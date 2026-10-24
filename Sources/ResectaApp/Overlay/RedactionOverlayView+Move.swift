import UIKit
import RedactionEngine

// The move and group-move helpers, moved out of `RedactionOverlayView.swift`
// (the hub) from its `// MARK: - Move Helpers` seam: beginning a move on a
// selected region, beginning a group move, the start slop every move, group
// move and resize waits out, updating either as the finger travels, ending a
// group move, and committing an Add to Selection toggle on lift. The hub's touch handling calls them. The drag state they read and
// write is stored on the hub (an extension adds no storage).

extension RedactionOverlayView {

    /// Begin a move drag on an already-selected region.
    func beginMove(for region: RedactionRegion, at point: CGPoint) {
        let viewRect = pdfNormalizedToOverlay(region.normalizedRect)
        dragOffset = CGSize(
            width: point.x - viewRect.origin.x,
            height: point.y - viewRect.origin.y
        )
        preDragNormalizedRect = region.normalizedRect
        dragStartPoint = point
        isDraggingExistingRegion = true
        isActivelyDragging = true
        moveCommitFeedback.prepare()
    }

    /// Begin a group move of all selected regions, from a touch on one of
    /// them.
    func beginGroupMove(at point: CGPoint, touching touchedID: UUID) {
        preDragGroupRects = [:]
        for region in regions where selectedIDs.contains(region.id) {
            preDragGroupRects[region.id] = region.normalizedRect
        }
        dragStartPoint = point
        groupMoveTouchedID = touchedID
        isGroupMoving = true
        isActivelyDragging = true
        moveCommitFeedback.prepare()
    }

    /// The start slop, in screen points: a move, a group move or a resize
    /// changes nothing until the finger has travelled this far from where it
    /// went down, so a tap that drifts is a tap; from then on it follows the
    /// finger, and only then does its lift commit.
    static let startSlop: CGFloat = 4

    /// True once the finger has travelled past the start slop from
    /// `dragStartPoint` (or when there is none); it stays true for the drag.
    func passStartSlop(to point: CGPoint) -> Bool {
        if !hasPassedStartSlop, let start = dragStartPoint {
            hasPassedStartSlop = hypot(point.x - start.x, point.y - start.y) >= Self.startSlop * fingerScale
        } else {
            hasPassedStartSlop = true
        }
        return hasPassedStartSlop
    }

    /// With Add to Selection on, a touch on a region edits the selection
    /// when it lifts: the touch records the region and the primary touch's
    /// lift toggles it. A cancelled touch (the region's menu, a pinch, a
    /// scroll) is reset without toggling. True when a toggle was committed.
    func commitPendingToggle() -> Bool {
        guard let id = pendingToggleID else { return false }
        coordinator?.toggleRegionSelection(id)
        return true
    }

    /// End a group move on lift. A lift with no travel, every member still
    /// at its pre-drag rect, was a tap on one member: it selects only that
    /// member and commits nothing. Otherwise the members' new rects commit
    /// as one step.
    func endGroupMove() {
        let members = regions.filter { selectedIDs.contains($0.id) }
        if let touchedID = groupMoveTouchedID,
           members.allSatisfy({ preDragGroupRects[$0.id] == $0.normalizedRect }) {
            coordinator?.selectRegion(touchedID)
            return
        }
        moveCommitFeedback.impactOccurred()
        coordinator?.commitMoveMultiple(members.map { (id: $0.id, newRect: $0.normalizedRect) },
                                        page: pageIndex, undoManager: window?.undoManager)
    }

    /// Update all selected regions' positions during a group move. One
    /// delta moves every member, clamped so the group's union stays on
    /// the page: an edge stops the whole group, keeping its spacing.
    func updateGroupMove(to point: CGPoint) {
        guard passStartSlop(to: point), let start = dragStartPoint else { return }
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
        guard passStartSlop(to: point), let selectedID,
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
