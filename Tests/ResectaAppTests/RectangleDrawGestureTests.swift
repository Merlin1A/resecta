import Testing
import UIKit
import CoreGraphics
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// Rectangle draw-tool gesture surgery (1.1.0 draw-tool S1; D-109 / RB-74..76).
//
// Pins the six overlay-side fixes in `RedactionOverlayView`:
//   S1-a  repaint on gesture end — `resetDragState()` ends with
//         `setNeedsDisplay()`, so a rejected rubber band (DT-01) and the
//         lifted look after a move/resize (DT-02) cannot outlive the gesture;
//   S1-b  anchored-edge snapping while drawing (DT-03) — the new-region path
//         snaps through `applyResizeSnapping` with `drawSnapHandle`, so only
//         the two edges under the finger move and the origin corner is
//         invariant;
//   S1-c  the rubber band is clamped to the page (DT-08);
//   S1-d  primary-touch identity (DT-10) — a foreign touch never moves,
//         ends or cancels the primary's gesture;
//   S1-e  the rect tracks the finger back inside the 8-pt start gate (DT-11);
//   S1-f  the marquee never runs in draw mode (DT-07, overlay half).
//
// Geometry: a 400×400 overlay, so 1 overlay pt = 0.0025 normalized. Snap
// targets are other regions' edges + midlines, the 16-pt page margins and
// the page centre lines (200); `ResectaTokens.Snap.proximityThreshold` is
// 10 pt. Every fixture keeps its unintended edges ≥ 10 pt clear of every
// target so only the named snap can fire.

@Suite("Rectangle draw gesture surgery (S1)")
@MainActor
struct RectangleDrawGestureTests {

    private static let overlaySize = CGSize(width: 400, height: 400)
    private static let tolerance: CGFloat = 1e-6

    private func makeOverlay(
        drawing: Bool = true,
        regions: [RedactionRegion] = [],
        selectedIDs: Set<UUID> = []
    ) -> (overlay: RedactionOverlayView, coordinator: RecordingCoordinator) {
        let overlay = RedactionOverlayView(
            frame: CGRect(origin: .zero, size: Self.overlaySize)
        )
        overlay.isDrawingMode = drawing
        overlay.activeShapeTool = .rectangle
        overlay.snapToTextEnabled = false
        let coordinator = RecordingCoordinator()
        overlay.coordinator = coordinator
        overlay.configure(with: regions, selectedIDs: selectedIDs)
        return (overlay, coordinator)
    }

    /// Drive ONE touch identity through began → moved… → ended.
    private func drag(
        _ overlay: RedactionOverlayView,
        from origin: CGPoint,
        through points: [CGPoint]
    ) {
        let touch = StubTouch(location: origin, view: overlay)
        overlay.touchesBegan([touch], with: nil)
        for point in points {
            touch.move(to: point)
            overlay.touchesMoved([touch], with: nil)
        }
        overlay.touchesEnded([touch], with: nil)
    }

    private func expectClose(
        _ actual: CGFloat, _ expected: CGFloat, _ label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(abs(actual - expected) < Self.tolerance,
                "\(label)=\(actual), expected ~\(expected)",
                sourceLocation: sourceLocation)
    }

    // MARK: - S1-a repaint on gesture end

    @Test("S1-a: a rejected sub-threshold rubber band schedules a repaint on touch-up (DT-01)")
    func testRejectedDragRepaintsOnEnd() {
        let (overlay, coordinator) = makeOverlay()
        let touch = StubTouch(location: CGPoint(x: 100, y: 100), view: overlay)
        overlay.touchesBegan([touch], with: nil)
        // Past the 8-pt start gate (a band is painted), under the 20-pt
        // commit floor (the band is rejected on touch-up).
        touch.move(to: CGPoint(x: 112, y: 112))
        overlay.touchesMoved([touch], with: nil)
        #expect(overlay.currentDragRect == CGRect(x: 100, y: 100, width: 12, height: 12))

        overlay.layer.displayIfNeeded()
        #expect(overlay.layer.needsDisplay() == false,
                "precondition: the mid-drag repaint was flushed")

