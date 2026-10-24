import Testing
import UIKit
import CoreGraphics
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// The resize gesture's outcomes, driven through the real overlay touch
// path into the real coordinator and the real region state: a cancelled
// resize leaves the region where it began, a resize dragged across the
// opposite edge flips about the crossed edge, a snapped edge is never left
// under the resize floor, and with Add to Selection on a tap on a
// neighbour inside the selected region's handle box adds the neighbour
// instead of resizing the selected region.
//
// Geometry: a 400×400 overlay, so 1 overlay pt = 0.0025 normalized, at
// zoom 1.0 (no PDFView ancestor): the handle box is 46 pt (half 23), the
// snap band 10 pt and the resize floor 8 pt across a box 20 or more long. Snap targets are the other
// regions' edges and midlines, the 16-pt page margins and the page centre
// lines (200). Region A is the centred square, overlay 100…300 × 100…300;
// its right-centre handle sits at (300, 200).

@Suite("Overlay resize cancel and geometry", .tags(.overlay))
@MainActor
struct OverlayCancelAndHapticTests {

    private static let overlaySize = CGSize(width: 400, height: 400)
    private static let tolerance: CGFloat = 1e-6
    /// The resize floor at 1.0× across a box whose other side carries the
    /// long one (`RegionSizeFloor`), in overlay points.
    private static let resizeFloorAtUnitZoom: CGFloat = 8

    /// The overlay under test, the coordinator it commits through and the
    /// state that coordinator writes, held together so the coordinator —
    /// the overlay's `weak` reference — lives while the test reads the
    /// state.
    private struct Canvas {
        let overlay: RedactionOverlayView
        let coordinator: PDFViewCoordinator
        let state: RedactionState
    }

    private static func regionA() -> RedactionRegion {
        RedactionRegion.mock(rect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
    }

    private func makeCanvas(
        regions: [RedactionRegion],
        selectedIDs: Set<UUID>,
        addToSelection: Bool = false
    ) -> Canvas {
        let state = RedactionState()
        for region in regions {
            state.addRegion(region, page: 0, undoManager: nil)
        }
        state.selectedRegionIDs = selectedIDs
        let coordinator = PDFViewCoordinator()
        coordinator.redactionState = state
        coordinator.isMultiSelectActive = addToSelection
        let overlay = RedactionOverlayView(frame: CGRect(origin: .zero, size: Self.overlaySize))
        overlay.pageIndex = 0
        overlay.isDrawingMode = false
        overlay.activeShapeTool = .rectangle
        overlay.isMultiSelectActive = addToSelection
        overlay.coordinator = coordinator
        overlay.configure(with: state.regions[0] ?? [], selectedIDs: state.selectedRegionIDs)
        return Canvas(overlay: overlay, coordinator: coordinator, state: state)
    }

    /// Press ONE touch identity at `start` and move it through `points`;
    /// the caller lifts or cancels it.
    private func press(
        _ overlay: RedactionOverlayView,
        at start: CGPoint,
        through points: [CGPoint]
    ) -> StubTouch {
        let touch = StubTouch(location: start, view: overlay)
        overlay.touchesBegan([touch], with: nil)
        for point in points {
            touch.move(to: point)
            overlay.touchesMoved([touch], with: nil)
        }
        return touch
    }

    private func storedRect(_ id: UUID, in state: RedactionState) -> CGRect? {
        state.regions[0]?.first(where: { $0.id == id })?.normalizedRect
    }

    private func expectSameRect(
        _ actual: CGRect?, _ expected: CGRect, _ label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let actual else {
            Issue.record("\(label): the region is gone", sourceLocation: sourceLocation)
            return
        }
        let close = abs(actual.minX - expected.minX) < Self.tolerance
            && abs(actual.minY - expected.minY) < Self.tolerance
            && abs(actual.width - expected.width) < Self.tolerance
            && abs(actual.height - expected.height) < Self.tolerance
        #expect(close, "\(label)=\(actual), expected ~\(expected)", sourceLocation: sourceLocation)
    }

    // MARK: - Cancel

    @Test("A resize cancelled mid-drag leaves the region at its pre-resize rect, drawn and stored")
    func cancelledResizeRestoresThePreResizeRect() {
        let region = Self.regionA()
        let canvas = makeCanvas(regions: [region], selectedIDs: [region.id])
        let version = canvas.state.regionVersion

        // The right-centre handle, dragged 60 pt right in two moves.
        let touch = press(canvas.overlay, at: CGPoint(x: 300, y: 200),
                          through: [CGPoint(x: 340, y: 200), CGPoint(x: 360, y: 200)])
        #expect(canvas.overlay.isActivelyDragging, "touch-down on the handle begins a resize")
        #expect(canvas.overlay.regions.first(where: { $0.id == region.id })?.normalizedRect
                    != region.normalizedRect,
                "precondition: the drawn rect followed the finger")

        canvas.overlay.touchesCancelled([touch], with: nil)

        expectSameRect(canvas.overlay.regions.first(where: { $0.id == region.id })?.normalizedRect,
                       region.normalizedRect, "the drawn rect after the cancel")
        expectSameRect(storedRect(region.id, in: canvas.state), region.normalizedRect,
                       "the stored rect after the cancel")
        #expect(canvas.state.regionVersion == version, "a cancel commits nothing")
        #expect(canvas.overlay.isActivelyDragging == false)
    }

