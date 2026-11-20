import UIKit
import PDFKit
import RedactionEngine

// The overlay's touch handling, moved out of `RedactionOverlayView.swift`
// (the hub) from its `// MARK: - Touch Handling` and `// MARK: - Zoom`
// seams: touches began, moved, ended and cancelled, the zoom scale they
// read, the reset of the drag state, and the rejection of a box drawn
// smaller than the drag threshold. The drag state they read and write is
// stored on the hub (an extension adds no storage).

extension RedactionOverlayView {
    // MARK: - Touch Handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard touches.count == 1, let touch = touches.first else { return }
        // Ignore secondary touchesBegan while a gesture is already
        // in flight. Prevents a finger landing during a Pencil drag from
        // hijacking the gesture state machine.
        guard primaryTouch == nil else { return }
        primaryTouch = touch
        let point = touch.location(in: self)
        // DRAW WINS: while the Rectangle tool
        // is on, a touch-down ALWAYS starts a draw — over region bodies and
        // over resize-handle boxes alike. The handle / region / marquee
        // branches below run only with the tool off (`hitTest` already
        // claims every point in draw mode; the editor clears the selection
        // and the Add-to-Selection toggle on tool entry).
        if isDrawingMode {
            coordinator?.selectRegion(nil)
            switch activeShapeTool {
            case .rectangle:
                dragOrigin = point
                currentDragRect = nil
                isActivelyDragging = true
                // VoiceOver announcement for drawing-in-progress
                UIAccessibility.post(notification: .announcement,
                                     argument: "Drawing region")
            }
            return
        }

        // Priority 1: Resize handle of selected region
        if let handle = hitTestResizeHandle(at: point) {
            beginResize(handle, at: point)
            return
        }

        // Priority 2: Tap on existing region — select, and start move if already selected
        if let tappedRegion = hitTestRegion(at: point) {
            // iPad Shift+tap OR iPhone "Select More" toggle: tap toggles
            // multi-selection, when the touch lifts (`commitPendingToggle`).
            // Both routes converge on the same toggle call — the toolbar
            // toggle layers on top of the existing selection model.
            let shiftHeld = event?.modifierFlags.contains(.shift) ?? false
            if RedactionOverlayView.shouldToggleSelection(
                isMultiSelectActive: isMultiSelectActive,
                shiftHeld: shiftHeld
            ) {
                pendingToggleID = tappedRegion.id
                return
            }

            if selectedIDs.contains(tappedRegion.id), selectedIDs.count == 1 {
                // Single-selected — begin move immediately
                beginMove(for: tappedRegion, at: point)
            } else if selectedIDs.contains(tappedRegion.id), selectedIDs.count > 1 {
                // Multi-selected and tapped one of them — begin group move
                beginGroupMove(at: point, touching: tappedRegion.id)
            } else {
                // Not selected — select it; a drag moves it once selected
                coordinator?.selectRegion(tappedRegion.id)
            }
            return
        }

