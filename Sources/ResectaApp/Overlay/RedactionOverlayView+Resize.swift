import UIKit
import RedactionEngine

// The resize gesture and the touch hit tests, moved out of
// `RedactionOverlayView.swift` (the hub) along its `// MARK: - Resize` seam:
// the selected region's resize toward a dragged handle, the region hit test
// (topmost wins) and the resize-handle hit test with its pure resolver. The
// hub's touch handling, `claimsTouch` and hover call them from there.

extension RedactionOverlayView {

    // MARK: - Resize

    /// Resize the selected region toward the dragged handle. The rect the
    /// resize began with is the anchor for the whole drag; a finger past
    /// the opposite edge flips the box about that edge; the snap acts on the
    /// edges that now move, and the size floor holds after it, on those
    /// axes only.
    func updateSelectedRegionForResize(handle: ResizeHandle, to point: CGPoint) {
        guard let selectedID,
              let idx = regions.firstIndex(where: { $0.id == selectedID }),
              let start = preResizeNormalizedRect
        else { return }

        let resized = Self.resizedRect(pdfNormalizedToOverlay(start), handle: handle, to: point)
        var newRect = snapEngine.applyResizeSnapping(
            to: resized.rect, handle: resized.handle, excluding: selectedID, in: snapPage)
        newRect = Self.flooredRect(newRect, handle: resized.handle,
                                   floor: Self.minimumRegionSize * fingerScale)

        // Clamp to overlay bounds
        newRect = newRect.intersection(bounds)
        guard !newRect.isNull else { return }

        regions[idx].normalizedRect = overlayToPDFNormalized(newRect)
        setNeedsDisplay()
    }

    /// The edges a handle moves.
    static func movingEdges(_ handle: ResizeHandle) -> (left: Bool, right: Bool, top: Bool, bottom: Bool) {
        switch handle {
        case .topLeft: return (true, false, true, false)
        case .topRight: return (false, true, true, false)
        case .bottomLeft: return (true, false, false, true)
        case .bottomRight: return (false, true, false, true)
        case .topCenter: return (false, false, true, false)
        case .bottomCenter: return (false, false, false, true)
        case .leftCenter: return (true, false, false, false)
        case .rightCenter: return (false, true, false, false)
        }
    }

    /// The handle that moves exactly these edges.
    static func handle(movingLeft left: Bool, right: Bool, top: Bool, bottom: Bool) -> ResizeHandle {
        switch (left, right, top, bottom) {
        case (true, _, true, _): return .topLeft
        case (_, true, true, _): return .topRight
        case (true, _, _, true): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        case (_, _, true, _): return .topCenter
        case (_, _, _, true): return .bottomCenter
        case (true, _, _, _): return .leftCenter
        default: return .rightCenter
        }
    }

    /// The rect a handle drag gives from the rect the resize began with:
    /// each moving edge follows the finger and the opposite edge is the
    /// anchor; a finger past the anchor flips the box about it. Also
    /// returns the handle as it now sits (left and right, or top and
    /// bottom, swapped on a flipped axis) for the snap and the floor.
    static func resizedRect(
        _ start: CGRect, handle: ResizeHandle, to point: CGPoint
    ) -> (rect: CGRect, handle: ResizeHandle) {
        let edges = movingEdges(handle)
        var (minX, maxX, minY, maxY) = (start.minX, start.maxX, start.minY, start.maxY)
        var (left, right, top, bottom) = (false, false, false, false)
        if edges.left || edges.right {
            let anchor = edges.left ? start.maxX : start.minX
            right = point.x > anchor || (point.x == anchor && edges.right)
            left = !right
            minX = min(anchor, point.x)
            maxX = max(anchor, point.x)
        }
        if edges.top || edges.bottom {
            let anchor = edges.top ? start.maxY : start.minY
            bottom = point.y > anchor || (point.y == anchor && edges.bottom)
            top = !bottom
            minY = min(anchor, point.y)
            maxY = max(anchor, point.y)
        }
        let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        return (rect, Self.handle(movingLeft: left, right: right, top: top, bottom: bottom))
    }

    /// Hold `floor` on the axes `handle` moves, keeping the anchored edge.
    static func flooredRect(_ rect: CGRect, handle: ResizeHandle, floor: CGFloat) -> CGRect {
        let edges = movingEdges(handle)
        var floored = rect
        if (edges.left || edges.right), floored.width < floor {
            if edges.left { floored.origin.x = floored.maxX - floor }
            floored.size.width = floor
        }
        if (edges.top || edges.bottom), floored.height < floor {
            if edges.top { floored.origin.y = floored.maxY - floor }
            floored.size.height = floor
        }
        return floored
    }

