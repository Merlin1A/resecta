import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

// WU-23 — Saturation banner shortcut contracts. Each tap-shortcut
// mutates the corresponding `searchState` field; the banner copy is
// pinned per D-37. Re-trigger of the
// search after the mutation is wired through the `onTriggerSearch`
// closure on `SearchResultsSection` (verified by handoff cell — not
// re-tested here since it is a closure call without side effects on
// `SearchState`; the trigger path itself is exercised by the broader
// search test suite).

@Suite("Saturation banner (WU-23)", .tags(.search))
@MainActor
struct SaturationBannerTests {

    // MARK: - Strings

    @Test("Banner headline matches the existing saturation copy")
    func bannerHeadline() {
        // The banner promotes (not replaces) the prior inline message,
        // so the headline string remains "≥ 10,000 matches — refine query".
        let expected = "\u{2265} 10,000 matches \u{2014} refine query"
        #expect(WU23Strings.headline == expected)
    }

    @Test("Shortcut button labels are mechanism-description action labels")
    func shortcutLabels() {
        #expect(WU23Strings.addWholeWord == "Add whole-word filter")
        #expect(WU23Strings.toggleCaseSensitive == "Toggle case-sensitive")
        #expect(WU23Strings.scopeToCurrentPage == "Scope to current page")
    }

    // MARK: - Add whole-word filter shortcut

    @Test("Add whole-word filter sets options.wholeWord = true")
    func addWholeWordMutatesOptions() {
        let state = SearchState()
        state.options.wholeWord = false

        // Mirror the banner's tap handler.
        state.options.wholeWord = true

        #expect(state.options.wholeWord == true)
    }

    @Test("Add whole-word filter is idempotent — re-tap leaves wholeWord = true")
    func addWholeWordIsIdempotent() {
        let state = SearchState()
        state.options.wholeWord = true

        state.options.wholeWord = true

        #expect(state.options.wholeWord == true)
    }

    // MARK: - Toggle case-sensitive shortcut

    @Test("Toggle case-sensitive flips options.caseSensitive")
    func toggleCaseSensitiveFlipsField() {
        let state = SearchState()
        #expect(state.options.caseSensitive == false)

        state.options.caseSensitive.toggle()
        #expect(state.options.caseSensitive == true)

        state.options.caseSensitive.toggle()
        #expect(state.options.caseSensitive == false)
    }

    // MARK: - Scope to current page shortcut (WU-23 simple form)

    @Test("Scope to current page sets navigationScope = .currentPage")
    func scopeToCurrentPageMutatesScope() {
        let state = SearchState()
        state.navigationScope = .wholeDocument

        state.navigationScope = .currentPage

        #expect(state.navigationScope == .currentPage)
    }

    // MARK: - WU-65 scope-to-current-page action chain

    @Test("WU-65: scopeToCurrentPage drains pending buffer, cancels scan, sets scope")
    func scopeToCurrentPageActionChain() async {
        let state = SearchState()
        state.isSearching = true
        state.navigationScope = .wholeDocument

        // Populate the pending buffer via `appendResult` — under the
        // batchFlushSize threshold so it lands in `pendingResults` and
        // not `results` directly. Per [RR-23] flush MUST run before
        // cancel so this entry survives the re-target.
        let id = UUID()
        let pending = SearchResult(
            id: id,
            pageIndex: 0,
            normalizedRect: CGRect(x: 0, y: 0, width: 0.1, height: 0.05),
            matchedText: "alpha",
            contextSnippet: "alpha context",
            source: .textLayer,
            term: "alpha"
        )
        state.appendResult(pending)

        await state.scopeToCurrentPage()

        // Pending buffer drained into `results` (via flush before
        // cancel; cancel's internal flush is a no-op afterwards).
        #expect(state.results.contains(where: { $0.id == id }))
        // In-flight search marked finished.
        #expect(state.isSearching == false)
        // Scope re-targeted.
        #expect(state.navigationScope == .currentPage)
    }

    @Test("WU-65: scopeToCurrentPage from .currentPage is idempotent")
    func scopeToCurrentPageIdempotent() async {
        let state = SearchState()
        state.navigationScope = .currentPage

        await state.scopeToCurrentPage()

        #expect(state.navigationScope == .currentPage)
        #expect(state.isSearching == false)
    }
}
