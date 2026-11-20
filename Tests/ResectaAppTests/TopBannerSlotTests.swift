import Testing
import Foundation
import SwiftUI
@testable import ResectaApp

// The editor's band under the toolbar: six places in a fixed order, the
// first that holds shown, the rest waiting. The order has one home
// (`TopBannerSlot`); the import annotation notice's own visibility reads
// only its own facts. Every expectation is the band's case table, written
// out, not derived from the code under test.

@MainActor
@Suite("Editor top-banner slot")
struct TopBannerSlotTests {

    /// The band's order, written out.
    private static let order: [TopBannerSlot] = [
        .redrawn, .paused, .importAnnotations, .sourceProtection, .fit, .imagePages,
    ]

    /// Every set of the six places, by the bits of 0 to 63 over `order`.
    private static var everySet: [Set<TopBannerSlot>] {
        (0..<64).map { bits in Set(order.indices.filter { bits & (1 << $0) != 0 }.map { order[$0] }) }
    }

    @Test("The band shows the first notice in its order, for every set of notices")
    func occupantForEverySet() {
        #expect(TopBannerSlot.allCases.count == 6)
        #expect(TopBannerSlot.allCases == Self.order)
        let sets = Self.everySet
        #expect(sets.count == 64)
        #expect(Set(sets).count == 64)
        for present in sets {
            var expected: TopBannerSlot?
            for slot in Self.order where present.contains(slot) {
                expected = slot
                break
            }
            #expect(TopBannerSlot.occupant(of: present) == expected, "\(present)")
        }
        #expect(TopBannerSlot.occupant(of: [.paused, .importAnnotations]) == .paused)
        #expect(TopBannerSlot.occupant(of: [.redrawn, .paused]) == .redrawn)
        #expect(TopBannerSlot.occupant(of: []) == nil)
    }

    @Test("The folded mark's number is how many notices hold, and it shows from two")
    func waitingCountForEverySet() {
        let sets = Self.everySet
        #expect(sets.count == 64)
        var shown = 0
        for present in sets {
            let expected: Int? = present.count >= 2 ? present.count : nil
            #expect(TopBannerSlot.waitingCount(of: present) == expected, "\(present)")
            if expected != nil { shown += 1 }
        }
        // 64 sets less the empty one and the six of one.
        #expect(shown == 57)
        #expect(TopBannerSlot.waitingCount(of: [.paused, .importAnnotations]) == 2)
        #expect(TopBannerSlot.waitingCount(of: [.paused]) == nil)
    }

    /// An editing document whose source carries a filled form field, so the
    /// annotation notice is owed.
    private static func annotatedEditingDocument() -> DocumentState {
        let documentState = DocumentState()
        documentState.phase = .editing
        documentState.sourceFilledFormFieldCount = 1
        return documentState
    }