    // MARK: - Region Hit Testing

    /// Hit-test regions in reverse order so topmost region wins.
    func hitTestRegion(at point: CGPoint) -> RedactionRegion? {
        for region in regions.reversed() {
            let viewRect = pdfNormalizedToOverlay(region.normalizedRect)
            // 8-point inset expansion for easier touch targeting
            let hitRect = viewRect.insetBy(dx: -8 * fingerScale, dy: -8 * fingerScale)
            if hitRect.contains(point) {
                return region
            }
        }
        return nil
    }

    // MARK: - Resize Handle Hit Testing

    enum ResizeHandle {
        case topLeft, topRight, bottomLeft, bottomRight
        case topCenter, bottomCenter, leftCenter, rightCenter
    }

    /// Pure hit-test resolver — the exact geometry `hitTest(_:with:)`
    /// and `touchesBegan` consult (via `hitTestResizeHandle` below) at
    /// the single touch-down instant, with zero recognizer slop: a
    /// touch starting outside every box this returns falls straight
    /// through `hitTest` to PDFView's own pan/zoom recognizer for that
    /// touch's whole lifetime — there is no renegotiation as the
    /// finger moves, and the drawn handle dot (`drawResizeHandles`) is
    /// cosmetic and contributes nothing to this test. `targetHandleSize`
    /// is clamped to at most HALF the region's shorter side (never
    /// past the region's own center, so opposite-edge handles stay
    /// distinguishable) and at least the 22pt floor, so
    /// handles on a small region shrink gracefully toward the old
    /// behavior instead of fully overlapping. When the clamped boxes
    /// of two or more handles overlap the touch point, the nearest
    /// handle center wins — deterministic, independent of the array
    /// order below (which previously decided ties by accident).
    internal static func resolveResizeHandle(
        at point: CGPoint,
        regionRect: CGRect,
        targetHandleSize: CGFloat = ResectaTokens.TouchTarget.minimum,
        minimumHandleSize: CGFloat = 22
    ) -> ResizeHandle? {
        let clamped = min(
            targetHandleSize,
            max(minimumHandleSize, min(regionRect.width, regionRect.height) / 2)
        )

        let handles: [(ResizeHandle, CGPoint)] = [
            (.topLeft,     CGPoint(x: regionRect.minX, y: regionRect.minY)),
            (.topRight,    CGPoint(x: regionRect.maxX, y: regionRect.minY)),
            (.bottomLeft,  CGPoint(x: regionRect.minX, y: regionRect.maxY)),
            (.bottomRight, CGPoint(x: regionRect.maxX, y: regionRect.maxY)),
            (.topCenter,   CGPoint(x: regionRect.midX, y: regionRect.minY)),
            (.bottomCenter, CGPoint(x: regionRect.midX, y: regionRect.maxY)),
            (.leftCenter,  CGPoint(x: regionRect.minX, y: regionRect.midY)),
            (.rightCenter, CGPoint(x: regionRect.maxX, y: regionRect.midY)),
        ]

        let candidates = handles.filter { _, center in
            CGRect(x: center.x - clamped / 2, y: center.y - clamped / 2,
                   width: clamped, height: clamped).contains(point)
        }
        return candidates.min(by: { lhs, rhs in
            let ldx = lhs.1.x - point.x, ldy = lhs.1.y - point.y
            let rdx = rhs.1.x - point.x, rdy = rhs.1.y - point.y
            return (ldx * ldx + ldy * ldy) < (rdx * rdx + rdy * rdy)
        })?.0
    }

    /// The selected region shows and takes resize handles only while Add
    /// to Selection is off: with it on, a tap anywhere on a region adds or
    /// removes that region, never starts a resize.
    var resizeHandlesActive: Bool { !isMultiSelectActive }

    func hitTestResizeHandle(at point: CGPoint) -> ResizeHandle? {
        guard resizeHandlesActive,
              let selectedID,
              let region = regions.first(where: { $0.id == selectedID })
        else { return nil }

        let rect = pdfNormalizedToOverlay(region.normalizedRect)
        return Self.resolveResizeHandle(
            at: point,
            regionRect: rect,
            targetHandleSize: ResectaTokens.TouchTarget.minimum * fingerScale,
            minimumHandleSize: 22 * fingerScale
        )
    }
}
