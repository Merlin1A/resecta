import Testing
import Foundation
import UIKit
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

    // MARK: - One on-screen size at every zoom

    /// Overlay points show at 1 / fingerScale on screen.
    private static func onScreen(_ overlayPoints: CGFloat, viewScale: CGFloat) -> CGFloat {
        overlayPoints * viewScale
    }

    @Test("The size label, the outline and the handle ring keep one on-screen size at 0.64 and 2.0")
    func onScreenSizesHoldAcrossZoom() {
        let label = "120 \u{00D7} 24" as NSString
        func sizes(_ viewScale: CGFloat) -> (pill: CGFloat, ring: CGFloat, stroke: CGFloat) {
            let fingerScale = 1 / viewScale
            return (
                Self.onScreen(RedactionOverlayView.dimensionLabelPillSize(for: label, fingerScale: fingerScale).height, viewScale: viewScale),
                Self.onScreen(RedactionOverlayView.handleRingWidth(handleScale: 1, fingerScale: fingerScale), viewScale: viewScale),
                Self.onScreen(RedactionOverlayView.regionStrokeWidth(isSelected: true, fingerScale: fingerScale), viewScale: viewScale)
            )
        }
        let fit = sizes(0.64), zoomed = sizes(2.0)
        #expect(abs(fit.pill - zoomed.pill) < 0.5, "the label's pill: \(fit.pill) at fit, \(zoomed.pill) at 2x")
        #expect(abs(fit.ring - zoomed.ring) < 0.01)
        #expect(abs(fit.stroke - 2.5) < 0.01 && abs(zoomed.stroke - 2.5) < 0.01)
    }

    @Test("The lift shadow resolves to the same colour in dark appearance as in light")
    func liftShadowShowsInDarkAppearance() {
        let shadow = RedactionOverlayView.liftShadowColor
        let light = shadow.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        let dark = shadow.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        #expect(light == dark)
        #expect(dark.cgColor.alpha >= 0.2, "a shadow on the white page reads in either appearance")
    }
}
