import Testing
import Foundation
import CoreGraphics
@testable import ResectaApp
@testable import RedactionEngine

// The parked match walk follows the page bar: when the page shown leaves
// the current match's page, the current match is let go, so the strip's
// Apply cannot apply a match on another page; and › / ‹ (and J / K) step
// from the page shown, not from a match the person has paged away from.

@MainActor
@Suite("Match walk follows the page shown")
struct WalkNavigatorTests {

    /// Results on pages 0, 0, 2 and 5, in document order.
    private static func search() -> SearchState {
        let search = SearchState(defaults: makeScratchDefaults().0)
        search.results = [0, 0, 2, 5].enumerated().map { offset, page in
            SearchResult(
                pageIndex: page,
                normalizedRect: CGRect(x: 0.1, y: 0.1 + 0.1 * CGFloat(offset), width: 0.2, height: 0.03),
                matchedText: "Amount", contextSnippet: "…Amount…", source: .textLayer, term: "Amount", isSelected: false)
        }
        return search
    }

    @Test("Paging away from the current match lets it go; paging within its page keeps it")
    func pagingAwayLetsTheCurrentGo() {
        let search = Self.search()
        search.currentResultIndex = 0
        search.yieldWalk(toPage: 0)
        #expect(search.currentResultIndex == 0)
        search.yieldWalk(toPage: 3)
        #expect(search.currentResult == nil)
    }

    @Test("› steps to the first match on or after the page shown, ‹ to the last on or before it")
    func stepsFromThePageShown() {
        let search = Self.search()
        search.currentResultIndex = 0
        // Paged to page 3 with the walk still on page 0's first match.
        search.walkToNext(fromPage: 3)
        #expect(search.currentResult?.pageIndex == 5)

        search.currentResultIndex = 0
        search.walkToPrevious(fromPage: 3)
        #expect(search.currentResultIndex == 2, "the last match on a page before page 3 is page 2's")

        search.currentResultIndex = nil
        search.walkToNext(fromPage: 2)
        #expect(search.currentResultIndex == 2, "the page shown's own match comes first")
    }

    @Test("On the current match's page the walk steps as before, and wraps")
    func onThePageStepsAsBefore() {
        let search = Self.search()
        search.currentResultIndex = 0
        search.walkToNext(fromPage: 0)
        #expect(search.currentResultIndex == 1)
        search.currentResultIndex = 3
        search.walkToNext(fromPage: 5)
        #expect(search.currentResultIndex == 0, "past the last match the walk wraps to the first")
        search.currentResultIndex = nil
        search.walkToNext(fromPage: 6)
        #expect(search.currentResultIndex == 0, "after the last match's page, › wraps to the first")
    }

    @Test("The page bar's arrows move the page and let an off-page current match go")
    func pageBarArrowsYieldTheWalk() {
        let documentState = DocumentState()
        documentState.sourceDocument = makeMultiPagePDFDocument(pages: 6)
        let redactionState = RedactionState()
        let search = Self.search()
        search.currentResultIndex = 0
        redactionState.activeSearch = search
        PageNavigationBar.showPage(1, documentState: documentState, redactionState: redactionState)
        #expect(documentState.currentPageIndex == 1)
        #expect(search.currentResult == nil)
    }
}
