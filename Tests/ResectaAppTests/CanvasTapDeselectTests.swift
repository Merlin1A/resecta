import Testing
import Foundation
import CoreGraphics
import UIKit
import PDFKit
import Observation
import RedactionEngine
@testable import ResectaApp

// A tap on an empty part of the page clears the region selection. The
// overlay claims only regions and handles, so a tap elsewhere reaches
// PDFKit; the canvas's single-tap recognizer hands its point to the
// coordinator, which asks the overlay's own region hit test and clears
// the selection when no region is under the point. With Add to Selection
// on, or the Rectangle tool on, the tap changes nothing; an empty
// selection is never written.

@Suite("Canvas tap deselects")
@MainActor
struct CanvasTapDeselectTests {

    /// A one-page view with page 0's overlay laid over it, as the editor
    /// mounts it, at zoom 1 so the hit tolerances are in view points.
    /// Region A sits at overlay (40…160, 120…180), region B at
    /// (220…340, 120…180).
    private func mounted() -> (
        coordinator: PDFViewCoordinator, state: RedactionState,
        view: FitFlooredPDFView, window: UIWindow, a: RedactionRegion, b: RedactionRegion
    ) {
        let state = RedactionState()
        let a = RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.10, y: 0.70, width: 0.30, height: 0.10), source: .manual)
        let b = RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.55, y: 0.70, width: 0.30, height: 0.10), source: .manual)
        state.addRegion(a, page: 0, undoManager: nil)
        state.addRegion(b, page: 0, undoManager: nil)

        let coordinator = PDFViewCoordinator()
        coordinator.redactionState = state
        coordinator.documentState = DocumentState()

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let view = FitFlooredPDFView(frame: window.bounds)
        view.displayMode = .singlePage
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600))
        view.document = PDFDocument(data: renderer.pdfData { ctx in ctx.beginPage() })
        window.addSubview(view)
        window.isHidden = false

        let page = view.document!.page(at: 0)!
        let overlay = coordinator.pdfView(view, overlayViewFor: page) as! RedactionOverlayView
        overlay.frame = view.bounds
        overlay.snapZoomScaleOverride = 1
        view.addSubview(overlay)
        return (coordinator, state, view, window, a, b)
    }

    @Test("A tap on empty page clears the selection")
    func tapOnEmptyPageClears() {
        let m = mounted()
        m.state.selectedRegionIDs = [m.a.id]
        m.coordinator.handleCanvasTap(at: CGPoint(x: 200, y: 450), in: m.view)
        #expect(m.state.selectedRegionIDs.isEmpty)
    }

    @Test("A tap inside a handle's box but outside the region's hit inset clears the selection")
    func tapBesideTheRegionClears() {
        let m = mounted()
        m.state.selectedRegionIDs = [m.a.id]
        // A's top-left corner is (40, 120); its handle box reaches 22 pt
        // out, the region hit test 8 pt.
        m.coordinator.handleCanvasTap(at: CGPoint(x: 25, y: 105), in: m.view)
        #expect(m.state.selectedRegionIDs.isEmpty)
    }

    @Test("A tap on another region's body leaves the selection to the overlay")
    func tapOnARegionChangesNothing() {
        let m = mounted()
        m.state.selectedRegionIDs = [m.a.id]
        m.coordinator.handleCanvasTap(at: CGPoint(x: 280, y: 150), in: m.view)
        #expect(m.state.selectedRegionIDs == [m.a.id])
    }

    @Test("With Add to Selection on, a tap on empty page changes nothing")
    func addToSelectionMakesTheTapInert() {
        let m = mounted()
        m.state.selectedRegionIDs = [m.a.id, m.b.id]
        m.coordinator.isMultiSelectActive = true
        m.coordinator.handleCanvasTap(at: CGPoint(x: 200, y: 450), in: m.view)
        #expect(m.state.selectedRegionIDs == [m.a.id, m.b.id])
    }

    @Test("With the Rectangle tool on, a tap on empty page changes nothing")
    func drawingToolMakesTheTapInert() {
        let m = mounted()
        m.state.selectedRegionIDs = [m.a.id]
        m.coordinator.isDrawingMode = true
        m.coordinator.handleCanvasTap(at: CGPoint(x: 200, y: 450), in: m.view)
        #expect(m.state.selectedRegionIDs == [m.a.id])
    }

    @Test("A tap with nothing selected writes nothing")
    func emptySelectionIsNotWritten() {
        let m = mounted()
        let version = m.state.regionVersion
        let changed = ChangeFlag()
        withObservationTracking {
            _ = m.state.selectedRegionIDs
        } onChange: {
            changed.fired = true
        }
        m.coordinator.handleCanvasTap(at: CGPoint(x: 200, y: 450), in: m.view)
        #expect(changed.fired == false, "no observation churn on an empty selection")
        #expect(m.state.regionVersion == version)
        #expect(m.state.selectedRegionIDs.isEmpty)
    }

    @Test("The decision: only a tap on no region, with a selection, the tool off and Add to Selection off clears")
    func decisionTable() {
        let clears = PDFViewCoordinator.canvasTapClearsSelection
        #expect(clears(false, false, false, true))
        #expect(!clears(true, false, false, true), "a region under the point is the overlay's")
        #expect(!clears(false, true, false, true), "the Rectangle tool on")
        #expect(!clears(false, false, true, true), "Add to Selection on")
        #expect(!clears(false, false, false, false), "nothing selected")
    }

    @Test("The canvas's single tap waits for the double tap and leaves touches to the overlay")
    func singleTapRecognizerShape() {
        let view = FitFlooredPDFView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let taps = (view.gestureRecognizers ?? []).compactMap { $0 as? UITapGestureRecognizer }
        let single = taps.first { $0.name == FitFlooredPDFView.clearSelectionTapName }
        #expect(single != nil)
        #expect(single?.numberOfTapsRequired == 1)
        #expect(single?.cancelsTouchesInView == false)
        #expect(single?.delaysTouchesEnded == false)
        #expect(taps.contains { $0.name == FitFlooredPDFView.returnToFitGestureName }, "the double tap stays")
    }
}

/// Set by an observation's change handler, which runs off the test's
/// actor; read after the tap on the main actor.
nonisolated private final class ChangeFlag: @unchecked Sendable {
    var fired = false
}
