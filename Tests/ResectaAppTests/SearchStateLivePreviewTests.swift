import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

@Suite("SearchState live preview", .tags(.search))
@MainActor
struct SearchStateLivePreviewTests {

    /// Pure provider — no PDF needed for these tests, the engine reads
    /// only the synthetic strings here.
    private func textProvider(pages: [String]) -> @Sendable (Int) async -> String? {
        return { idx in
            guard idx >= 0 && idx < pages.count else { return nil }
            return pages[idx]
        }
    }

    @Test("Rapid typing only publishes the last query's preview")
    func rapidTypingCancelsEarlier() async {
        let state = SearchState()
        let searcher = DocumentSearcher()
        let provider = textProvider(pages: ["abc abc abc"])

        // Type "a" → "ab" → "abc" within the debounce window.
        state.queryText = "a"
        state.scheduleLivePreview(
            searcher: searcher, currentPageIndex: 0, totalPageCount: 1,
            pageTextProvider: provider, debounce: .milliseconds(50)
        )
        state.queryText = "ab"
        state.scheduleLivePreview(
            searcher: searcher, currentPageIndex: 0, totalPageCount: 1,
            pageTextProvider: provider, debounce: .milliseconds(50)
        )
        state.queryText = "abc"
        state.scheduleLivePreview(
            searcher: searcher, currentPageIndex: 0, totalPageCount: 1,
            pageTextProvider: provider, debounce: .milliseconds(50)
        )

        // CAT-234: self-clocking settle — poll the published preview instead of
        // a fixed wall-clock sleep (which flaked under full-suite load, OQ-24).
        // Each scheduleLivePreview cancels the prior debounce, so only the final
        // "abc" query ever publishes; exit as soon as its 3 matches land.
        for _ in 0..<100 {
            if state.livePreview?.totalCount == 3 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        let preview = state.livePreview
        #expect(preview != nil)
        // Only "abc" matches (3 occurrences).
        #expect(preview?.totalCount == 3)
        #expect(preview?.currentPageMatches.count == 3)
    }

    @Test("clearLivePreview cancels in-flight task and nils the result")
    func clearCancels() async {
        let state = SearchState()
        let searcher = DocumentSearcher()
        let provider = textProvider(pages: ["alpha alpha"])

        state.queryText = "alpha"
        state.scheduleLivePreview(
            searcher: searcher, currentPageIndex: 0, totalPageCount: 1,
            pageTextProvider: provider, debounce: .milliseconds(200)
        )

        // Cancel before the debounce fires. The 20 ms pre-cancel sleep is
        // intentional — it lets the 200 ms debounce schedule before the cancel.
        try? await Task.sleep(for: .milliseconds(20))
        state.clearLivePreview()

        // CAT-238: replace the fixed 300 ms settle with a bounded poll that
        // spans the debounce window. clearLivePreview() nils synchronously and
        // cancels the in-flight task; the guard is that the cancelled debounce
        // never re-publishes, so the preview must STAY nil across the window.
        // (The dossier framed this as exit-on-nil, but the production clear is
        // synchronous — a sustained-nil poll is what actually exercises the
        // cancellation. A late publish trips the break and fails below.)
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(10))
            if state.livePreview != nil { break }
        }

