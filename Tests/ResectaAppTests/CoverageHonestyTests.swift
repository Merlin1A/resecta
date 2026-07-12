import Testing
import Foundation
import CoreGraphics
import RedactionEngine
@testable import ResectaApp

// q13 — results/coverage honesty. Pins the QW-12 cap-remainder banner,
// the ST-83 OCR-skip surfacing on both legs (search banner + triage
// banner), and the UXF-16 mode-switch preview-counter clear.

// MARK: - QW-12 cap remainder

@Suite("Search footer cap banner (QW-12)", .tags(.search))
@MainActor
struct SearchFooterCapBannerTests {

    @Test("Cap banner carries the unscanned-page remainder")
    func capBannerCarriesRemainder() {
        let text = SearchFooterSection.capBannerText(
            resultCount: 1000, unscannedPageCount: 12
        )
        #expect(text.contains("Showing first 1000 results."))
        #expect(text.contains("12 pages were never scanned."))
    }

    @Test("Cap banner singularizes a one-page remainder")
    func capBannerSingularRemainder() {
        let text = SearchFooterSection.capBannerText(
            resultCount: 1000, unscannedPageCount: 1
        )
        #expect(text.contains("1 page was never scanned."))
        #expect(!text.contains("pages were"))
    }

    @Test("Cap banner omits the remainder sentence at zero")
    func capBannerZeroRemainder() {
        let text = SearchFooterSection.capBannerText(
            resultCount: 1000, unscannedPageCount: 0
        )
        #expect(!text.contains("never scanned"))
        #expect(text.contains("Showing first 1000 results."))
        #expect(text.contains("Refine your search"))
    }

    @Test("appendResult snapshots the unscanned remainder when the cap fires")
    func capSnapshotsUnscannedPages() {
        let state = SearchState()
        state.totalPages = 40
        state.currentSearchPage = 12

        // Fill to the engine cap, then deliver one more result: the cap
        // branch must fire and snapshot 40 - 12 = 28 unscanned pages.
        let filler = SearchResult(
            pageIndex: 0,
            normalizedRect: CGRect(x: 0, y: 0, width: 0.1, height: 0.1),
            matchedText: "filler",
            contextSnippet: "filler",
            source: .textLayer,
            term: "filler"
        )
        state.results = Array(repeating: filler, count: DocumentSearcher.maxResults)
        state.appendResult(filler)

        #expect(state.resultsAtCap)
        #expect(state.capUnscannedPageCount == 28)
    }
}

// MARK: - ST-83 search-leg banner

@Suite("OCR skip banner (ST-83, search leg)", .tags(.search))
@MainActor
struct OCRSkipBannerTests {

    @Test("Banner appears on first skip — set non-empty after recordOCRSkip")
    func bannerAppearsOnFirstSkip() {
        let state = SearchState()
        #expect(state.ocrSkippedPages.isEmpty)
        state.recordOCRSkip(page: 0)
        #expect(state.ocrSkippedPages == [0])
    }

    @Test("Banner accumulates distinct pages; Set semantics dedupe")
    func bannerAccumulatesPages() {
        let state = SearchState()
        state.recordOCRSkip(page: 2)
        state.recordOCRSkip(page: 5)
        state.recordOCRSkip(page: 2)
        #expect(state.ocrSkippedPages == [2, 5])
    }

    @Test("resetOCRSkippedPages clears the set without touching other state")
    func resetClearsOnly() {
        let state = SearchState()
        state.recordOCRSkip(page: 1)
        state.recordRegexTimeout(page: 3)
        state.resetOCRSkippedPages()
        #expect(state.ocrSkippedPages.isEmpty)
        // The sibling regex-timeout set is independent.
        #expect(state.regexTimeoutPages == [3])
    }

    @Test("Headline pluralizes and renders 1-based page numbers")
    func headlinePluralizationAndNumbering() {
        let single = SearchResultsSection.ocrSkipBannerHeadline(pages: [0])
        #expect(single.contains("Page 1 was"))
        #expect(!single.contains("Page 0"))

        let multiple = SearchResultsSection.ocrSkipBannerHeadline(pages: [2, 4])
        #expect(multiple.contains("Pages 3 and 5 were"))
        #expect(multiple.contains("not searched"))
    }
}

// MARK: - ST-83 detect-leg banner

@Suite("Triage OCR skip banner (ST-83, detect leg)")
@MainActor
struct DetectionTriageOCRSkipBannerTests {

    @Test("Headline pluralizes and renders 1-based page numbers")
    func headlinePluralizationAndNumbering() {
        let single = DetectionTriageSheet.ocrSkipBannerHeadline(pages: [0])
        #expect(single.contains("Page 1 is"))
        #expect(single.contains("that page"))

        let multiple = DetectionTriageSheet.ocrSkipBannerHeadline(pages: [1, 3, 7])
        #expect(multiple.contains("Pages 2, 4, and 8 are"))
        #expect(multiple.contains("those pages"))
        #expect(multiple.contains("not checked"))
    }

    @Test("clearForNewDocument drops the skip-page set")
    func clearForNewDocumentDropsSkips() {
        let state = RedactionState()
        state.ocrPixelCapSkippedPages = [1, 4]
        state.clearForNewDocument()
        #expect(state.ocrPixelCapSkippedPages.isEmpty)
    }
}

// MARK: - UXF-16 mode-switch preview residue

@Suite("Mode-switch preview residue (UXF-16)", .tags(.search))
@MainActor
struct ModeSwitchPreviewResidueTests {

    @Test("clearLivePreview drops both the counter source and the rects")
    func clearDropsCountersAndRects() {
        // The mode-switch handler in `SearchAndRedactSheet` now calls
        // `clearLivePreview()` on EVERY `searchModeType` transition (not
        // just into piiScan), so the "Matches this page … Total …" row —
        // whose counts read from `livePreview` — cannot survive a mode
        // switch. This pins the state mechanics that handler relies on.
        let state = SearchState()
        state.setLivePreviewRects([CGRect(x: 0, y: 0, width: 0.2, height: 0.1)])
        #expect(!state.livePreviewRects.isEmpty)

        state.clearLivePreview()

        #expect(state.livePreview == nil)
        #expect(state.livePreviewRects.isEmpty)
    }
}
