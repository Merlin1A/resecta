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

    /// At the start slop's crossing, each of the boxes `ids` that is still
    /// anchored to its text (`FirstEdit.applies`) takes its start, read once
    /// here and kept for the drag: the plan read now is the one the last
    /// drawing pass made, with the box still anchored, while a later pass
    /// holds it as edited and has no start for it. The box's copy is no
    /// longer anchored from here; the stored region changes at the lift.
    func takeFirstEditStarts(for ids: Set<UUID>) {
        for i in regions.indices where ids.contains(regions[i].id) && FirstEdit.applies(to: regions[i]) {
            let id = regions[i].id
            firstEditStarts[id] = startReader(id)?.share ?? regions[i].normalizedRect
            regions[i].textAnchored = false
        }
    }

    /// True when every box the slop gave a start is back on it, and every
    /// other box of `members` back on its rect in `before`, each compared in
    /// sixty-fourths of the page as shown: a drag that came back, which
    /// changes nothing.
    func cameBackToTheStart(_ members: [RedactionRegion], before: [UUID: CGRect]) -> Bool {
        let sides = geometry.displayedSize
        return members.allSatisfy { member in
            guard let place = firstEditStarts[member.id] ?? before[member.id] else { return false }
            return FirstEdit.samePlace(member.normalizedRect, place, displayedSize: sides)
        }
    }

    /// Puts the copies of the boxes in `before` back to those rects, and the
    /// boxes the slop gave a start back to anchored, as the stored regions
    /// still are: no configure follows a drag that wrote nothing.
    func restoreFirstEditCopies(_ before: [UUID: CGRect]) {
        for i in regions.indices {
            let id = regions[i].id
            if let rect = before[id] { regions[i].normalizedRect = rect }
            if firstEditStarts[id] != nil { regions[i].textAnchored = true }
            if let drawn = preGestureDrawnPageRects[id] { regions[i].drawnPageRect = drawn }
        }
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
    /// member and commits nothing. A group the start slop gave a start to
    /// that comes back, each such member on its start and every other on its
    /// pre-drag rect, is no tap: nothing is written, the copies go back and
    /// the selection stays. Otherwise the members' new rects commit as one
    /// step.
    func endGroupMove() {
        let members = regions.filter { selectedIDs.contains($0.id) }
        if !firstEditStarts.isEmpty {
            if cameBackToTheStart(members, before: preDragGroupRects) {
                restoreFirstEditCopies(preDragGroupRects)
                return
            }
        } else if let touchedID = groupMoveTouchedID,
           members.allSatisfy({ preDragGroupRects[$0.id] == $0.normalizedRect }) {
            coordinator?.selectRegion(touchedID)
            return
        }
        moveCommitFeedback.impactOccurred()
        coordinator?.commitMoveMultiple(members.map { (id: $0.id, newRect: $0.normalizedRect) },
                                        page: pageIndex,
                                        drawnPageRects: drawnPageRects(for: members.map(\.id)),
                                        undoManager: window?.undoManager)
    }

    /// Update all selected regions' positions during a group move. One
    /// delta moves every member, clamped so the group's union stays on
    /// the page: an edge stops the whole group, keeping its spacing.
    func updateGroupMove(to point: CGPoint) {
        let crossing = !hasPassedStartSlop
        guard passStartSlop(to: point), let start = dragStartPoint else { return }
        if crossing { takeFirstEditStarts(for: selectedIDs) }
        // Each member moves from its start, or from its pre-drag rect.
        func anchor(_ id: UUID) -> CGRect? { firstEditStarts[id] ?? preDragGroupRects[id] }
        var union = CGRect.null
        for region in regions where selectedIDs.contains(region.id) {
            if let originalNorm = anchor(region.id) {
                union = union.union(pdfNormalizedToOverlay(originalNorm))
            }
        }
        guard !union.isNull else { return }
        // Held so the group stays on the page as PDFKit places it.
        let page = pageRectOnCanvas
        let dx = min(max(point.x - start.x, page.minX - union.minX), page.maxX - union.maxX)
        let dy = min(max(point.y - start.y, page.minY - union.minY), page.maxY - union.maxY)

        for i in regions.indices where selectedIDs.contains(regions[i].id) {
            guard let originalNorm = anchor(regions[i].id) else { continue }
            let moved = pdfNormalizedToOverlay(originalNorm).offsetBy(dx: dx, dy: dy)
            storeFromGesture(i, overlayRect: moved)
        }
    }

    /// Update the selected region's position during a move drag.
    func updateSelectedRegionForMove(to point: CGPoint) {
        let crossing = !hasPassedStartSlop
        guard passStartSlop(to: point), let selectedID,
              let idx = regions.firstIndex(where: { $0.id == selectedID })
        else { return }
        if crossing {
            takeFirstEditStarts(for: [selectedID])
            // The box moves from its start, and the point of the page under
            // the touch-down stays under the finger: the grab offset is
            // retaken from the touch-down against the start, through the
            // canvas's own map (which takes the page's turn).
            if let start = firstEditStarts[selectedID], let touchDown = dragStartPoint {
                regions[idx].normalizedRect = start
                let origin = pdfNormalizedToOverlay(start).origin
                dragOffset = CGSize(width: touchDown.x - origin.x, height: touchDown.y - origin.y)
            }
        }

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
            page: pageRectOnCanvas
        )

        var newRect = CGRect(origin: newOrigin, size: regionSize)

        // Apply snap guides during move, then keep the region on the page:
        // a guide near the edge may pull it past.
        newRect = snapEngine.applySnapping(to: newRect, excluding: selectedID, in: snapPage)
        let page = pageRectOnCanvas
        newRect.origin = CGPoint(x: max(page.minX, min(newRect.minX, page.maxX - newRect.width)),
                                 y: max(page.minY, min(newRect.minY, page.maxY - newRect.height)))

        storeFromGesture(idx, overlayRect: newRect)
        // The touch's redraw (`redrawGesture`) marks the top canvas and the
        // moved box's layers; a mark of the whole overlay here would pass
        // every box.
    }
}