        #expect(state.livePreview == nil)
        #expect(state.livePreviewRects.isEmpty)
    }

    @Test("piiScan mode short-circuits to no preview")
    func piiScanShortCircuits() async {
        let state = SearchState()
        state.searchModeType = .piiScan
        state.queryText = "anything"
        let searcher = DocumentSearcher()
        let provider = textProvider(pages: ["alpha"])

        state.scheduleLivePreview(
            searcher: searcher, currentPageIndex: 0, totalPageCount: 1,
            pageTextProvider: provider, debounce: .milliseconds(20)
        )
        try? await Task.sleep(for: .milliseconds(80))
        #expect(state.livePreview == nil)
    }

    @Test("setLivePreviewRects publishes rects and bumps version")
    func setRects() {
        let state = SearchState()
        let before = state.resultVersion
        let rects = [CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05)]
        state.setLivePreviewRects(rects)
        #expect(state.livePreviewRects == rects)
        #expect(state.resultVersion > before)
    }

    // MARK: - D10-F3 scope + debounce

    /// #11 — the preview scopes to the current page even when whole-document
    /// navigation is active. Pre-D10-F3 this walked every page; the read-index
    /// set proves only the visible page is read.
    @Test("scheduleLivePreview scopes to current page under wholeDocument nav")
    func previewAlwaysCurrentPageScope() async {
        let state = SearchState()
        state.navigationScope = .wholeDocument
        state.searchModeType = .text
        state.queryText = "match"
        let searcher = DocumentSearcher()
        let recorder = PreviewIndexRecorder()
        // Pages 0 & 2 contain "match"; current page 1 does not.
        let pages = ["match here", "no hit here", "match again"]
        let provider: @Sendable (Int) async -> String? = { idx in
            await recorder.record(idx)
            guard idx >= 0 && idx < pages.count else { return nil }
            return pages[idx]
        }
        state.scheduleLivePreview(
            searcher: searcher, currentPageIndex: 1, totalPageCount: 3,
            pageTextProvider: provider, debounce: .milliseconds(20)
        )
        for _ in 0..<100 {
            if state.livePreview != nil { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let seen = await recorder.indices
        #expect(Set(seen) == [1], "provider read \(Set(seen)); expected only the current page {1}")
        // Current page 1 has no hit, so the preview total is scoped to it.
        #expect(state.livePreview?.currentPageMatches.isEmpty == true)
    }

    /// #12 — the default debounce is 300 ms (matching the full-search debounce).
    /// Asserting the provider has NOT run by 250 ms is the load-safe direction:
    /// sleeps only lengthen under load, so this can miss a regression but never
    /// invent one. Under the old 200 ms default the provider would already have
    /// run by 250 ms.
    @Test("scheduleLivePreview default debounce is 300ms")
    func defaultDebounceIs300ms() async {
        let state = SearchState()
        state.searchModeType = .text
        state.queryText = "alpha"
        let searcher = DocumentSearcher()
        let recorder = PreviewIndexRecorder()
        let provider: @Sendable (Int) async -> String? = { idx in
            await recorder.record(idx)
            return "alpha alpha"
        }
        // Omit `debounce:` to exercise the default.
        state.scheduleLivePreview(
            searcher: searcher, currentPageIndex: 0, totalPageCount: 1,
            pageTextProvider: provider
        )
        try? await Task.sleep(for: .milliseconds(250))
        let seenEarly = await recorder.indices
        #expect(seenEarly.isEmpty, "provider ran within 250 ms — default debounce regressed below 300 ms")
        state.clearLivePreview()
    }

    /// #13 — a settled whole-document query reads ONLY the current page's text,
    /// never the off-screen pages, after the D10-F3 scope fix.
    @Test("a settled whole-document query reads only the current page")
    func settledWholeDocReadsOnlyCurrentPage() async {
        let state = SearchState()
        state.navigationScope = .wholeDocument
        state.searchModeType = .text
        state.queryText = "alpha"
        let searcher = DocumentSearcher()
        let recorder = PreviewIndexRecorder()
        let pages = ["alpha p0", "alpha p1", "alpha p2", "alpha p3"]
        let provider: @Sendable (Int) async -> String? = { idx in
            await recorder.record(idx)
            guard idx >= 0 && idx < pages.count else { return nil }
            return pages[idx]
        }
        state.scheduleLivePreview(
            searcher: searcher, currentPageIndex: 2, totalPageCount: 4,
            pageTextProvider: provider, debounce: .milliseconds(20)
        )
        for _ in 0..<100 {
            if state.livePreview != nil { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let seen = await recorder.indices
        #expect(Set(seen) == [2], "read-index set was \(Set(seen)); expected only the current page {2}")
    }
}

/// Records the page indices a `pageTextProvider` is asked for, so a test can
/// assert the live preview reads only the current page (D10-F3 scope).
private actor PreviewIndexRecorder {
    private(set) var indices: [Int] = []
    func record(_ idx: Int) { indices.append(idx) }
}
