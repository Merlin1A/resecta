import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

@Suite("SearchState scope-aware navigation", .tags(.search))
@MainActor
struct SearchStateScopeTests {

    private func makeResult(page: Int, term: String = "x") -> SearchResult {
        SearchResult(
            pageIndex: page,
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.04),
            matchedText: term,
            contextSnippet: "…\(term)…",
            source: .textLayer,
            term: term
        )
    }

    /// 5 results across 3 pages: p0×2, p1×0, p2×3.
    private func threePageState() -> SearchState {
        let state = SearchState()
        state.results = [
            makeResult(page: 0),
            makeResult(page: 0),
            makeResult(page: 2),
            makeResult(page: 2),
            makeResult(page: 2),
        ]
        return state
    }

    @Test("currentPage scope wraps within visible page only")
    func wrapsWithinPage() {
        let state = threePageState()
        state.navigationScope = .currentPage

        // Visible page is 0 → scope contains results[0..1].
        state.navigateToNext(currentPageIndex: 0)
        #expect(state.currentResultIndex == 0)
        state.navigateToNext(currentPageIndex: 0)
        #expect(state.currentResultIndex == 1)
        state.navigateToNext(currentPageIndex: 0)
        #expect(state.currentResultIndex == 0) // wrapped

        state.navigateToPrevious(currentPageIndex: 0)
        #expect(state.currentResultIndex == 1) // wrapped backwards
    }

    @Test("currentPage scope on a page with no results is a no-op")
    func emptyScopeNoOp() {
        let state = threePageState()
        state.currentResultIndex = 0
        state.navigationScope = .currentPage

        // Visible page is 1 (no matches).
        state.navigateToNext(currentPageIndex: 1)
        #expect(state.currentResultIndex == 0)
        state.navigateToPrevious(currentPageIndex: 1)
        #expect(state.currentResultIndex == 0)
    }

    @Test("Switch back to wholeDocument resumes at same result by ID")
    func resumeByID() {
        let state = threePageState()

        // Park on the second result of page 2 (results[3]).
        state.currentResultIndex = 3
        let parkedID = state.currentResult?.id

        // Toggle into currentPage scope on page 2 — currentResultIndex
        // unchanged (the parked result is in the page-2 scope already).
        state.navigationScope = .currentPage
        #expect(state.currentResult?.id == parkedID)

        // Step within page 2.
        state.navigateToNext(currentPageIndex: 2)
        // currentResultIndex should now be 4 (third match on page 2).
        #expect(state.currentResultIndex == 4)
        let afterStepID = state.currentResult?.id

        // Switch back to wholeDocument — result identity preserved.
        state.navigationScope = .wholeDocument
        #expect(state.currentResult?.id == afterStepID)
    }

    @Test("wholeDocument navigation traverses all pages")
    func wholeDocumentTraversesAll() {
        let state = threePageState()
        state.navigationScope = .wholeDocument

        state.navigateToNext(currentPageIndex: 0)
        #expect(state.currentResultIndex == 0)
        state.navigateToNext(currentPageIndex: 0)
        #expect(state.currentResultIndex == 1)
        state.navigateToNext(currentPageIndex: 0)
        #expect(state.currentResultIndex == 2) // crosses to page 2
    }
}
