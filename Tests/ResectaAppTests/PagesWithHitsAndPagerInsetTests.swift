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
//   (b) The bottom-chrome layout model (`ParkedChromeLayout`): the
//       page bar's mount rule (it stays while the sheet is parked at
//       the compact float, with or without a live result walk), the
//       parked-canvas inset, the toast clearance and the hint-capsule
//       lift — one truth table, including the park-with-no-query
//       boundary the compact-float draw tests rely on.

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
            hasCompletedRun: false, resultCount: 0, atCap: false) == false)
        #expect(SearchAndRedactSheet.shouldShowPagesWithHitsLine(
            hasCompletedRun: false, resultCount: 5, atCap: false) == false)
        #expect(SearchAndRedactSheet.shouldShowPagesWithHitsLine(
            hasCompletedRun: true, resultCount: 0, atCap: false) == false)
        #expect(SearchAndRedactSheet.shouldShowPagesWithHitsLine(
            hasCompletedRun: true, resultCount: 5, atCap: false) == true)
        // A capped run never scanned the tail: "M with hits" would read
        // as a document-wide count, so the line steps aside.
        #expect(SearchAndRedactSheet.shouldShowPagesWithHitsLine(
            hasCompletedRun: true, resultCount: 1_000, atCap: true) == false)
    }

    @Test("Distinct-page derivation counts unique pages, order-independent")
    func distinctPageDerivation() {
        #expect(SearchAndRedactSheet.distinctPageCount([]) == 0)
        #expect(SearchAndRedactSheet.distinctPageCount([0, 0, 0]) == 1)
        #expect(SearchAndRedactSheet.distinctPageCount([0, 1, 2, 1, 0]) == 3)
        #expect(SearchAndRedactSheet.distinctPageCount([4, 2, 4, 2, 4]) == 2)
    }
}

@Suite("Parked-chrome layout model")
@MainActor
struct ParkedChromeLayoutTests {

    private func layout(
        sheet: Bool = true,
        detent: PresentationDetent = .compactFloat,
        walk: Bool = true,
        pages: Int = 3,
        size: UserInterfaceSizeClass? = .compact,
        phase: DocumentState.PhaseKind = .editing,
        hug: CGFloat = CompactFloatDetent.hugHeight
    ) -> ParkedChromeLayout {
        ParkedChromeLayout(
            sheetPresented: sheet, detent: detent, walkLive: walk,
            pageCount: pages, sizeClass: size, phase: phase, hugHeight: hug)
    }

    @Test("The page bar mounts only at compact width, with a page open, in the editing phase")
    func pageBarEligibility() {
        #expect(layout(sheet: false, walk: false).showsPageBar)
        #expect(!layout(sheet: false, walk: false, pages: 0).showsPageBar)
        #expect(!layout(sheet: false, walk: false, size: .regular).showsPageBar)
        #expect(!layout(sheet: false, walk: false, size: nil).showsPageBar)
        #expect(!layout(sheet: false, walk: false, phase: .verifying).showsPageBar)
        #expect(!layout(sheet: false, walk: false, phase: .verified).showsPageBar)
    }

    @Test("A one-page document shows the page bar, and bottom toasts clear it; no page shows none")
    func onePageDocumentShowsTheBar() {
        #expect(layout(sheet: false, walk: false, pages: 1).showsPageBar)
        #expect(layout(sheet: false, walk: false, pages: 1).toastClearance == ParkedChromeLayout.pageBarClearance)
        #expect(!layout(sheet: false, walk: false, pages: 0).showsPageBar)
    }

    @Test("The page bar stays while the sheet is parked at the compact float, with or without a live walk")
    func pageBarStaysWhileParked() {
        // sheet × detent × walk — a parked walk keeps the page control,
        // so a page with no hits stays reachable without raising.
        #expect(layout(sheet: true, detent: .compactFloat, walk: true).showsPageBar)
        // The compact-float draw tests park with no query: the bar stays.
        #expect(layout(sheet: true, detent: .compactFloat, walk: false).showsPageBar)
        #expect(layout(sheet: true, detent: .medium, walk: true).showsPageBar)
        #expect(layout(sheet: true, detent: .large, walk: true).showsPageBar)
        // A stale compact detent binding with no sheet up is not a park.
        #expect(layout(sheet: false, detent: .compactFloat, walk: true).showsPageBar)
        #expect(layout(sheet: false, detent: .compactFloat, walk: false).showsPageBar)
    }

