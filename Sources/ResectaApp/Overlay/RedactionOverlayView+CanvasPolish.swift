import UIKit

// A pure helper for the move-drag, extracted from
// `RedactionOverlayView.swift` so the hub file stays smaller and the
// helper is unit-testable without a UIView host.
//
//   `clampedDragOrigin(…)`
//           (grab point stays under finger up to overlay edge; degenerate
//           region-bigger-than-overlay case pinned at origin corner)

extension RedactionOverlayView {

    // MARK: - Drag-offset clamping

    /// Pure helper for the move-drag origin. The grab point
    /// (touch - dragOffset) is kept under the finger up to the overlay
    /// edge — the touch is clamped to overlay bounds first, then the
    /// origin is derived. This avoids two failure modes the prior
    /// `clamp(origin)` posture allowed:
    ///   1. When the finger ran past the overlay edge, the grab point
    ///      fell behind the finger (region clamped, finger kept moving).
    ///   2. When `regionSize > overlaySize` (degenerate zoom case), the
    ///      `bounds.width - regionSize.width` upper bound went negative
    ///      and `max(0, min(..., neg))` snapped the origin to (0, 0) —
    ///      the region re-centered on the overlay origin instead of
    ///      tracking the grab point.
    ///
    /// Returns the overlay-space origin for the moved region.
    static func clampedDragOrigin(
        touchPoint: CGPoint,
        dragOffset: CGSize,
        regionSize: CGSize,
        overlaySize: CGSize
    ) -> CGPoint {
        let clampedTouch = CGPoint(
            x: max(0, min(touchPoint.x, overlaySize.width)),
            y: max(0, min(touchPoint.y, overlaySize.height))
        )
        var newOrigin = CGPoint(
            x: clampedTouch.x - dragOffset.width,
            y: clampedTouch.y - dragOffset.height
        )
        // Step 2: keep the region inside the overlay. The outer max(0, …)
        // pins the degenerate case (region bigger than overlay) at the
        // origin corner rather than re-centering.
        let maxX = max(0, overlaySize.width - regionSize.width)
        let maxY = max(0, overlaySize.height - regionSize.height)
        newOrigin.x = max(0, min(newOrigin.x, maxX))
        newOrigin.y = max(0, min(newOrigin.y, maxY))
        return newOrigin
    }
}
