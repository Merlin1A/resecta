import Testing
import Foundation
@testable import ResectaApp

// The editor's one top-banner slot: the paused notice, the scan summary and
// the import annotation notice share the canvas's top edge and show one at a
// time — paused first, then the scan summary, then the annotation notice.
// The precedence has one home (`TopBannerSlot`); the annotation notice's own
// visibility reads only its own facts.

@MainActor
@Suite("Editor top-banner slot")
struct TopBannerSlotTests {

    @Test("Paused beats the scan summary, which beats the annotation notice; nothing shows with none up")
    func precedence() {
        #expect(TopBannerSlot.winner(paused: true, detection: true, annotation: true) == .paused)
        #expect(TopBannerSlot.winner(paused: true, detection: false, annotation: true) == .paused)
        #expect(TopBannerSlot.winner(paused: false, detection: true, annotation: true) == .detection)
        #expect(TopBannerSlot.winner(paused: false, detection: false, annotation: true) == .annotation)
        #expect(TopBannerSlot.winner(paused: false, detection: false, annotation: false) == nil)
    }

    /// An editing document whose source carries a filled form field, so the
    /// annotation notice is owed.
    private static func annotatedEditingDocument() -> DocumentState {
        let documentState = DocumentState()
        documentState.phase = .editing
        documentState.sourceFilledFormFieldCount = 1
        return documentState
    }

    @Test("The editor's read: a paused run takes the slot over the scan summary and the annotation notice")
    func pausedTakesTheSlot() {
        let documentState = Self.annotatedEditingDocument()
        documentState.wasPausedByBackground = true
        #expect(TopBannerSlot.winner(documentState: documentState, detectionBannerPresent: true) == .paused)
    }

    @Test("The editor's read: the scan summary waits for the paused notice, then takes the slot over the annotation notice")
    func detectionFollowsPaused() {
        let documentState = Self.annotatedEditingDocument()
        #expect(TopBannerSlot.winner(documentState: documentState, detectionBannerPresent: true) == .detection)
        #expect(TopBannerSlot.winner(documentState: documentState, detectionBannerPresent: false) == .annotation)
    }

    @Test("The editor's read: a dismissed annotation notice and a phase other than editing leave the slot empty")
    func emptySlot() {
        let documentState = Self.annotatedEditingDocument()
        documentState.annotationNoticeDismissed = true
        #expect(TopBannerSlot.winner(documentState: documentState, detectionBannerPresent: false) == nil)
        let verifying = Self.annotatedEditingDocument()
        verifying.wasPausedByBackground = true
        verifying.phase = .verified(report: .skipped)
        #expect(TopBannerSlot.winner(documentState: verifying, detectionBannerPresent: true) == nil)
    }

    @Test("The annotation notice's visibility reads its own facts only")
    func annotationVisibilityReadsItsOwnFacts() {
        #expect(ImportAnnotationNoticeBanner.isVisible(
            phaseKind: .editing, annotationTypeCount: 1, dismissed: false))
        #expect(!ImportAnnotationNoticeBanner.isVisible(
            phaseKind: .editing, annotationTypeCount: 1, dismissed: true))
    }
}
