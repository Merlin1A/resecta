import Testing
import Foundation
import CoreGraphics
import RedactionEngine
@testable import ResectaApp

// The parked strip's match line (`SearchState.walkLine` /
// `walkSummary`) and the one published walk-liveness predicate, pinned
// without a SwiftUI host.

@Suite("Walk summary line")
@MainActor
struct WalkSummaryTests {

    private func result(
        page: Int = 1, matched: String, term: String, category: PIICategory? = nil
    ) -> SearchResult {
        SearchResult(
            pageIndex: page,
            normalizedRect: CGRect(x: 0.1, y: 0.5, width: 0.2, height: 0.02),
            matchedText: matched,
            contextSnippet: matched,
            source: .textLayer,
            term: term,
            piiCategory: category)
    }

    private func state(mode: SearchModeType, results: [SearchResult], current: Int? = 0) -> SearchState {
        let s = SearchState()
        s.searchModeType = mode
        s.results = results
        s.currentResultIndex = current
        return s
    }

    @Test("Scan: the category's display name · Page k of N · the matched text")
    func scanLine() {
        let s = state(mode: .piiScan, results: [result(page: 1, matched: "Hartwell", term: "name", category: .name)])
        let summary = s.walkSummary(for: s.results[0], pageCount: 3)
        #expect(summary == WalkSummary(kind: "Name", pageLabel: "Page 2 of 3", text: "Hartwell"))
        #expect(s.walkLine(pageCount: 3, reviewPending: false) == .match(summary))
    }

    @Test("Text search: the term · page, and the text only when it differs from the term (case-insensitive)")
    func textSearchDropsTheTextWhenItEqualsTheTerm() {
        let same = state(mode: .text, results: [result(page: 0, matched: "DELIA", term: "Delia")])
        #expect(same.walkSummary(for: same.results[0], pageCount: 3)
                == WalkSummary(kind: "Delia", pageLabel: "Page 1 of 3", text: nil))
        let differs = state(mode: .text, results: [result(page: 0, matched: "Delia's", term: "Delia")])
        #expect(differs.walkSummary(for: differs.results[0], pageCount: 3).text == "Delia's")
    }

    @Test("Regex and multi-term keep the matched text even when it equals the term")
    func regexAndMultiTermKeepTheText() {
        let regex = state(mode: .regex, results: [result(matched: "4111", term: "4111")])
        #expect(regex.walkSummary(for: regex.results[0], pageCount: 1).text == "4111")
        let multi = state(mode: .multiTerm, results: [result(matched: "Delia", term: "Delia")])
        #expect(multi.walkSummary(for: multi.results[0], pageCount: 1).text == "Delia")
    }

    @Test("The page readout is 1-based over the document's page count")
    func pageLabel() {
        #expect(SearchState.walkPageLabel(pageIndex: 0, pageCount: 1) == "Page 1 of 1")
        #expect(SearchState.walkPageLabel(pageIndex: 22, pageCount: 23) == "Page 23 of 23")
    }

    @Test("A current the active filters hide reads 'Hidden by filters'")
    func hiddenByFilters() {
        let s = state(mode: .text, results: [result(matched: "x", term: "x")])
        s.sourceFilter = .ocrOnly   // the one text-layer result drops out of the filtered set
        #expect(s.currentResultFilteredPosition == nil)
        #expect(s.walkLine(pageCount: 1, reviewPending: false) == .hiddenByFilters)
        #expect(WalkLine.hiddenByFiltersText == "Hidden by filters")
    }

    @Test("Results on board but no current yet: the slot is empty")
    func noCurrentIsEmpty() {
        let s = state(mode: .text, results: [result(matched: "x", term: "x")], current: nil)
        #expect(s.walkLine(pageCount: 1, reviewPending: false) == .empty)
    }

    @Test("No results: the list's own headline, verbatim; empty in the pre-search contexts")
    func statusHeadlines() {
        let noMatch = state(mode: .text, results: [], current: nil)
        noMatch.queryText = "zzz"; noMatch.hasCompletedRunSinceClear = true
        #expect(noMatch.walkLine(pageCount: 1, reviewPending: false) == .status("No matches"))
        let notRun = state(mode: .regex, results: [], current: nil)
        notRun.queryText = "a+"
        #expect(notRun.walkLine(pageCount: 1, reviewPending: false) == .status("Not run yet"))
        let preScan = state(mode: .piiScan, results: [], current: nil)
        #expect(preScan.walkLine(pageCount: 1, reviewPending: false) == .status("Not scanned yet"))
        let preSearch = state(mode: .text, results: [], current: nil)
        #expect(preSearch.walkLine(pageCount: 1, reviewPending: false) == .empty)
        let preRegex = state(mode: .regex, results: [], current: nil)
        #expect(preRegex.walkLine(pageCount: 1, reviewPending: false) == .empty)
        let preMulti = state(mode: .multiTerm, results: [], current: nil)
        #expect(preMulti.walkLine(pageCount: 1, reviewPending: false) == .empty)
    }

    @Test("A pending review owns the slot: empty, with or without stale results")
    func reviewPendingIsEmpty() {
        let scan = state(mode: .piiScan, results: [], current: nil)
        #expect(scan.walkLine(pageCount: 1, reviewPending: true) == .empty)
        let stale = state(mode: .piiScan, results: [result(matched: "x", term: "x", category: .ssn)])
        #expect(stale.walkLine(pageCount: 1, reviewPending: true) == .empty)
    }

    @Test("The walk is live with results on board, or with the staged review owning the Scan interface (the review walk)")
    func walkLiveness() {
        let search = state(mode: .text, results: [result(matched: "x", term: "x")])
        #expect(search.isWalkLive(reviewPending: false))
        // A pending review touches only the Scan interface; a Search session stays live on its results.
        #expect(search.isWalkLive(reviewPending: true))
        let scan = state(mode: .piiScan, results: [result(matched: "x", term: "x", category: .ssn)])
        #expect(scan.isWalkLive(reviewPending: false))
        // The review walk: a pending review on the Scan interface is live with stale results —
        #expect(scan.isWalkLive(reviewPending: true))
        #expect(scan.reviewOwnsInterface(reviewPending: true))
        // — and with none; a Search session with nothing on board is not.
        #expect(state(mode: .piiScan, results: [], current: nil).isWalkLive(reviewPending: true))
        #expect(!state(mode: .text, results: [], current: nil).isWalkLive(reviewPending: false))
        #expect(!state(mode: .text, results: [], current: nil).isWalkLive(reviewPending: true))
        let store = RedactionState()
        #expect(!store.walkLive)
        store.activeSearch = search
        #expect(store.walkLive)
        // The editor's read follows the review walk too — the page bar
        // steps aside beneath the parked review.
        let review = RedactionState()
        review.activeSearch = state(mode: .piiScan, results: [], current: nil)
        #expect(!review.walkLive)
        review.pendingTriage = [0: [DetectionResult(
            normalizedRect: CGRect(x: 0.1, y: 0.5, width: 0.2, height: 0.03),
            kind: .pii(.ssn), confidence: 0.9, matchedText: "123-45-6789")]]
        #expect(review.walkLive)
    }
}
