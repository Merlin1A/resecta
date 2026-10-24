import Testing
import Foundation
import CoreGraphics
import UIKit
import RedactionEngine
@testable import ResectaApp

// The overlay's selection gestures, driven with one StubTouch per gesture.
// Each case runs against the recording coordinator (what the overlay
// asked for) and, where the outcome matters, against a real coordinator
// and RedactionState (what the user ends up with), checking the state's
// invariants after every mutation.

@Suite("Canvas selection gestures")
@MainActor
struct CanvasSelectionGestureTests {

    private static let overlaySize = CGSize(width: 400, height: 400)

    /// Three regions side by side: A at overlay (40…120, 80…120), B at
    /// (160…240, 80…120), C at (280…360, 80…120).
    private static func threeRegions() -> [RedactionRegion] {
        [0.1, 0.4, 0.7].map {
            RedactionRegion(id: UUID(), normalizedRect: CGRect(x: $0, y: 0.7, width: 0.2, height: 0.1), source: .manual)
        }
    }

    private static let centreOfB = CGPoint(x: 200, y: 100)

    private func recordingOverlay(
        regions: [RedactionRegion], selectedIDs: Set<UUID>
    ) -> (overlay: RedactionOverlayView, coordinator: RecordingCoordinator) {
        let overlay = RedactionOverlayView(frame: CGRect(origin: .zero, size: Self.overlaySize))
        overlay.snapZoomScaleOverride = 1
        let coordinator = RecordingCoordinator()
        overlay.coordinator = coordinator
        overlay.configure(with: regions, selectedIDs: selectedIDs)
        return (overlay, coordinator)
    }

    /// A real coordinator and state with the regions on page 0, the overlay
    /// mounted in a shown window so it reaches the window's undo manager.
    /// The coordinator is returned so the test holds it: the overlay's
    /// reference to it is weak.
    private func realOverlay(
        regions: [RedactionRegion], selectedIDs: Set<UUID>
    ) throws -> (
        overlay: RedactionOverlayView, coordinator: PDFViewCoordinator,
        state: RedactionState, window: UIWindow, undo: UndoManager
    ) {
        let state = RedactionState()
        for region in regions { state.addRegion(region, page: 0, undoManager: nil) }
        state.selectedRegionIDs = selectedIDs
        let coordinator = PDFViewCoordinator()
        coordinator.redactionState = state
        let window = UIWindow(frame: CGRect(origin: .zero, size: Self.overlaySize))
        let overlay = RedactionOverlayView(frame: window.bounds)
        overlay.snapZoomScaleOverride = 1
        overlay.coordinator = coordinator
        overlay.configure(with: regions, selectedIDs: selectedIDs)
        window.addSubview(overlay)
        window.isHidden = false
        let undo = try #require(window.undoManager, "a window vends its undo manager")
        return (overlay, coordinator, state, window, undo)
    }

    private func gesture(_ overlay: RedactionOverlayView, from start: CGPoint, through points: [CGPoint] = []) {
        let touch = StubTouch(location: start, view: overlay)
        overlay.touchesBegan([touch], with: nil)
        for point in points {
            touch.move(to: point)
            overlay.touchesMoved([touch], with: nil)
        }
        overlay.touchesEnded([touch], with: nil)
    }

    // MARK: - A still tap on a group member

    @Test("A still tap on one region of a selected group selects only it, and moves nothing")
    func stillTapNarrowsTheGroup() {
        let regions = Self.threeRegions()
        let (overlay, coordinator) = recordingOverlay(regions: regions, selectedIDs: Set(regions.map(\.id)))
        gesture(overlay, from: Self.centreOfB)
        #expect(coordinator.selections.last == regions[1].id)
        #expect(coordinator.groupMoves.isEmpty)
    }

    @Test("Through the real coordinator a still tap leaves only that region selected and no undo step")
    func stillTapNarrowsTheRealSelection() throws {
        let regions = Self.threeRegions()
        let m = try realOverlay(regions: regions, selectedIDs: Set(regions.map(\.id)))
        let version = m.state.regionVersion
        gesture(m.overlay, from: Self.centreOfB)
        #expect(m.state.selectedRegionIDs == [regions[1].id])
        #expect(m.undo.canUndo == false, "no undo step")
        #expect(m.state.regionVersion == version, "nothing moved")
        m.state.checkInvariants()
    }

    @Test("A drag on one region of a selected group still moves the group and keeps the selection")
    func dragStillMovesTheGroup() {
        let regions = Self.threeRegions()
        let (overlay, coordinator) = recordingOverlay(regions: regions, selectedIDs: Set(regions.map(\.id)))
        let start = Self.centreOfB
        gesture(overlay, from: start, through: [
            CGPoint(x: start.x + 10, y: start.y),
            CGPoint(x: start.x + 30, y: start.y),
        ])
        #expect(coordinator.groupMoves.count == 1)
        #expect(coordinator.groupMoves.first?.count == 3)
        #expect(coordinator.selections.isEmpty, "the selection is kept")
    }

    // MARK: - Add to Selection edits the set on lift

    private func cancelled(_ overlay: RedactionOverlayView, at point: CGPoint) {
        let touch = StubTouch(location: point, view: overlay)
        overlay.touchesBegan([touch], with: nil)
        overlay.touchesCancelled([touch], with: nil)
    }

    @Test("With Add to Selection on, a lifted tap on a region toggles it once")
    func addToSelectionTogglesOnLift() {
        let regions = Self.threeRegions()
        let (overlay, coordinator) = recordingOverlay(regions: regions, selectedIDs: [regions[0].id])
        overlay.isMultiSelectActive = true
        let touch = StubTouch(location: Self.centreOfB, view: overlay)
        overlay.touchesBegan([touch], with: nil)
        #expect(coordinator.toggles.isEmpty, "nothing changes at touch-down")
        overlay.touchesEnded([touch], with: nil)
        #expect(coordinator.toggles == [regions[1].id])
    }

    @Test("With Add to Selection on, a cancelled touch on a region toggles nothing")
    func addToSelectionCancelTogglesNothing() {
        let regions = Self.threeRegions()
        let (overlay, coordinator) = recordingOverlay(regions: regions, selectedIDs: [regions[0].id])
        overlay.isMultiSelectActive = true
        cancelled(overlay, at: Self.centreOfB)
        #expect(coordinator.toggles.isEmpty)
    }

    @Test("Through the real coordinator a cancelled touch with Add to Selection on leaves the selection as it was")
    func addToSelectionCancelKeepsTheRealSelection() throws {
        let regions = Self.threeRegions()
        let m = try realOverlay(regions: regions, selectedIDs: [regions[0].id])
        m.overlay.isMultiSelectActive = true
        cancelled(m.overlay, at: Self.centreOfB)
        #expect(m.state.selectedRegionIDs == [regions[0].id])
        m.state.checkInvariants()
    }
}
