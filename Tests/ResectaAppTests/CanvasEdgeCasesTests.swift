import Testing
import Foundation
import CoreGraphics
@testable import ResectaApp

// WU-44 — canvas polish edge-cases. Two pure-function predicates pinned
// independently so a drift on either branch surfaces in isolation.
//
// M-D.7 — dimension-label position helper. Small regions prefer above,
//          taller regions prefer below; both fall back to the alternate
//          slot, and suppress when neither slot fits in the overlay.
// M-D.8 — drag-offset clamping helper. Grab point stays under finger up
//          to the overlay edge; degenerate region-bigger-than-overlay
//          case stays pinned at the origin corner.

@Suite("Canvas edge cases (WU-44)")
@MainActor
struct CanvasEdgeCasesTests {

    // MARK: - M-D.7 — Dimension label position

    @Test("Small region (<40pt tall) with room above prefers above (M-D.7)")
    func smallRegionPrefersAbove() {
        // Region 200x20 in the middle of a 400x400 overlay. With pill
        // height 16 and gap 4, above wants minY - 16 - 4 = 100 - 20 = 80.
        let rect = CGRect(x: 50, y: 100, width: 200, height: 20)
        let position = RedactionOverlayView.dimensionLabelPosition(
            regionRect: rect,
            pillHeight: 16,
            overlayHeight: 400
        )
        #expect(position == .above(y: 80))
    }

    @Test("Tall region (>=40pt) with room below stays below (legacy posture)")
    func tallRegionStaysBelow() {
        // Region 200x80, plenty of room below: maxY (180) + gap (4) = 184.
        let rect = CGRect(x: 50, y: 100, width: 200, height: 80)
        let position = RedactionOverlayView.dimensionLabelPosition(
            regionRect: rect,
            pillHeight: 16,
            overlayHeight: 400
        )
        #expect(position == .below(y: 184))
    }

    @Test("Small region with no room above falls back to below")
    func smallRegionNoAboveFallsBack() {
        // Region near top edge: minY=4. Above would need y = 4-16-4 = -16
        // → out of bounds. Falls back to below: maxY(24) + gap(4) = 28.
        let rect = CGRect(x: 50, y: 4, width: 200, height: 20)
        let position = RedactionOverlayView.dimensionLabelPosition(
            regionRect: rect,
            pillHeight: 16,
            overlayHeight: 400
        )
        #expect(position == .below(y: 28))
    }

    @Test("Tall region with no room below falls back to above")
    func tallRegionNoBelowFallsBack() {
        // Region near bottom: maxY = 390, overlayHeight 400. Below needs
        // y + 16 <= 400 → 390+4+16 = 410 > 400. Falls back to above:
        // minY(310) - 16 - 4 = 290.
        let rect = CGRect(x: 50, y: 310, width: 200, height: 80)
        let position = RedactionOverlayView.dimensionLabelPosition(
            regionRect: rect,
            pillHeight: 16,
            overlayHeight: 400
        )
        #expect(position == .above(y: 290))
    }

    @Test("Region with no room above OR below is suppressed entirely")
    func suppressedWhenNoRoomEitherSide() {
        // Region fills the overlay vertically; neither above nor below
        // fits. Label is suppressed rather than clamped onto the region.
        let rect = CGRect(x: 50, y: 0, width: 200, height: 400)
        let position = RedactionOverlayView.dimensionLabelPosition(
            regionRect: rect,
            pillHeight: 16,
            overlayHeight: 400
        )
        #expect(position == .suppressed)
    }

    @Test("Threshold boundary: exactly 40pt tall uses the below branch")
    func thresholdBoundary() {
        // Threshold is `< 40` (strict less-than). A 40pt-tall region
        // falls into the tall-branch and prefers below.
        let rect = CGRect(x: 50, y: 100, width: 200, height: 40)
        let position = RedactionOverlayView.dimensionLabelPosition(
            regionRect: rect,
            pillHeight: 16,
            overlayHeight: 400
        )
        #expect(position == .below(y: 144))
    }

    // MARK: - M-D.8 — Drag-offset clamping

    @Test("Touch in-bounds: origin tracks the touch minus dragOffset (M-D.8)")
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
