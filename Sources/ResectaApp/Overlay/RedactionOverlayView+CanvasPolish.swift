import UIKit

// Pure helpers and adaptive-stroke constants
// for the canvas a11y polish bundle. Extracted from
// `RedactionOverlayView.swift` to keep that file under the 1500 LOC hub
// cap; the pattern mirrors `RedactionOverlayView+TagExemption.swift`.
//
//   `badgeOuterStrokeWidth`     (badge perimeter contrast)
//   `selectionHandleOuterStrokeWidth` (handle ring against light bg)
//   `HandleAnimationDirection` + `reduceMotionHandleScale(…)`
//           (Reduce-Motion gate for the CADisplayLink path)
//
//   `DimensionLabelPosition` + `dimensionLabelPosition(…)`
//           (above-vs-below placement for small/tall regions; suppress
//           when neither slot fits in the overlay)
//   `clampedDragOrigin(…)`
//           (grab point stays under finger up to overlay edge; degenerate
//           region-bigger-than-overlay case pinned at origin corner)

extension RedactionOverlayView {

    // MARK: - Badge outer stroke

    /// Hairline outer stroke around the PII-type badge so its perimeter
    /// stays visible when the badge color blends with the region fill
    /// underneath (orange badge on orange fill, purple on purple) or
    /// with adjacent document content in dark mode. Adaptive
    /// `UIColor.separator` colour at the call site; 0.5pt is sub-pixel
    /// on 2× / 3× retina — just enough for an edge.
    static let badgeOuterStrokeWidth: CGFloat = 0.5

    // MARK: - Selection-handle outer ring

    /// 1pt mid-gray outer stroke around each resize handle so the
    /// white-fill / blue-stroke handles stay visible against light
    /// backgrounds (e.g. white page margins). Drawn as a slightly
    /// enlarged disc beneath the handle, so the visible ring scales
    /// with `handleScale` alongside the handle itself.
    static let selectionHandleOuterStrokeWidth: CGFloat = 1.0

    // MARK: - Reduce-Motion gate

    /// Names the gesture branch (selection gained vs lost) for the
    /// resize-handle CADisplayLink path's Reduce-Motion override.
    enum HandleAnimationDirection {
        case `in`
        case out
    }

    /// Returns the resize-handle target scale when Reduce Motion is
    /// enabled; `nil` signals the caller to run the CADisplayLink
    /// interpolation path. The `direction` argument names the gesture
    /// branch without coupling the test to `UIAccessibility` state.
    /// Pinned by `CanvasAccessibilityPolishTests`.
    static func reduceMotionHandleScale(
        direction: HandleAnimationDirection,
        reduceMotion: Bool
    ) -> CGFloat? {
        guard reduceMotion else { return nil }
        switch direction {
        case .in: return 1.0
        case .out: return 0.0
        }
    }

    // MARK: - Dimension label placement

    /// Regions shorter than this threshold prefer the dimension label
    /// above the rect (the label feels crowded sitting below a thin
    /// strip); regions at-or-above the threshold prefer the legacy
    /// below posture. 40pt was chosen so the typical text-line height
    /// (~20-30pt) lands on the above branch and the typical PII
    /// bounding-box (~50pt+) lands on the below branch.
    static let dimensionLabelSmallRegionThreshold: CGFloat = 40.0

    /// Result of the dimension-label position helper. The suppressed
    /// case is reached when neither above nor below has room inside
    /// the overlay; the call site skips the draw entirely rather than
    /// clamping into an unreadable position on top of the region.
    enum DimensionLabelPosition: Equatable {
        case above(y: CGFloat)
        case below(y: CGFloat)
        case suppressed
    }

    /// Pure helper for dimension-label vertical placement. Small
    /// regions (< `dimensionLabelSmallRegionThreshold` pt tall) try
    /// `above` first so the label doesn't crowd a thin region from
    /// below; taller regions try `below` first (legacy posture). If
    /// the preferred position falls outside the overlay, the helper
    /// falls back to the alternate position; if neither fits, the
    /// call site suppresses the label so it never lands on top of
    /// the region.
    ///
    /// `gap` is the spacing between the region edge and the pill
    /// (4pt by existing convention). `pillHeight` and `overlayHeight`
    /// are in overlay-view points.
    static func dimensionLabelPosition(
        regionRect: CGRect,
        pillHeight: CGFloat,
        overlayHeight: CGFloat,
        gap: CGFloat = 4
    ) -> DimensionLabelPosition {
        let aboveY = regionRect.minY - pillHeight - gap
        let belowY = regionRect.maxY + gap
        let aboveFits = aboveY >= 0
        let belowFits = belowY + pillHeight <= overlayHeight
        let preferAbove = regionRect.height < dimensionLabelSmallRegionThreshold

        if preferAbove {
            if aboveFits { return .above(y: aboveY) }
            if belowFits { return .below(y: belowY) }
        } else {
            if belowFits { return .below(y: belowY) }
            if aboveFits { return .above(y: aboveY) }
        }
        return .suppressed
    }

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
