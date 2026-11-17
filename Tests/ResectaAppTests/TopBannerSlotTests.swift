import Testing
import Foundation
@testable import ResectaApp

// The editor's one top-banner slot: the paused notice and the import
// annotation notice share the canvas's top edge and show one at a time,
// paused first. The precedence has one home (`TopBannerSlot`); the
// annotation notice's own visibility reads only its own facts.

@MainActor
@Suite("Editor top-banner slot")
struct TopBannerSlotTests {

    @Test("Paused beats the annotation notice; nothing shows with neither up: every pair of inputs")
    func precedence() {
        let rows: [(paused: Bool, annotation: Bool, winner: TopBannerSlot?)] = [
            (paused: false, annotation: false, winner: nil),
            (paused: false, annotation: true, winner: .annotation),
            (paused: true, annotation: false, winner: .paused),
            (paused: true, annotation: true, winner: .paused),
        ]
        #expect(rows.count == 4)
        for row in rows {
            #expect(TopBannerSlot.winner(paused: row.paused, annotation: row.annotation) == row.winner,
                    "paused \(row.paused), annotation \(row.annotation)")
        }
    }

    /// An editing document whose source carries a filled form field, so the
    /// annotation notice is owed.
    private static func annotatedEditingDocument() -> DocumentState {
        let documentState = DocumentState()
        documentState.phase = .editing
        documentState.sourceFilledFormFieldCount = 1
        return documentState
    }

    @Test("The editor's read: a paused run takes the slot over the annotation notice")
    func pausedTakesTheSlot() {
        let documentState = Self.annotatedEditingDocument()
        documentState.wasPausedByBackground = true
        #expect(TopBannerSlot.winner(documentState: documentState) == .paused)
    }

    @Test("The editor's read: with no pause, the annotation notice takes the slot")
    func annotationTakesTheSlotWithNoPause() {
        let documentState = Self.annotatedEditingDocument()
        #expect(TopBannerSlot.winner(documentState: documentState) == .annotation)
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

    @Test("The annotation notice's visibility reads its own facts only")
    func annotationVisibilityReadsItsOwnFacts() {
        #expect(ImportAnnotationNoticeBanner.isVisible(
            phaseKind: .editing, annotationTypeCount: 1, dismissed: false))
        #expect(!ImportAnnotationNoticeBanner.isVisible(
            phaseKind: .editing, annotationTypeCount: 1, dismissed: true))
    }
}