    @Test("The editor's read: paused comes before the import notice, and the fit input ranks fifth")
    func editorsRead() {
        let both = Self.annotatedEditingDocument()
        both.wasPausedByBackground = true
        #expect(TopBannerSlot.winner(documentState: both) == .paused, "O-2 paused and the import notice")
        #expect(TopBannerSlot.holding(documentState: both) == [.paused, .importAnnotations])

        let annotated = Self.annotatedEditingDocument()
        #expect(TopBannerSlot.winner(documentState: annotated) == .importAnnotations, "O-3 the import notice alone")

        let plain = DocumentState()
        plain.phase = .editing
        #expect(TopBannerSlot.winner(documentState: plain) == nil, "O-3 none")
        #expect(TopBannerSlot.holding(documentState: plain).isEmpty)

        #expect(TopBannerSlot.winner(documentState: plain, widenedOnPage: true) == .fit, "O-5 the fit input")
        #expect(TopBannerSlot.winner(documentState: annotated, widenedOnPage: true) == .importAnnotations,
                "O-5 the import notice before the fit input")
        plain.wasPausedByBackground = true
        #expect(TopBannerSlot.winner(documentState: plain, widenedOnPage: true) == .paused, "O-5 then with the pause")
        #expect(TopBannerSlot.holding(documentState: plain, widenedOnPage: true) == [.paused, .fit])
    }

    @Test("The editor's read: a dismissed annotation notice and a phase other than editing leave the slot empty")
    func emptySlot() {
        let documentState = Self.annotatedEditingDocument()
        documentState.annotationNoticeDismissed = true
        #expect(TopBannerSlot.winner(documentState: documentState) == nil)
        let verifying = Self.annotatedEditingDocument()
        verifying.wasPausedByBackground = true
        verifying.phase = .verified(report: .skipped)
        #expect(TopBannerSlot.winner(documentState: verifying) == nil)
    }

    @Test("What holds is read with the phase aside")
    func holdingLeavesThePhaseAside() {
        let verifying = Self.annotatedEditingDocument()
        verifying.wasPausedByBackground = true
        verifying.phase = .verified(report: .skipped)
        #expect(TopBannerSlot.holding(documentState: verifying) == [.paused, .importAnnotations])
        verifying.annotationNoticeDismissed = true
        #expect(TopBannerSlot.holding(documentState: verifying) == [.paused])
    }

    /// One state of the editor's sheet slot, its inputs to the band's rule,
    /// and the phases in which the band shows.
    private struct SlotState {
        let name: String
        let slotPresents: Bool
        let searchIsTheSheet: Bool
        let detent: PresentationDetent
        let shownIn: Set<DocumentState.PhaseKind>
    }

    @Test("The band shows only while editing with no sheet above the parked height")
    func bandIsShownTable() {
        let phases: [DocumentState.PhaseKind] = [
            .empty, .importing, .editing, .detecting, .redacting, .verifying, .verified, .exporting, .failed,
        ]
        // Each slot state, its inputs, and the phases in which the band shows.
        let slotStates: [SlotState] = [
            SlotState(name: "H-1 no sheet", slotPresents: false, searchIsTheSheet: false,
                      detent: .medium, shownIn: [.editing]),
            SlotState(name: "H-2 Search parked", slotPresents: true, searchIsTheSheet: true,
                      detent: .compactFloat, shownIn: [.editing]),
            SlotState(name: "H-3 Search at medium", slotPresents: true, searchIsTheSheet: true,
                      detent: .medium, shownIn: []),
            SlotState(name: "H-3 Search at large", slotPresents: true, searchIsTheSheet: true,
                      detent: .large, shownIn: []),
            SlotState(name: "H-4 the rationale sheet", slotPresents: true, searchIsTheSheet: false,
                      detent: .compactFloat, shownIn: []),
        ]
        var rows = 0
        for state in slotStates {
            for phase in phases {
                let shown = TopBannerSlot.bandIsShown(
                    phase: phase, slotPresents: state.slotPresents,
                    searchIsTheSheet: state.searchIsTheSheet, searchDetent: state.detent)
                #expect(shown == state.shownIn.contains(phase), "\(state.name), \(phase)")
                rows += 1
            }
        }
        #expect(phases.count == 9)
        #expect(rows == 45)
    }

    @Test("Hiding the band leaves every notice in place")
    func hidingEndsNothing() {
        let documentState = Self.annotatedEditingDocument()
        documentState.wasPausedByBackground = true
        let before = TopBannerSlot.holding(documentState: documentState)
        #expect(TopBannerSlot.winner(documentState: documentState) == .paused)
        // Search rises to medium: the band hides.
        #expect(!TopBannerSlot.bandIsShown(
            phase: documentState.phaseKind, slotPresents: true, searchIsTheSheet: true, searchDetent: .medium))
        // Search parks: the band shows the same occupant, and nothing has ended.
        #expect(TopBannerSlot.bandIsShown(
            phase: documentState.phaseKind, slotPresents: true, searchIsTheSheet: true, searchDetent: .compactFloat))
        #expect(TopBannerSlot.winner(documentState: documentState) == .paused)
        #expect(TopBannerSlot.holding(documentState: documentState) == before)
        #expect(documentState.wasPausedByBackground)
        #expect(!documentState.annotationNoticeDismissed)
    }

    @Test("The annotation notice's visibility reads its own facts only")
    func annotationVisibilityReadsItsOwnFacts() {
        #expect(ImportAnnotationNoticeBanner.isVisible(
            phaseKind: .editing, annotationTypeCount: 1, dismissed: false))
        #expect(!ImportAnnotationNoticeBanner.isVisible(
            phaseKind: .editing, annotationTypeCount: 1, dismissed: true))
    }
}