        overlay.touchesEnded([touch], with: nil)
        #expect(coordinator.addedRegions.isEmpty)
        #expect(overlay.currentDragRect == nil)
        #expect(overlay.isActivelyDragging == false)
        #expect(overlay.layer.needsDisplay(),
                "resetDragState must schedule the repaint that erases the ghost band, label and guides")
    }

    @Test("S1-a: a move commit on a selected region schedules a repaint on touch-up (DT-02)")
    func testMoveCommitRepaintsOnEnd() {
        // 200×200 overlay-pt region centred on the page (overlay rect
        // 100…300 × 100…300). The touch lands at its centre, ≥ 77 pt from
        // every 46-pt handle box, so touch-down begins an immediate move
        // (already single-selected, draw tool off).
        let region = RedactionRegion.mock(
            rect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        )
        let (overlay, coordinator) = makeOverlay(
            drawing: false, regions: [region], selectedIDs: [region.id]
        )
        let touch = StubTouch(location: CGPoint(x: 200, y: 200), view: overlay)
        overlay.touchesBegan([touch], with: nil)
        #expect(overlay.isActivelyDragging, "touch-down inside the selected body begins a move")
        touch.move(to: CGPoint(x: 240, y: 230))
        overlay.touchesMoved([touch], with: nil)

        overlay.layer.displayIfNeeded()
        #expect(overlay.layer.needsDisplay() == false,
                "precondition: the mid-drag repaint was flushed")

        overlay.touchesEnded([touch], with: nil)
        #expect(coordinator.movedRegions.count == 1)
        #expect(coordinator.movedRegions.first?.id == region.id)
        #expect(coordinator.addedRegions.isEmpty)
        #expect(overlay.isActivelyDragging == false)
        #expect(overlay.layer.needsDisplay(),
                "resetDragState must schedule the repaint that drops the lifted look and restores the handles")
    }

    // MARK: - S1-b anchored-edge snapping

    @Test("S1-b: drawSnapHandle maps the finger's quadrant to the handle whose two edges move")
    func testDrawSnapHandleQuadrants() {
        let origin = CGPoint(x: 100, y: 100)
        #expect(RedactionOverlayView.drawSnapHandle(
            origin: origin, point: CGPoint(x: 150, y: 150)) == .bottomRight)
        #expect(RedactionOverlayView.drawSnapHandle(
            origin: origin, point: CGPoint(x: 150, y: 50)) == .topRight)
        #expect(RedactionOverlayView.drawSnapHandle(
            origin: origin, point: CGPoint(x: 50, y: 150)) == .bottomLeft)
        #expect(RedactionOverlayView.drawSnapHandle(
            origin: origin, point: CGPoint(x: 50, y: 50)) == .topLeft)
        // Ties (dx == 0 / dy == 0) resolve to the bottom/right side.
        #expect(RedactionOverlayView.drawSnapHandle(
            origin: origin, point: origin) == .bottomRight)
        #expect(RedactionOverlayView.drawSnapHandle(
            origin: origin, point: CGPoint(x: 100, y: 50)) == .topRight)
        #expect(RedactionOverlayView.drawSnapHandle(
            origin: origin, point: CGPoint(x: 50, y: 100)) == .bottomLeft)
    }

    @Test("S1-b: the far edge snaps to a neighbour's edge while the origin corner stays put (DT-03)")
    func testFarEdgeSnapsWithoutMovingTheOrigin() {
        // Neighbour whose LEFT edge sits at x = 206, 6 pt short of the
        // drag's far edge (212) and nearer than the page-centre line (200,
        // 12 pt away). Its y-extent (340…380) and its other x-targets
        // (246, 286) are ≥ 10 pt clear of every edge of the drag.
        let neighbour = RedactionRegion.mock(
            rect: CGRect(x: 0.515, y: 0.05, width: 0.2, height: 0.1)
        )
        let (overlay, coordinator) = makeOverlay(regions: [neighbour])
        drag(overlay, from: CGPoint(x: 60, y: 60), through: [CGPoint(x: 212, y: 180)])

        #expect(coordinator.addedRegions.count == 1)
        guard let committed = coordinator.addedRegions.first?.normalizedRect else { return }
        // The old translating snapper shifted the whole band by −6
        // (minX 60 → 54). The anchored snapper moves only the far edge.
        expectClose(committed.minX, 60.0 / 400.0, "minX (origin corner)")
        expectClose(committed.maxX, 206.0 / 400.0, "maxX (snapped far edge)")
        expectClose(committed.minY, 1.0 - 180.0 / 400.0, "minY")
        expectClose(committed.maxY, 1.0 - 60.0 / 400.0, "maxY")
    }

    @Test("S1-b: a midline target near the band's centre no longer translates it")
    func testMidlineTargetDoesNotShiftTheRect() {
        // The drag spans x 60…185 (midX 122.5). A neighbour whose left
        // edge is at x = 126 sits 3.5 pt from that midpoint — the old
        // translating snapper matched `midX` and shifted the whole band by
        // +3.5. The anchored snapper only considers the finger's edges
        // (185: nearest target is the page centre at 200, 15 pt away, out
        // of band), so nothing moves.
        let neighbour = RedactionRegion.mock(
            rect: CGRect(x: 0.315, y: 0.05, width: 0.5, height: 0.1)
        )
        let (overlay, coordinator) = makeOverlay(regions: [neighbour])
        drag(overlay, from: CGPoint(x: 60, y: 60), through: [CGPoint(x: 185, y: 180)])

        #expect(coordinator.addedRegions.count == 1)
        guard let committed = coordinator.addedRegions.first?.normalizedRect else { return }
        expectClose(committed.minX, 60.0 / 400.0, "minX")
        expectClose(committed.maxX, 185.0 / 400.0, "maxX")
        expectClose(committed.minY, 1.0 - 180.0 / 400.0, "minY")
        expectClose(committed.maxY, 1.0 - 60.0 / 400.0, "maxY")
    }

    // MARK: - S1-c page-bounds clamp

    @Test("S1-c: a drag past the page edge commits the band clipped to the page (DT-08)")
    func testOffPageDragIsClampedToBounds() {
        let (overlay, coordinator) = makeOverlay()
        let touch = StubTouch(location: CGPoint(x: 300, y: 300), view: overlay)
        overlay.touchesBegan([touch], with: nil)
        touch.move(to: CGPoint(x: 450, y: 450))   // 50 pt past both page edges
        overlay.touchesMoved([touch], with: nil)
        #expect(overlay.currentDragRect == CGRect(x: 300, y: 300, width: 100, height: 100),
                "the live band is clipped, so the off-page handle stays grabbable")
        overlay.touchesEnded([touch], with: nil)

        #expect(coordinator.addedRegions.count == 1)
        guard let committed = coordinator.addedRegions.first?.normalizedRect else { return }
        let clipped = overlay.overlayToPDFNormalized(
            CGRect(x: 300, y: 300, width: 100, height: 100)
        )
        expectClose(committed.minX, clipped.minX, "minX")
        expectClose(committed.minY, clipped.minY, "minY")
        expectClose(committed.width, clipped.width, "width")
        expectClose(committed.height, clipped.height, "height")
        #expect(committed.minX >= 0 && committed.maxX <= 1
                && committed.minY >= 0 && committed.maxY <= 1,
                "committed normalized rect must stay within [0, 1]")
    }

    // MARK: - S1-d primary-touch identity

    @Test("S1-d: a second finger's move does not steer the rubber band (DT-10)")
    func testForeignTouchMoveIsIgnored() {
        let (overlay, _) = makeOverlay()
        let primary = StubTouch(location: CGPoint(x: 60, y: 60), view: overlay)
        overlay.touchesBegan([primary], with: nil)
        primary.move(to: CGPoint(x: 150, y: 150))
        overlay.touchesMoved([primary], with: nil)
        let before = overlay.currentDragRect
        #expect(before == CGRect(x: 60, y: 60, width: 90, height: 90))

        let foreign = StubTouch(location: CGPoint(x: 300, y: 300), view: overlay)
        overlay.touchesMoved([foreign], with: nil)
        #expect(overlay.currentDragRect == before,
                "a foreign touch must leave the band where the primary left it")

        // A set carrying both fingers still follows the primary.
        primary.move(to: CGPoint(x: 160, y: 170))
        overlay.touchesMoved([foreign, primary], with: nil)
        #expect(overlay.currentDragRect == CGRect(x: 60, y: 60, width: 100, height: 110))

        overlay.touchesEnded([primary], with: nil)
        #expect(overlay.isActivelyDragging == false)
    }

    @Test("S1-d: a second finger's lift neither commits nor ends the gesture; the primary's lift commits")
    func testForeignTouchEndIsIgnored() {
        let (overlay, coordinator) = makeOverlay()
        let primary = StubTouch(location: CGPoint(x: 60, y: 60), view: overlay)
        overlay.touchesBegan([primary], with: nil)
        primary.move(to: CGPoint(x: 150, y: 150))
        overlay.touchesMoved([primary], with: nil)

        let foreign = StubTouch(location: CGPoint(x: 300, y: 300), view: overlay)
        overlay.touchesEnded([foreign], with: nil)
        #expect(coordinator.addedRegions.isEmpty, "a foreign lift must not commit")
        #expect(overlay.isActivelyDragging, "a foreign lift must not reset the gesture")
        #expect(overlay.currentDragRect == CGRect(x: 60, y: 60, width: 90, height: 90))

        overlay.touchesCancelled([foreign], with: nil)
        #expect(overlay.isActivelyDragging, "a foreign cancel must not discard the gesture")
        #expect(overlay.currentDragRect == CGRect(x: 60, y: 60, width: 90, height: 90))

        overlay.touchesEnded([primary], with: nil)
        #expect(coordinator.addedRegions.count == 1, "the primary's own lift still commits")
        #expect(overlay.isActivelyDragging == false)
        #expect(overlay.currentDragRect == nil)
    }

    // MARK: - S1-e rect tracks the finger back

    @Test("S1-e: the band follows the finger back inside the start gate and a returned drag commits nothing (DT-11)")
    func testRectTracksTheFingerBack() {
        let (overlay, coordinator) = makeOverlay()
        let touch = StubTouch(location: CGPoint(x: 100, y: 100), view: overlay)
        overlay.touchesBegan([touch], with: nil)

        // The 8-pt start gate still holds before the first over-threshold move.
        touch.move(to: CGPoint(x: 105, y: 105))
        overlay.touchesMoved([touch], with: nil)
        #expect(overlay.currentDragRect == nil, "under the start gate: no band yet")

        touch.move(to: CGPoint(x: 130, y: 130))
        overlay.touchesMoved([touch], with: nil)
        #expect(overlay.currentDragRect == CGRect(x: 100, y: 100, width: 30, height: 30))

        touch.move(to: CGPoint(x: 103, y: 103))
        overlay.touchesMoved([touch], with: nil)
        #expect(overlay.currentDragRect == CGRect(x: 100, y: 100, width: 3, height: 3),
                "the band must shrink with the finger, not freeze at the last over-threshold rect")

        overlay.touchesEnded([touch], with: nil)
        #expect(coordinator.addedRegions.isEmpty,
                "a 3×3 band is below the 20-pt commit floor — nothing commits")
        #expect(overlay.currentDragRect == nil)
    }

    // MARK: - S1-f marquee never runs in draw mode

    @Test("S1-f: with Add to Selection left on, a draw-mode drag draws a region and never runs the marquee (DT-07)")
    func testMarqueeDoesNotRunInDrawMode() {
        let (overlay, coordinator) = makeOverlay()
        overlay.isMultiSelectActive = true
        drag(overlay, from: CGPoint(x: 60, y: 60), through: [CGPoint(x: 150, y: 150)])
        #expect(coordinator.addedRegions.count == 1, "draw mode draws")
        #expect(coordinator.lassoCommits.isEmpty, "no lasso commit in draw mode")

        // Regression pin for the marquee itself: draw tool OFF, toggle ON,
        // empty-space drag → one lasso commit, no region.
        let (marqueeOverlay, marqueeCoordinator) = makeOverlay(drawing: false)
        marqueeOverlay.isMultiSelectActive = true
        drag(marqueeOverlay, from: CGPoint(x: 60, y: 60), through: [CGPoint(x: 150, y: 150)])
        #expect(marqueeCoordinator.lassoCommits.count == 1, "tool off: the marquee still runs")
        #expect(marqueeCoordinator.addedRegions.isEmpty)
    }
}