    @Test("The canvas inset is the hug only while parked — bar shown, bar hidden, or no bar at all")
    func canvasInsetIsTheHugOnlyWhileParked() {
        #expect(layout(walk: true).canvasBottomInset == CompactFloatDetent.hugHeight)
        #expect(layout(walk: false).canvasBottomInset == CompactFloatDetent.hugHeight)
        #expect(layout(pages: 0).canvasBottomInset == CompactFloatDetent.hugHeight)
        #expect(layout(detent: .medium).canvasBottomInset == 0)
        #expect(layout(detent: .large).canvasBottomInset == 0)
        #expect(layout(sheet: false).canvasBottomInset == 0)
    }

    @Test("The model reads the hug it is given — the accessibility hug rides through the inset and the clearance")
    func readsTheGivenHug() {
        #expect(layout(hug: 120).canvasBottomInset == 120)
        #expect(layout(hug: 120).toastClearance == 120 + ParkedChromeLayout.pageBarClearance)
        #expect(layout(pages: 0, hug: 120).toastClearance == 120)
    }

    @Test("Toast clearance: the hug while parked, plus the bar while it is up and uncovered; zero under a taller sheet")
    func toastClearance() {
        let bar = ParkedChromeLayout.pageBarClearance
        let hug = CompactFloatDetent.hugHeight
        // No sheet: the import toast clears the bar.
        #expect(layout(sheet: false, walk: false).toastClearance == bar)
        #expect(layout(sheet: false, walk: false, pages: 0).toastClearance == 0)
        // Parked with a live walk: the bar stays — both.
        #expect(layout(walk: true).toastClearance == hug + bar)
        // Parked with no walk: the bar stays — both.
        #expect(layout(walk: false).toastClearance == hug + bar)
        #expect(layout(pages: 0).toastClearance == hug)
        // A taller sheet covers the app-level host; the sheet-local
        // host needs nothing.
        #expect(layout(detent: .medium).toastClearance == 0)
        #expect(layout(detent: .large).toastClearance == 0)
    }

    @Test("The page bar's clearance is the chevron floor plus its vertical padding, read from the tokens")
    func pageBarClearanceIsTheBarsLayoutHeight() {
        #expect(ParkedChromeLayout.pageBarClearance
                == ResectaTokens.TouchTarget.minimum + 2 * ResectaTokens.Spacing.sm)
    }

    @Test("The hint-capsule lift is zero in every state — the capsule rides the bottom inset")
    func hintCapsuleLiftIsZero() {
        #expect(layout().hintCapsuleLift == 0)
        #expect(layout(walk: false).hintCapsuleLift == 0)
        #expect(layout(sheet: false, walk: false).hintCapsuleLift == 0)
        #expect(layout(detent: .medium).hintCapsuleLift == 0)
    }

    @Test("Equatable over the inputs")
    func equatableOverInputs() {
        #expect(layout() == layout())
        // The walk no longer moves the chrome; the page count still does.
        #expect(layout() == layout(walk: false))
        #expect(layout() != layout(pages: 0))
        #expect(layout() != layout(hug: 120))
    }
}

// The sheet-local toast host at a medium or large detent: it sits above the
// footer, so a notice never covers Select All or Apply.
@Suite("Sheet toast host lift")
@MainActor
struct SheetToastHostLiftTests {

    @Test("With the footer up, the host lifts by the footer's height on top of the clearance")
    func liftsAboveTheFooter() {
        #expect(SearchAndRedactSheet.sheetToastLift(clearance: 12, footerHeight: 64, footerShown: true) == 76)
    }

    @Test("Without the footer, the host keeps the clearance alone")
    func clearanceAloneWithoutTheFooter() {
        #expect(SearchAndRedactSheet.sheetToastLift(clearance: 12, footerHeight: 64, footerShown: false) == 12)
    }
}
