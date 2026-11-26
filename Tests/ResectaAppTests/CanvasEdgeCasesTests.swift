import Testing
import Foundation
import CoreGraphics
@testable import ResectaApp

// Canvas polish edge-cases: the drag-offset clamping helper. The grab
// point stays under the finger up to the overlay edge; a degenerate
// region bigger than the overlay stays pinned at the origin corner.

@Suite("Canvas edge cases")
@MainActor
struct CanvasEdgeCasesTests {

    // MARK: - Drag-offset clamping

    @Test("Touch in-bounds: origin tracks the touch minus dragOffset")
    func touchInBoundsTracksGrabPoint() {
        // Touch at (150, 150), drag offset (50, 50) (grab is 50pt from
        // top-left of the region). Region 100x100 in 400x400 overlay.
        // Origin: 150-50 = 100, 150-50 = 100.
        let origin = RedactionOverlayView.clampedDragOrigin(
            touchPoint: CGPoint(x: 150, y: 150),
            dragOffset: CGSize(width: 50, height: 50),
            regionSize: CGSize(width: 100, height: 100),
            overlaySize: CGSize(width: 400, height: 400)
        )
        #expect(origin == CGPoint(x: 100, y: 100))
    }

    @Test("Touch past right edge: grab point clamps to overlay edge")
    func touchPastRightEdgeClampsGrabPoint() {
        // Touch at (500, 200) but overlay width is 400. Touch clamps to
        // x=400. With dragOffset.width=50, newOrigin.x = 400-50 = 350.
        // Region width 100 + origin 350 = 450 > overlay 400, so origin
        // clamps to overlay-width - region-width = 300.
        let origin = RedactionOverlayView.clampedDragOrigin(
            touchPoint: CGPoint(x: 500, y: 200),
            dragOffset: CGSize(width: 50, height: 50),
            regionSize: CGSize(width: 100, height: 100),
            overlaySize: CGSize(width: 400, height: 400)
        )
        #expect(origin == CGPoint(x: 300, y: 150))
    }

    @Test("Touch past top-left corner: both axes clamp into the overlay")
    func touchPastTopLeftClampsBothAxes() {
        // Touch at (-30, -30). Clamped touch (0, 0). newOrigin = (0-50,
        // 0-50) = (-50, -50). Outer max(0, …) pins origin to (0, 0).
        let origin = RedactionOverlayView.clampedDragOrigin(
            touchPoint: CGPoint(x: -30, y: -30),
            dragOffset: CGSize(width: 50, height: 50),
            regionSize: CGSize(width: 100, height: 100),
            overlaySize: CGSize(width: 400, height: 400)
        )
        #expect(origin == CGPoint(x: 0, y: 0))
    }

    @Test("Region bigger than overlay stays pinned at origin (degenerate)")
    func regionBiggerThanOverlayPinsAtOrigin() {
        // Region 600x600 in 400x400 overlay. overlaySize - regionSize
        // = -200; max(0, -200) = 0. Origin pins at (0, 0) regardless of
        // touch position — the prior posture re-centered the region on
        // the overlay origin via the same arithmetic.
        let origin = RedactionOverlayView.clampedDragOrigin(
            touchPoint: CGPoint(x: 200, y: 200),
            dragOffset: CGSize(width: 300, height: 300),
            regionSize: CGSize(width: 600, height: 600),
            overlaySize: CGSize(width: 400, height: 400)
        )
        #expect(origin == CGPoint(x: 0, y: 0))
    }

    @Test("Touch at right edge with grab near right: tracks up to edge")
    func touchAtRightEdgeTracksGrabPoint() {
        // Touch at exactly (400, 200), drag offset (90, 50) (grab is
        // 90pt from left of region). newOrigin = (400-90, 200-50)
        // = (310, 150). With region width 100, right edge = 410 — out of
        // bounds; clamps to overlay-width - region-width = 300.
        let origin = RedactionOverlayView.clampedDragOrigin(
            touchPoint: CGPoint(x: 400, y: 200),
            dragOffset: CGSize(width: 90, height: 50),
            regionSize: CGSize(width: 100, height: 100),
            overlaySize: CGSize(width: 400, height: 400)
        )
        #expect(origin == CGPoint(x: 300, y: 150))
    }
}
