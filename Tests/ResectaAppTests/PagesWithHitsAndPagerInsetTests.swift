import Testing
import SwiftUI
@testable import ResectaApp

// Two pure-function contracts pinned without a
// SwiftUI host:
//
//   (a) The "N pages · M with hits" orientation line beneath the
//       search sheet's header chrome: exact text (singular/plural),
//       the completed-run-with-results gate, and the distinct-page
//       derivation shared by both Search's unfiltered results and
//       Scan review's staged detections.
//   (b) The page nav bar's extra bottom padding while the search
//       sheet floats at the compact detent, so it clears the compact
//       strip instead of sitting underneath it.

@Suite("Pages-with-hits header line")
@MainActor
struct PagesWithHitsLineTests {

    @Test("Text: plural default, singular page count, \"with hits\" never inflects")
    func lineTextGrammar() {
        #expect(SearchAndRedactSheet.pagesWithHitsLine(pageCount: 1, pagesWithHits: 1)
                == "1 page \u{00B7} 1 with hits")
        #expect(SearchAndRedactSheet.pagesWithHitsLine(pageCount: 1, pagesWithHits: 0)
                == "1 page \u{00B7} 0 with hits")
        #expect(SearchAndRedactSheet.pagesWithHitsLine(pageCount: 12, pagesWithHits: 5)
                == "12 pages \u{00B7} 5 with hits")
        #expect(SearchAndRedactSheet.pagesWithHitsLine(pageCount: 3, pagesWithHits: 3)
                == "3 pages \u{00B7} 3 with hits")
    }

    @Test("Gate: only a completed run with a non-empty result set shows the line")
    func gatePredicate() {
        #expect(SearchAndRedactSheet.shouldShowPagesWithHitsLine(
            hasCompletedRun: false, resultCount: 0) == false)
        #expect(SearchAndRedactSheet.shouldShowPagesWithHitsLine(
            hasCompletedRun: false, resultCount: 5) == false)
        #expect(SearchAndRedactSheet.shouldShowPagesWithHitsLine(
            hasCompletedRun: true, resultCount: 0) == false)
        #expect(SearchAndRedactSheet.shouldShowPagesWithHitsLine(
            hasCompletedRun: true, resultCount: 5) == true)
    }

    @Test("Distinct-page derivation counts unique pages, order-independent")
    func distinctPageDerivation() {
        #expect(SearchAndRedactSheet.distinctPageCount([]) == 0)
        #expect(SearchAndRedactSheet.distinctPageCount([0, 0, 0]) == 1)
        #expect(SearchAndRedactSheet.distinctPageCount([0, 1, 2, 1, 0]) == 3)
        #expect(SearchAndRedactSheet.distinctPageCount([4, 2, 4, 2, 4]) == 2)
    }
}

@Suite("Page nav bar compact-float inset")
@MainActor
struct PageBarCompactInsetTests {

    @Test("Zero whenever the search sheet is not presented")
    func zeroWhenNotPresented() {
        #expect(DocumentEditorView.pageBarCompactInset(
            sheetPresented: false, detent: .compactFloat) == 0)
        #expect(DocumentEditorView.pageBarCompactInset(
            sheetPresented: false, detent: .medium) == 0)
    }

    @Test("Zero when presented at a taller-than-compact detent")
    func zeroAtTallerDetent() {
        #expect(DocumentEditorView.pageBarCompactInset(
            sheetPresented: true, detent: .medium) == 0)
        #expect(DocumentEditorView.pageBarCompactInset(
            sheetPresented: true, detent: .large) == 0)
    }

    @Test("Hug height only when presented AND at the compact-float detent")
    func hugHeightAtCompactFloat() {
        #expect(DocumentEditorView.pageBarCompactInset(
            sheetPresented: true, detent: .compactFloat) == CompactFloatDetent.hugHeight)
    }
}

// The unified inset for the no-page-bar
// case (single-page documents) — same geometry, same symbolic hug.
@Suite("Compact-parked canvas inset with no page bar")
@MainActor
struct CompactParkedCanvasInsetTests {

    @Test("Zero whenever the search sheet is not presented")
    func zeroWhenNotPresented() {
        #expect(DocumentEditorView.compactParkedCanvasInset(
            sheetPresented: false, detent: .compactFloat) == 0)
    }

    @Test("Zero when presented at medium or large")
    func zeroAtTallerDetent() {
        #expect(DocumentEditorView.compactParkedCanvasInset(
            sheetPresented: true, detent: .medium) == 0)
        #expect(DocumentEditorView.compactParkedCanvasInset(
            sheetPresented: true, detent: .large) == 0)
    }

    @Test("Hug height at compact-parked with NO bar — reads CompactFloatDetent.hugHeight symbolically")
    func hugHeightAtCompactFloatWithoutBar() {
        #expect(DocumentEditorView.compactParkedCanvasInset(
            sheetPresented: true, detent: .compactFloat) == CompactFloatDetent.hugHeight)
    }
}
