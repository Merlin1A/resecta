import UIKit
import CoreGraphics
@testable import ResectaApp
@testable import RedactionEngine

// Shared canvas touch harness for `RedactionOverlayView` gesture tests
// (`RectangleDrawGestureTests`).
// ONE internal copy — the pair used to live as private
// duplicates in the two older suites.
//
// The overlay keys an in-flight gesture on the primary `UITouch` instance:
// `touchesMoved` / `touchesEnded` / `touchesCancelled`
// ignore any touch that is not the one `touchesBegan` recorded. A
// began → moved → ended sequence must therefore reuse ONE `StubTouch`
// and relocate it with `move(to:)`, exactly as UIKit delivers a real
// finger — minting a fresh stub per event reads as a foreign finger.

/// Test-only coordinator that records the overlay's commit calls so the
/// drag-end paths can be asserted without mounting a real PDFView.
/// `testOverlays` mirrors the base class's private `activeOverlays`
/// dictionary so the tool-switch discard path can be exercised without
/// the PDFKit delegate callback that normally populates it.
final class RecordingCoordinator: PDFViewCoordinator {
    var addedRegions: [RedactionRegion] = []
    var movedRegions: [(id: UUID, newRect: CGRect)] = []
    var resizedRegions: [(id: UUID, newRect: CGRect)] = []
    var lassoCommits: [[RedactionRegion]] = []
    var testOverlays: [RedactionOverlayView] = []
    /// Every `selectRegion(_:)` call in order (`nil` = clear).
    var selections: [UUID?] = []
    /// Every `commitMoveMultiple` call in order — the group moves.
    var groupMoves: [[(id: UUID, newRect: CGRect)]] = []
    /// Every `toggleRegionSelection(_:)` call in order.
    var toggles: [UUID] = []

    override func selectRegion(_ id: UUID?) {
        selections.append(id)
    }

    override func commitMoveMultiple(
        _ moves: [(id: UUID, newRect: CGRect)],
        page: Int,
        undoManager: UndoManager?
    ) {
        groupMoves.append(moves)
    }

    override func toggleRegionSelection(_ id: UUID) {
        toggles.append(id)
    }

    override func addRegion(
        _ region: RedactionRegion,
        page: Int,
        undoManager: UndoManager?
    ) {
        addedRegions.append(region)
    }

    override func commitMove(
        _ id: UUID,
        page: Int,
        newRect: CGRect,
        undoManager: UndoManager?
    ) {
        movedRegions.append((id: id, newRect: newRect))
    }

    override func commitResize(
        _ id: UUID,
        page: Int,
        newRect: CGRect,
        undoManager: UndoManager?
    ) {
        resizedRegions.append((id: id, newRect: newRect))
    }

    override func commitLassoSelection(_ regions: [RedactionRegion]) {
        lassoCommits.append(regions)
    }

    override func updateActiveShapeTool(
        _ tool: RedactionOverlayView.ShapeTool
    ) {
        activeShapeTool = tool
        for overlay in testOverlays {
            overlay.activeShapeTool = tool
        }
    }
}

/// Minimal `UITouch` stub for synthesising touch sequences in tests.
/// `move(to:)` relocates the SAME instance so a began → moved → ended
/// sequence keeps one touch identity, as UIKit does.
final class StubTouch: UITouch {
    private var _location: CGPoint
    private let _view: UIView

    init(location: CGPoint, view: UIView) {
        self._location = location
        self._view = view
        super.init()
    }

    /// Relocate this touch for the next `touchesMoved` / `touchesEnded`.
    func move(to location: CGPoint) {
        _location = location
    }

    override func location(in view: UIView?) -> CGPoint {
        return _location
    }
    override var view: UIView? { _view }
}
