import Testing
import UIKit
import CoreGraphics
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// Rectangle draw-tool gesture surgery.
//
// Pins six overlay-side fixes in `RedactionOverlayView`:
//   - repaint on gesture end — `resetDragState()` ends with
//     `setNeedsDisplay()`, so a rejected rubber band and the
//     lifted look after a move/resize cannot outlive the gesture;
//   - anchored-edge snapping while drawing — the new-region path
//     snaps through `applyResizeSnapping` with `drawSnapHandle`, so only
//     the two edges under the finger move and the origin corner is
//     invariant;
//   - the rubber band is clamped to the page;
//   - primary-touch identity — a foreign touch never moves,
//     ends or cancels the primary's gesture;
//   - the rect tracks the finger back inside the 8-pt start gate;
//   - the marquee never runs in draw mode (overlay half).
//
// Geometry: a 400×400 overlay, so 1 overlay pt = 0.0025 normalized. Snap
// targets are other regions' edges + midlines, the 16-pt page margins and
// the page centre lines (200); `ResectaTokens.Snap.proximityThreshold` is
// 10 pt. Every fixture keeps its unintended edges ≥ 10 pt clear of every
// target so only the named snap can fire.

@Suite("Rectangle draw gesture surgery")
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

    // MARK: - Repaint on gesture end

    @Test("A rejected sub-threshold rubber band schedules a repaint on touch-up")
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

    @Test("A move commit on a selected region schedules a repaint on touch-up")
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

    // MARK: - Anchored-edge snapping

    @Test("drawSnapHandle maps the finger's quadrant to the handle whose two edges move")
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

    @Test("The far edge snaps to a neighbour's edge while the origin corner stays put")
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

    @Test("A midline target near the band's centre no longer translates it")
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

    // MARK: - Page-bounds clamp

    @Test("A drag past the page edge commits the band clipped to the page")
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

    // MARK: - Primary-touch identity

    @Test("A second finger's move does not steer the rubber band")
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

    @Test("A second finger's lift neither commits nor ends the gesture; the primary's lift commits")
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

    // MARK: - Rect tracks the finger back

    @Test("The band follows the finger back inside the start gate and a returned drag commits nothing")
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

    // MARK: - Marquee never runs in draw mode

    @Test("With Add to Selection left on, a draw-mode drag draws a region and never runs the marquee")
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

    @Test("The editor's tool maps to the rectangle shape, and no tool reads as the rectangle")
    func drawingToolMapsToRectangle() {
        #expect(DocumentEditorView.shapeTool(for: nil) == .rectangle)
        #expect(DocumentEditorView.shapeTool(for: .rectangle) == .rectangle)
    }

    // MARK: - Quieter guides (the snap engine)

    /// A snap page of boxes given in overlay points (top-left origin) on a
    /// 400 × 400 overlay at zoom 1.
    private static func snapPage(_ rects: [CGRect]) -> (page: SnapGuideEngine.Page, ids: [UUID]) {
        let size = overlaySize
        let regions = rects.map { r in
            RedactionRegion(id: UUID(), normalizedRect: CGRect(
                x: r.minX / size.width, y: 1 - r.maxY / size.height,
                width: r.width / size.width, height: r.height / size.height), source: .manual)
        }
        let page = SnapGuideEngine.Page(
            regions: regions, bounds: CGRect(origin: .zero, size: size), fingerScale: 1,
            toOverlay: { n in CGRect(x: n.minX * size.width, y: (1 - n.maxY) * size.height,
                                     width: n.width * size.width, height: n.height * size.height) })
        return (page, regions.map(\.id))
    }

    @Test("A box moved 3 points in a stack of one-line boxes at a 7.7-point pitch follows the finger within half a point")
    func testStackMoveFollowsTheFinger() {
        let rows = (0..<6).map { CGRect(x: 100, y: 100 + 7.7 * CGFloat($0), width: 100, height: 5) }
        let (page, ids) = Self.snapPage(rows)
        let moved = rows[2].offsetBy(dx: 0, dy: 3)
        let snapped = SnapGuideEngine().applySnapping(to: moved, excluding: ids[2], in: page)
        #expect(abs(snapped.minY - moved.minY) <= 0.5, "moved to \(moved.minY), snapped to \(snapped.minY)")
    }

    @Test("The nearest edge wins: a bottom edge 1 point from a neighbour's edge snaps, not a top edge 4 points from another")
    func testNearestEdgeWins() {
        let above = CGRect(x: 100, y: 80, width: 100, height: 16)    // its bottom at 96
        let below = CGRect(x: 100, y: 131, width: 100, height: 20)   // its top at 131
        let (page, _) = Self.snapPage([above, below])
        let moving = CGRect(x: 120, y: 100, width: 60, height: 30)  // top 100 (4 from 96), bottom 130 (1 from 131)
        let snapped = SnapGuideEngine().applySnapping(to: moving, excluding: nil, in: page)
        #expect(abs(snapped.maxY - 131) < 1e-6 && abs(snapped.height - 30) < 1e-6, "snapped \(snapped)")
    }

    @Test("No guide at the page margins or the page centre; only boxes beside the moving one on the other axis")
    func testOnlyEdgesOfBoxesBeside() {
        let (empty, _) = Self.snapPage([])
        let nearMargin = CGRect(x: 19, y: 19, width: 60, height: 30)  // 3 from the 16-point margins
        #expect(SnapGuideEngine().applySnapping(to: nearMargin, excluding: nil, in: empty) == nearMargin)
        let nearCentre = CGRect(x: 100, y: 198, width: 60, height: 30)  // its top 2 from the centre line (200)
        #expect(SnapGuideEngine().applySnapping(to: nearCentre, excluding: nil, in: empty) == nearCentre)
        // A box far to the right shares no x-range with the moving one: its top edge 2 points off is no target.
        let (farRight, _) = Self.snapPage([CGRect(x: 300, y: 102, width: 60, height: 20)])
        let moving = CGRect(x: 100, y: 100, width: 60, height: 30)
        #expect(SnapGuideEngine().applySnapping(to: moving, excluding: nil, in: farRight) == moving)
    }
}