    // MARK: - Crossing the opposite edge

    @Test("A resize dragged past the opposite edge flips about the crossed edge")
    func resizePastTheOppositeEdgeFlips() {
        let region = Self.regionA()
        let canvas = makeCanvas(regions: [region], selectedIDs: [region.id])

        // The right-centre handle (300, 200) dragged across the left edge
        // (100) to x = 50: the crossed edge becomes the anchor and the box
        // spans 50…100 — never 100…150, the width mirrored onto the old side.
        let touch = press(canvas.overlay, at: CGPoint(x: 300, y: 200),
                          through: [CGPoint(x: 150, y: 200), CGPoint(x: 50, y: 200)])
        canvas.overlay.touchesEnded([touch], with: nil)

        expectSameRect(storedRect(region.id, in: canvas.state),
                       CGRect(x: 0.125, y: 0.25, width: 0.125, height: 0.5),
                       "the committed rect")
    }

    // MARK: - The floor holds after the snap

    @Test("A snapped edge never leaves the box under the resize floor")
    func snapNeverPullsTheBoxUnderTheFloor() {
        let region = Self.regionA()
        // A neighbour below A, overlay 103…143 × 320…360: its left edge
        // (x = 103) sits inside the 10-pt snap band of a right edge the
        // floor holds at 108, and it is clear of the touch.
        let neighbour = RedactionRegion.mock(rect: CGRect(x: 0.2575, y: 0.1, width: 0.1, height: 0.1))
        let canvas = makeCanvas(regions: [region, neighbour], selectedIDs: [region.id])

        // The right-centre handle dragged to x = 102: a 2-pt box.
        let touch = press(canvas.overlay, at: CGPoint(x: 300, y: 200),
                          through: [CGPoint(x: 102, y: 200)])
        canvas.overlay.touchesEnded([touch], with: nil)

        guard let committed = storedRect(region.id, in: canvas.state) else {
            Issue.record("the resized region is gone")
            return
        }
        let widthInPoints = committed.width * Self.overlaySize.width
        #expect(widthInPoints >= Self.resizeFloorAtUnitZoom - Self.tolerance,
                "the committed width is \(widthInPoints) pt, under the \(Self.resizeFloorAtUnitZoom)-pt floor")
        #expect(abs(committed.minX - 0.25) < Self.tolerance, "the anchored left edge stays put")
        #expect(abs(committed.height - 0.5) < Self.tolerance, "the floor acts on the handle's axis only")
    }

    // MARK: - Add to Selection over a handle box

    @Test("With Add to Selection on, a tap on a neighbour inside the selected region's handle box adds the neighbour and resizes nothing")
    func addToSelectionTapInsideAHandleBoxAddsTheNeighbour() {
        let region = Self.regionA()
        // A neighbour right of A, overlay 310…370 × 180…220: its body covers
        // part of A's right-centre handle box (277…323 × 177…223) and none
        // of A's own hit area (92…308).
        let neighbour = RedactionRegion.mock(rect: CGRect(x: 0.775, y: 0.45, width: 0.15, height: 0.1))
        let canvas = makeCanvas(
            regions: [region, neighbour], selectedIDs: [region.id], addToSelection: true
        )
        let version = canvas.state.regionVersion

        // A tap at (315, 200) whose finger wobbles 3 pt before the lift.
        let touch = press(canvas.overlay, at: CGPoint(x: 315, y: 200),
                          through: [CGPoint(x: 318, y: 200)])
        canvas.overlay.touchesEnded([touch], with: nil)

        #expect(canvas.state.selectedRegionIDs == [region.id, neighbour.id],
                "the tap adds the neighbour to the selection")
        expectSameRect(storedRect(region.id, in: canvas.state), region.normalizedRect,
                       "the selected region's rect")
        #expect(canvas.state.regionVersion == version, "no resize is committed")
    }

    // MARK: - Group move at the page edge

    @Test("A group move stopped by the page edge keeps the spacing between its regions")
    func groupMoveAtTheEdgeKeepsTheSpacing() {
        // A at the left edge (overlay 0…100 × 160…240), B beside it
        // (150…250 × 160…240); both selected.
        let a = RedactionRegion.mock(rect: CGRect(x: 0, y: 0.4, width: 0.25, height: 0.2))
        let b = RedactionRegion.mock(rect: CGRect(x: 0.375, y: 0.4, width: 0.25, height: 0.2))
        let canvas = makeCanvas(regions: [a, b], selectedIDs: [a.id, b.id])

        // Drag A 150 pt further left than the edge allows.
        let touch = press(canvas.overlay, at: CGPoint(x: 50, y: 200),
                          through: [CGPoint(x: -100, y: 200)])
        canvas.overlay.touchesEnded([touch], with: nil)

        expectSameRect(storedRect(a.id, in: canvas.state), a.normalizedRect, "A, held by the edge")
        expectSameRect(storedRect(b.id, in: canvas.state), b.normalizedRect,
                       "B keeps its distance from A")
    }

    // MARK: - The long-press preview

    @Test("The overlay supplies the long-press menu's highlight preview")
    func contextMenuSuppliesAHighlightPreview() {
        let overlay = RedactionOverlayView(frame: CGRect(origin: .zero, size: Self.overlaySize))
        #expect(overlay.responds(to: NSSelectorFromString(
            "contextMenuInteraction:previewForHighlightingMenuWithConfiguration:")))
    }
}
