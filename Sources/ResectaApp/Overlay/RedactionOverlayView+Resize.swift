import UIKit
import RedactionEngine

// The resize gesture and the touch hit tests, moved out of
// `RedactionOverlayView.swift` (the hub) along its `// MARK: - Resize` seam:
// the selected region's resize toward a dragged handle, and the one rule for
// what a touch picks (`resolveHitTarget`: a handle or a region) with the
// handle resolver it reads. The hub's touch handling, `claimsTouch`, hover,
// the long-press menu and the canvas tap all read that rule.

extension RedactionOverlayView {

    // MARK: - Resize

    /// Begin a resize on the selected region's `handle`: the rect it starts
    /// from is the drag's anchor and the cancel's restore.
    func beginResize(_ handle: ResizeHandle, at point: CGPoint) {
        activeResizeHandle = handle
        preResizeNormalizedRect = selectedID.flatMap { id in regions.first { $0.id == id }?.normalizedRect }
        dragStartPoint = point
        isActivelyDragging = true
    }

    /// Resize the selected region toward the dragged handle. The rect the
    /// resize began with is the anchor for the whole drag, and the handle
    /// keeps the offset from the finger it was grabbed at; a finger past
    /// the opposite edge flips the box about that edge; the snap acts on the
    /// edges that now move, and the size floor holds after it, on those
    /// axes only.
    func updateSelectedRegionForResize(handle: ResizeHandle, to point: CGPoint) {
        guard passStartSlop(to: point), let selectedID,
              let idx = regions.firstIndex(where: { $0.id == selectedID }),
              let start = preResizeNormalizedRect, let touchDown = dragStartPoint
        else { return }

        let startRect = pdfNormalizedToOverlay(start)
        let grabbed = Self.handlePoint(handle, in: startRect)
        let edge = CGPoint(x: point.x + grabbed.x - touchDown.x, y: point.y + grabbed.y - touchDown.y)
        let resized = Self.resizedRect(startRect, handle: handle, to: edge)
        var newRect = snapEngine.applyResizeSnapping(
            to: resized.rect, handle: resized.handle, excluding: selectedID, in: snapPage)
        newRect = Self.flooredRect(newRect, handle: resized.handle, fingerScale: fingerScale)

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

    /// Where a handle sits on `rect`.
    static func handlePoint(_ handle: ResizeHandle, in rect: CGRect) -> CGPoint {
        let edges = movingEdges(handle)
        return CGPoint(x: edges.left ? rect.minX : edges.right ? rect.maxX : rect.midX,
                       y: edges.top ? rect.minY : edges.bottom ? rect.maxY : rect.midY)
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

    /// Hold the size floor on the axes `handle` moves, keeping the anchored
    /// edge: each moved axis floors at what `RegionSizeFloor` asks of it
    /// beside the other axis.
    static func flooredRect(_ rect: CGRect, handle: ResizeHandle, fingerScale: CGFloat) -> CGRect {
        let edges = movingEdges(handle)
        var floored = rect
        let widthFloor = RegionSizeFloor.floor(across: floored.height, fingerScale: fingerScale)
        if (edges.left || edges.right), floored.width < widthFloor {
            if edges.left { floored.origin.x = floored.maxX - widthFloor }
            floored.size.width = widthFloor
        }
        let heightFloor = RegionSizeFloor.floor(across: floored.width, fingerScale: fingerScale)
        if (edges.top || edges.bottom), floored.height < heightFloor {
            if edges.top { floored.origin.y = floored.maxY - heightFloor }
            floored.size.height = heightFloor
        }
        return floored
    }

    /// The one size floor, in screen points (overlay points are page
    /// points, so each is multiplied by `fingerScale`): a region needs 20
    /// along its long side and 8 across, so a one-line region can be drawn
    /// at the fit zoom. The draw reject and the resize floor both read it.
    enum RegionSizeFloor {
        static let longSide: CGFloat = 20
        static let across: CGFloat = 8

        static func admits(_ size: CGSize, fingerScale: CGFloat) -> Bool {
            max(size.width, size.height) >= longSide * fingerScale
                && min(size.width, size.height) >= across * fingerScale
        }

        /// The floor one axis is held at beside `other`: 8 across when
        /// `other` already carries the long side, else 20 along.
        static func floor(across other: CGFloat, fingerScale: CGFloat) -> CGFloat {
            (other >= longSide * fingerScale ? across : longSide) * fingerScale
        }
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
    /// Two more rules. A point inside the region past every handle box's
    /// inward reach (at most a quarter of that side) is the region's body,
    /// for a move, even on a thin region whose boxes overlap its middle.
    /// And with `containerBounds` (the page), a box that would cross the
    /// page edge slides inward so all of it can be touched.
    internal static func resolveResizeHandle(
        at point: CGPoint,
        regionRect: CGRect,
        targetHandleSize: CGFloat = ResectaTokens.TouchTarget.minimum,
        minimumHandleSize: CGFloat = 22,
        containerBounds: CGRect? = nil
    ) -> ResizeHandle? {
        let clamped = min(
            targetHandleSize,
            max(minimumHandleSize, min(regionRect.width, regionRect.height) / 2)
        )

        let centers: [(ResizeHandle, CGPoint)] = [
            (.topLeft,     CGPoint(x: regionRect.minX, y: regionRect.minY)),
            (.topRight,    CGPoint(x: regionRect.maxX, y: regionRect.minY)),
            (.bottomLeft,  CGPoint(x: regionRect.minX, y: regionRect.maxY)),
            (.bottomRight, CGPoint(x: regionRect.maxX, y: regionRect.maxY)),
            (.topCenter,   CGPoint(x: regionRect.midX, y: regionRect.minY)),
            (.bottomCenter, CGPoint(x: regionRect.midX, y: regionRect.maxY)),
            (.leftCenter,  CGPoint(x: regionRect.minX, y: regionRect.midY)),
            (.rightCenter, CGPoint(x: regionRect.maxX, y: regionRect.midY)),
        ]
        let boxes: [(handle: ResizeHandle, box: CGRect)] = centers.map { handle, center in
            var box = CGRect(x: center.x - clamped / 2, y: center.y - clamped / 2,
                             width: clamped, height: clamped)
            if let page = containerBounds {
                box.origin.x = max(page.minX, min(box.origin.x, page.maxX - clamped))
                box.origin.y = max(page.minY, min(box.origin.y, page.maxY - clamped))
            }
            return (handle, box)
        }
        func box(_ handle: ResizeHandle) -> CGRect {
            boxes.first { $0.handle == handle }?.box ?? .null
        }

        // The body zone: past each side's handle-box reach, capped at a
        // quarter of that side.
        let left = min(box(.leftCenter).maxX - regionRect.minX, regionRect.width / 4)
        let right = min(regionRect.maxX - box(.rightCenter).minX, regionRect.width / 4)
        let top = min(box(.topCenter).maxY - regionRect.minY, regionRect.height / 4)
        let bottom = min(regionRect.maxY - box(.bottomCenter).minY, regionRect.height / 4)
        let body = CGRect(x: regionRect.minX + left, y: regionRect.minY + top,
                          width: regionRect.width - left - right,
                          height: regionRect.height - top - bottom)
        if body.width > 0, body.height > 0, body.contains(point) { return nil }

        return boxes.filter { $0.box.contains(point) }.min(by: { lhs, rhs in
            let ldx = lhs.box.midX - point.x, ldy = lhs.box.midY - point.y
            let rdx = rhs.box.midX - point.x, rdy = rhs.box.midY - point.y
            return (ldx * ldx + ldy * ldy) < (rdx * rdx + rdy * rdy)
        })?.handle
    }

    /// The selected region shows and takes resize handles only while Add
    /// to Selection is off: with it on, a tap anywhere on a region adds or
    /// removes that region, never starts a resize.
    var resizeHandlesActive: Bool { !isMultiSelectActive }


    // MARK: - Hit Testing

    /// What a touch picks: a handle of the selected region, or a region.
    enum CanvasHitTarget: Equatable {
        case handle(ResizeHandle)
        case region(UUID)
    }

    /// The one rule for which region or handle a touch picks, in overlay
    /// points. In order: the selected region's handle, when `selected` is
    /// given and the point is in no other region's body; else the smallest
    /// region whose body holds the point (the later one on a tie); else,
    /// within `halo` of a region, the region whose edge is nearest (the
    /// later one on a tie). `regions` is in append order.
    static func resolveHitTarget(
        at point: CGPoint,
        regions: [(id: UUID, rect: CGRect)],
        selected: (id: UUID, rect: CGRect)?,
        halo: CGFloat,
        handleSize: CGFloat,
        minimumHandleSize: CGFloat,
        containerBounds: CGRect?
    ) -> CanvasHitTarget? {
        if let selected,
           !regions.contains(where: { $0.id != selected.id && $0.rect.contains(point) }),
           let handle = resolveResizeHandle(
               at: point, regionRect: selected.rect, targetHandleSize: handleSize,
               minimumHandleSize: minimumHandleSize, containerBounds: containerBounds) {
            return .handle(handle)
        }
        var best: (id: UUID, key: CGFloat)?
        for region in regions where region.rect.contains(point) {
            let area = region.rect.width * region.rect.height
            if best == nil || area <= best!.key { best = (region.id, area) }
        }
        if let best { return .region(best.id) }
        for region in regions where region.rect.insetBy(dx: -halo, dy: -halo).contains(point) {
            let dx = max(region.rect.minX - point.x, 0, point.x - region.rect.maxX)
            let dy = max(region.rect.minY - point.y, 0, point.y - region.rect.maxY)
            let distance = (dx * dx + dy * dy).squareRoot()
            if best == nil || distance <= best!.key { best = (region.id, distance) }
        }
        return best.map { .region($0.id) }
    }

    /// The touch's target on this overlay: `handles` false asks for a
    /// region only (the menu, hover, the canvas tap).
    func hitTarget(at point: CGPoint, handles: Bool) -> CanvasHitTarget? {
        let selected: (id: UUID, rect: CGRect)? = handles && resizeHandlesActive
            ? selectedID.flatMap { id in
                regions.first { $0.id == id }.map { (id, pdfNormalizedToOverlay($0.normalizedRect)) }
            }
            : nil
        return Self.resolveHitTarget(
            at: point,
            regions: regions.map { ($0.id, pdfNormalizedToOverlay($0.normalizedRect)) },
            selected: selected,
            halo: 8 * fingerScale,
            handleSize: ResectaTokens.TouchTarget.minimum * fingerScale,
            minimumHandleSize: 22 * fingerScale,
            containerBounds: bounds)
    }

    func hitTestRegion(at point: CGPoint) -> RedactionRegion? {
        guard case .region(let id)? = hitTarget(at: point, handles: false) else { return nil }
        return regions.first { $0.id == id }
    }

    func hitTestResizeHandle(at point: CGPoint) -> ResizeHandle? {
        guard case .handle(let handle)? = hitTarget(at: point, handles: true) else { return nil }
        return handle
    }
}
