import Testing
import Foundation
@testable import ResectaApp

// Canvas polish bundle. Three independently-scoped
// sub-fixes pinned by string-literal / predicate / shape tests so each
// one can fail in isolation if a future tweak drifts the message or
// the gating shape.

@Suite("Canvas polish bundle")
@MainActor
struct CanvasPolishBundleTests {

    // MARK: - Sub-threshold VoiceOver string

    @Test("Sub-threshold rejection names the remedy, not the floor")
    func subThresholdAnnouncementNamesTheRemedy() {
        // The floor is in screen points, so a number in the copy is wrong
        // at any zoom but 1×; the copy says what to do instead.
        #expect(
            RedactionOverlayView.subThresholdRejectionAnnouncement
            == "Region too small. Zoom in to draw a smaller region."
        )
        #expect(RedactionOverlayView.subThresholdRejectionAnnouncement
            .range(of: #"\d"#, options: .regularExpression) == nil)
    }

    @Test("The too-small notice reaches the toast queue through the coordinator")
    func tooSmallNoticeGoesThroughTheCoordinator() {
        let coordinator = PDFViewCoordinator()
        #expect(coordinator.noteRegionTooSmall() == false, "no queue attached: the overlay speaks it")
        let toasts = ToastQueueManager()
        coordinator.toastManager = toasts
        #expect(coordinator.noteRegionTooSmall())
        #expect(toasts.activeToasts.map(\.message) == [RedactionOverlayView.subThresholdRejectionAnnouncement])
    }

    // MARK: - Drawing-mode caption predicate

    @Test("Caption is visible only with rectangle tool active in editing phase")
    func captionVisibleOnlyDuringRectangleEditing() {
        #expect(DocumentEditorView.drawingModeCaptionShouldShow(
            activeTool: .rectangle, phaseKind: .editing
        ) == true)
    }

    @Test("Caption hides when no tool is active")
    func captionHidesWithNoActiveTool() {
        #expect(DocumentEditorView.drawingModeCaptionShouldShow(
            activeTool: nil, phaseKind: .editing
        ) == false)
    }

    @Test("Caption hides outside the editing phase even with the tool on")
    func captionHidesOutsideEditingPhase() {
        // The detecting / redacting / verifying phases blur the canvas
        // underneath their own progress card, so the caption underneath
        // would be stale — gate it on the editing phase.
        let nonEditingPhases: [DocumentState.PhaseKind] = [
            .empty, .importing, .detecting,
            .redacting, .verifying, .exporting, .failed,
        ]
        for phase in nonEditingPhases {
            #expect(DocumentEditorView.drawingModeCaptionShouldShow(
                activeTool: .rectangle, phaseKind: phase
            ) == false)
        }
    }

    @Test("Caption copy names the gesture mechanism (no outcome verb)")
    func captionMechanismDescription() {
        // Mechanism-description language — names the gesture, not
        // a promised outcome. "Drag to draw" names what one finger does and
        // "two fingers to scroll" names the other gesture; the user supplies
        // the intent.
        #expect(DocumentEditorView.drawingModeCaption == "Drag to draw · two fingers to scroll")
    }
}
