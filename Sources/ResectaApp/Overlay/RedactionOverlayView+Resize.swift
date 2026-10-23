import UIKit
import RedactionEngine

// The resize gesture and the touch hit tests, moved out of
// `RedactionOverlayView.swift` (the hub) along its `// MARK: - Resize` seam:
// the selected region's resize toward a dragged handle, the region hit test
// (topmost wins) and the resize-handle hit test with its pure resolver. The
// hub's touch handling, `claimsTouch` and hover call them from there.

extension RedactionOverlayView {

    // MARK: - Resize

    func updateSelectedRegionForResize(handle: ResizeHandle, to point: CGPoint) {
        guard let selectedID,
              let idx = regions.firstIndex(where: { $0.id == selectedID })
        else { return }

        let current = pdfNormalizedToOverlay(regions[idx].normalizedRect)
        var newRect: CGRect

        switch handle {
        case .topLeft:
            newRect = CGRect(x: point.x, y: point.y,
                             width: current.maxX - point.x, height: current.maxY - point.y)
        case .topRight:
            newRect = CGRect(x: current.minX, y: point.y,
                             width: point.x - current.minX, height: current.maxY - point.y)
        case .bottomLeft:
            newRect = CGRect(x: point.x, y: current.minY,
                             width: current.maxX - point.x, height: point.y - current.minY)
        case .bottomRight:
            newRect = CGRect(x: current.minX, y: current.minY,
                             width: point.x - current.minX, height: point.y - current.minY)
        case .topCenter:
            newRect = CGRect(x: current.minX, y: point.y,
                             width: current.width, height: current.maxY - point.y)
        case .bottomCenter:
            newRect = CGRect(x: current.minX, y: current.minY,
                             width: current.width, height: point.y - current.minY)
        case .leftCenter:
            newRect = CGRect(x: point.x, y: current.minY,
                             width: current.maxX - point.x, height: current.height)
        case .rightCenter:
            newRect = CGRect(x: current.minX, y: current.minY,
                             width: point.x - current.minX, height: current.height)
        }

        // Enforce minimum size in overlay space
        let resizeFloor = Self.minimumRegionSize * fingerScale
        newRect.size.width = max(abs(newRect.size.width), resizeFloor)
        newRect.size.height = max(abs(newRect.size.height), resizeFloor)

        // Apply snap guides to moving edges during resize
        newRect = applyResizeSnapping(to: newRect, handle: handle, excluding: selectedID)

        // Clamp to overlay bounds
        newRect = newRect.intersection(bounds)
        guard !newRect.isNull else { return }

        regions[idx].normalizedRect = overlayToPDFNormalized(newRect)
        setNeedsDisplay()
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

    func hitTestResizeHandle(at point: CGPoint) -> ResizeHandle? {
        guard let selectedID,
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