        // Priority 3: lasso marquee — empty-space touch-down while the
        // "Select More" toggle is on becomes a rect-marquee multi-select drag.
        // Gated on `isMultiSelectActive && !isDrawingMode`:
        // while the Rectangle tool is on, an empty-space drag draws — the
        // marquee never runs in draw mode. The branch is orthogonal to
        // `currentDragRect` — see `marqueeRect` declaration. The
        // undo-grouped commit happens in `touchesEnded` via
        // `coordinator?.commitLassoSelection`.
        if isMultiSelectActive && !isDrawingMode {
            marqueeOrigin = point
            marqueeRect = nil
            isActivelyDragging = true
            // VoiceOver announcement for marquee-in-progress.
            // Mechanism-description language — names the
            // observable affordance without making a promise claim.
            UIAccessibility.post(notification: .announcement,
                                 argument: "Selecting regions")
            return
        }
    }

    // MARK: - Zoom

    /// Current zoom scale on the enclosing `PDFView`, used to scale the
    /// zoom-dependent tolerances. Walks up the
    /// view hierarchy to locate the `PDFView`; defaults to 1.0 when no
    /// PDFView ancestor exists (test surfaces synthesise the overlay
    /// without a PDFView parent — the unit-zoom default keeps the
    /// tolerances under test deterministic).
    func currentZoomScale() -> CGFloat {
        var view: UIView? = self
        while view != nil {
            if let pdf = view as? PDFView {
                return pdf.scaleFactor
            }
            view = view?.superview
        }
        return 1.0
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Only honor the primary touch while a gesture is in flight:
        // a second finger's moves must not steer it.
        guard let primaryTouch,
              let touch = touches.first(where: { $0 === primaryTouch })
        else { return }
        let point = touch.location(in: self)

        if isGroupMoving {
            // Group move — translate all selected regions by delta
            updateGroupMove(to: point)
            setNeedsDisplay()
        } else if isDraggingExistingRegion {
            // Move selected region — update position from touch minus offset
            updateSelectedRegionForMove(to: point)
            setNeedsDisplay()
        } else if let handle = activeResizeHandle {
            // Resize selected region
            updateSelectedRegionForResize(handle: handle, to: point)
            setNeedsDisplay()
        } else if let origin = marqueeOrigin {
            // Lasso marquee — track the marching-ants rect over
            // empty space. The branch is reached only when touchesBegan
            // set `marqueeOrigin` (which it does only when
            // `isMultiSelectActive && empty touch-down`), so the
            // new-region drawing path below is never entered during a
            // marquee drag. No snap-to-guides on the marquee — the
            // rectangle is a selection cursor, not a committed region.
            // No minimum-drag threshold gate so very short drags still
            // surface a tiny visual cue; the intersection at commit will
            // simply select nothing if no region overlaps.
            marqueeRect = CGRect(
                x: min(origin.x, point.x),
                y: min(origin.y, point.y),
                width: abs(point.x - origin.x),
                height: abs(point.y - origin.y)
            )
            setNeedsDisplay()
        } else if let origin = dragOrigin {
            // Draw new region — the 8-pt start gate applies only until the
            // first over-threshold move; after that the band tracks the
            // finger back in as well. A drag that returns
            // to its origin commits nothing (the 20-pt floor rejects it).
            let dx = abs(point.x - origin.x)
            let dy = abs(point.y - origin.y)
            if currentDragRect != nil
                || dx >= Self.minimumDragThreshold * fingerScale
                || dy >= Self.minimumDragThreshold * fingerScale {
                var rect = CGRect(
                    x: min(origin.x, point.x),
                    y: min(origin.y, point.y),
                    width: abs(point.x - origin.x),
                    height: abs(point.y - origin.y)
                )
                // Apply snap guides during new region drawing — anchored
                // edges: only the two edges under the finger
                // snap; the origin corner is invariant by construction.
                rect = snapEngine.applyResizeSnapping(
                    to: rect,
                    handle: Self.drawSnapHandle(origin: origin, point: point),
                    excluding: nil,
                    in: snapPage
                )
                // Clamp the rubber band to the page —
                // mirrors the resize clamp in `updateSelectedRegionForResize`.
                // A band entirely off-page leaves the last rect in place.
                rect = rect.intersection(bounds)
                guard !rect.isNull else { return }
                currentDragRect = rect
                setNeedsDisplay()
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        // A secondary finger's lift must not end — or reset — the primary's
        // gesture. Checked BEFORE the defer on purpose.
        guard let primaryTouch, touches.contains(primaryTouch) else { return }
        defer { resetDragState() }
        if commitPendingToggle() { return }

        // Commit lasso marquee — intersect every visible region's
        // normalizedRect against the marquee's normalized rect; route the
        // hit set through `coordinator?.commitLassoSelection` so the
        // 500-region cap + warning toast land inside `RedactionState`.
        // The intersection uses the existing overlayToPDFNormalized
        // conversion site so the math stays single-sourced with the
        // new-region commit path. Branch is reached only when
        // `marqueeOrigin` was set — guarded by the
        // `isMultiSelectActive && empty touch-down` predicate in
        // `touchesBegan`, so multi-select-off documents never enter here.
        if marqueeOrigin != nil {
            let rect = marqueeRect ?? .zero
            let normalizedMarquee = overlayToPDFNormalized(rect)
            let hits = Self.regionsIntersecting(
                marqueeNormalized: normalizedMarquee,
                regions: regions
            )
            coordinator?.commitLassoSelection(hits)
            return
        }

        // Commit group move, or narrow the selection on a still tap
        if isGroupMoving {
            endGroupMove()
            return
        }

        // Commit single move
        if isDraggingExistingRegion, hasPassedStartSlop, let id = selectedID,
           let region = regions.first(where: { $0.id == id }) {
            moveCommitFeedback.impactOccurred()
            coordinator?.commitMove(id, page: pageIndex,
                                    newRect: region.normalizedRect,
                                    undoManager: window?.undoManager)
            return
        }

        // Commit resize
        if activeResizeHandle != nil, hasPassedStartSlop, let id = selectedID,
           let region = regions.first(where: { $0.id == id }) {
            moveCommitFeedback.impactOccurred(intensity: 0.4)  // a light tick: the resize landed
            coordinator?.commitResize(id, page: pageIndex,
                                      newRect: region.normalizedRect,
                                      undoManager: window?.undoManager)
            return
        }

        // Commit new region
        guard let rect = currentDragRect else { return }

        // Reject a band under the size floor, judged on the band the finger
        // drew (before the guides and the page clamp), so a guide never lifts
        // it over: shrink-to-centre + fade, soft haptic, announcement.
        let lift = primaryTouch.location(in: self)
        let finger = dragOrigin.map { CGSize(width: abs(lift.x - $0.x), height: abs(lift.y - $0.y)) } ?? rect.size
        if !RegionSizeFloor.admits(finger, fingerScale: fingerScale) {
            rejectSubThresholdRegion(rect)
            return
        }

        let normalizedRect = overlayToPDFNormalized(rect)
        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: normalizedRect,
            source: .manual
        )
        moveCommitFeedback.impactOccurred(intensity: 0.4)  // a light tick: the box landed
        coordinator?.addRegion(region, page: pageIndex, undoManager: window?.undoManager)
        // VoiceOver announcement on region commit
        coordinator?.toastManager?.announce("Region added")
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Only the primary touch's cancel discards the gesture;
        // a system cancel of the primary still cancels.
        guard let primaryTouch, touches.contains(primaryTouch) else { return }
        // Discard without committing — restore pre-drag region state
        if isGroupMoving {
            for i in regions.indices {
                if let original = preDragGroupRects[regions[i].id] {
                    regions[i].normalizedRect = original
                }
            }
        } else if isDraggingExistingRegion, let preDragNormalizedRect,
           let selectedID,
           let idx = regions.firstIndex(where: { $0.id == selectedID }) {
            // Restore pre-move position
            regions[idx].normalizedRect = preDragNormalizedRect
        } else if activeResizeHandle != nil, let preResizeNormalizedRect, let selectedID,
                  let idx = regions.firstIndex(where: { $0.id == selectedID }) {
            // Restore the pre-resize rect (nothing was committed)
            regions[idx].normalizedRect = preResizeNormalizedRect
        }
        resetDragState()
        setNeedsDisplay()
    }

    private func resetDragState() {
        coordinator?.setCanvasHoldsTouch(false)
        primaryTouch = nil
        dragOrigin = nil
        currentDragRect = nil
        activeResizeHandle = nil
        isActivelyDragging = false
        // Lasso marquee state cleanup
        marqueeOrigin = nil
        marqueeRect = nil
        // Move state cleanup
        isDraggingExistingRegion = false
        dragOffset = .zero
        preDragNormalizedRect = nil
        preResizeNormalizedRect = nil
        // Group move cleanup
        isGroupMoving = false
        preDragGroupRects = [:]
        dragStartPoint = nil
        hasPassedStartSlop = false
        groupMoveTouchedID = nil
        pendingToggleID = nil
        // Snap state cleanup
        snapEngine.reset()
        // Repaint on gesture end. The commit paths
        // run under `isActivelyDragging`, which makes the coordinator's
        // `configure` a no-op, and the later state sync sees `regions`
        // unchanged (the overlay already holds the final rect) — so this
        // is the only repaint that erases a rejected rubber band, its
        // label and guides, or drops the lifted look after a move/resize.
        setNeedsDisplay()
    }

    /// Animate sub-threshold region rejection with shrink-to-center + fade.
    private func rejectSubThresholdRegion(_ rect: CGRect) {
        rejectionFeedback.impactOccurred(intensity: 0.3)

        // The notice on screen (a toast VoiceOver also reads); the spoken
        // announcement alone when no toast queue is attached.
        if coordinator?.noteRegionTooSmall() != true {
            UIAccessibility.post(
                notification: .announcement,
                argument: RedactionOverlayView.subThresholdRejectionAnnouncement)
        }

        // Visual: create a temporary view that shrinks to center and fades out
        let rejectView = UIView(frame: rect)
        rejectView.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.15)
        rejectView.layer.borderColor = UIColor.systemBlue.cgColor
        rejectView.layer.borderWidth = 2.0
        addSubview(rejectView)

        if UIAccessibility.isReduceMotionEnabled {
            // Respect reduce-motion: simple fade without scale transform
            UIView.animate(withDuration: 0.15, delay: 0, options: .curveEaseOut) {
                rejectView.alpha = 0
            } completion: { _ in
                rejectView.removeFromSuperview()
            }
        } else {
            UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseOut) {
                rejectView.transform = CGAffineTransform(scaleX: 0.01, y: 0.01)
                rejectView.alpha = 0
            } completion: { _ in
                rejectView.removeFromSuperview()
            }
        }
    }
}
