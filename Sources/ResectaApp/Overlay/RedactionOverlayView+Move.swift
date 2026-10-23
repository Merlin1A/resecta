import UIKit
import RedactionEngine

// The move and group-move helpers, moved out of `RedactionOverlayView.swift`
// (the hub) from its `// MARK: - Move Helpers` seam: beginning a move on a
// selected region, beginning a group move, and updating either as the
// finger travels. The hub's touch handling calls them; the long-press
// helpers stay in the hub. The drag state they read and write is stored
// on the hub (an extension adds no storage).

extension RedactionOverlayView {

    /// Begin a move drag on an already-selected region.
    func beginMove(for region: RedactionRegion, at point: CGPoint) {
        let viewRect = pdfNormalizedToOverlay(region.normalizedRect)
        dragOffset = CGSize(
            width: point.x - viewRect.origin.x,
            height: point.y - viewRect.origin.y
        )
        preDragNormalizedRect = region.normalizedRect
        isDraggingExistingRegion = true
        isActivelyDragging = true
        moveCommitFeedback.prepare()
    }

    /// Begin a group move of all selected regions.
    func beginGroupMove(at point: CGPoint) {
        preDragGroupRects = [:]
        for region in regions where selectedIDs.contains(region.id) {
            preDragGroupRects[region.id] = region.normalizedRect
        }
        groupMoveStart = point
        isGroupMoving = true
        isActivelyDragging = true
        moveCommitFeedback.prepare()
    }

    /// Update all selected regions' positions during a group move. One
    /// delta moves every member, clamped so the group's union stays on
    /// the page: an edge stops the whole group, keeping its spacing.
    func updateGroupMove(to point: CGPoint) {
        guard let start = groupMoveStart else { return }
        var union = CGRect.null
        for region in regions where selectedIDs.contains(region.id) {
            if let originalNorm = preDragGroupRects[region.id] {
                union = union.union(pdfNormalizedToOverlay(originalNorm))
            }
        }
        guard !union.isNull else { return }
        let dx = min(max(point.x - start.x, bounds.minX - union.minX), bounds.maxX - union.maxX)
        let dy = min(max(point.y - start.y, bounds.minY - union.minY), bounds.maxY - union.maxY)

        for i in regions.indices where selectedIDs.contains(regions[i].id) {
            guard let originalNorm = preDragGroupRects[regions[i].id] else { continue }
            let moved = pdfNormalizedToOverlay(originalNorm).offsetBy(dx: dx, dy: dy)
            regions[i].normalizedRect = overlayToPDFNormalized(moved)
        }
    }

    /// Update the selected region's position during a move drag.
    func updateSelectedRegionForMove(to point: CGPoint) {
        guard let selectedID,
              let idx = regions.firstIndex(where: { $0.id == selectedID })
        else { return }

        // Capture old rect for dirty-region invalidation
        let oldOverlayRect = pdfNormalizedToOverlay(regions[idx].normalizedRect)
        let regionSize = oldOverlayRect.size

        // Clamp the touch into overlay bounds first, then
        // derive the region origin from (clamped touch) - dragOffset.
        // Keeps the grab point under the finger up to the overlay edge
        // and handles the region-bigger-than-overlay edge case at one site.
        let newOrigin = Self.clampedDragOrigin(
            touchPoint: point,
            dragOffset: dragOffset,
            regionSize: regionSize,
            overlaySize: bounds.size
        )

        var newRect = CGRect(origin: newOrigin, size: regionSize)

        // Apply snap guides during move
        newRect = snapEngine.applySnapping(to: newRect, excluding: selectedID, in: snapPage)

        regions[idx].normalizedRect = overlayToPDFNormalized(newRect)

        // Dirty-rect optimization: only invalidate old + new rect area (+ margin for shadow/handles)
        let margin: CGFloat = 20
        let dirtyRect = oldOverlayRect.union(newRect).insetBy(dx: -margin, dy: -margin)
        setNeedsDisplay(dirtyRect)
    }
}
