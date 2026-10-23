import UIKit
import RedactionEngine

// The canvas's snap guides, moved out of `RedactionOverlayView.swift` (the
// hub) along its `// MARK: - Snap State` and `// MARK: - Snap Engine`
// seams. One engine per overlay: it collects the guide targets once per
// drag (the other regions' edges and centres, the page margins and the page
// centre), snaps a moved, drawn or resized rect to them, keeps the active
// guides the draw pass strokes, and fires the haptic and the VoiceOver
// "Aligned to guide" announcement when a new guide appears. The overlay
// passes its page on each call and resets the engine when a gesture ends.

final class SnapGuideEngine {

    /// A snap guide line to draw during interaction.
    struct SnapGuide: Equatable {
        let position: CGFloat
        let isHorizontal: Bool  // true = horizontal line at Y position
    }

    /// Currently active snap guides, populated during drag/resize/move.
    private(set) var activeGuides: [SnapGuide] = []
    /// Track previous guide count for haptic firing (only on new guide appearance).
    private var previousGuideSet: Set<CGFloat> = []

    /// Cached snap guide targets for the current drag session.
    /// Computed once on first use after drag begins, invalidated on drag end.
    private var cachedGuideTargets: (horizontal: [CGFloat], vertical: [CGFloat])?
    private var cachedGuideExcludeID: UUID?

    /// Haptic for snap alignment — fires when a new guide activates.
    private lazy var snapFeedback: UIImpactFeedbackGenerator = {
        let gen = UIImpactFeedbackGenerator(style: .rigid)
        gen.prepare()
        return gen
    }()

    /// What a snap reads from the overlay: its regions, its bounds, the
    /// normalized-to-overlay transform and the finger scale the proximity
    /// threshold is multiplied by. Built fresh for each call.
    struct Page {
        let regions: [RedactionRegion]
        let bounds: CGRect
        let fingerScale: CGFloat
        let toOverlay: (CGRect) -> CGRect
    }

    // MARK: - Snapping

    /// Collect all snap guide positions from other regions, page margins, and page center.
    /// `excluding` omits the region being moved/drawn so it doesn't snap to itself.
    private func collectGuideTargets(excluding excludeID: UUID?, in page: Page) -> (horizontal: [CGFloat], vertical: [CGFloat]) {
        // Return cached targets if available and exclude ID matches.
        // Safe because regions cannot change during a drag (the overlay's isActivelyDragging blocks configure).
        if let cached = cachedGuideTargets, cachedGuideExcludeID == excludeID {
            return cached
        }

        var hTargets: [CGFloat] = []
        var vTargets: [CGFloat] = []

        // Other region edges and centers
        for region in page.regions where region.id != excludeID {
            let rect = page.toOverlay(region.normalizedRect)
            hTargets.append(contentsOf: [rect.minY, rect.midY, rect.maxY])
            vTargets.append(contentsOf: [rect.minX, rect.midX, rect.maxX])
        }

        // Page margins (16pt inset)
        let margin = ResectaTokens.Snap.pageMarginInset
        hTargets.append(contentsOf: [margin, page.bounds.height - margin])
        vTargets.append(contentsOf: [margin, page.bounds.width - margin])

        // Page center lines
        hTargets.append(page.bounds.height / 2)
        vTargets.append(page.bounds.width / 2)

        cachedGuideTargets = (hTargets, vTargets)
        cachedGuideExcludeID = excludeID
        return (hTargets, vTargets)
    }

    /// Apply snapping to a rect. Returns the adjusted rect; populates `activeGuides`.
    /// Fires snap haptic when new guides appear.
    func applySnapping(to rect: CGRect, excluding excludeID: UUID?, in page: Page) -> CGRect {
        let threshold = ResectaTokens.Snap.proximityThreshold * page.fingerScale
        let (hTargets, vTargets) = collectGuideTargets(excluding: excludeID, in: page)

        var result = rect
        var guides: [SnapGuide] = []
        var snappedPositions: Set<CGFloat> = []

        // Horizontal snapping (Y positions): top edge, center, bottom edge
        let yEdges: [(CGFloat, (CGFloat) -> CGFloat)] = [
            (result.minY, { dy in result.origin.y += dy; return result.minY }),
            (result.midY, { dy in result.origin.y += dy; return result.midY }),
            (result.maxY, { dy in result.origin.y += dy; return result.maxY }),
        ]
        for (edgeY, _) in yEdges {
            if let nearest = hTargets.min(by: { abs($0 - edgeY) < abs($1 - edgeY) }),
               abs(nearest - edgeY) <= threshold {
                let dy = nearest - edgeY
                result.origin.y += dy
                guides.append(SnapGuide(position: nearest, isHorizontal: true))
                snappedPositions.insert(nearest)
                break  // Only snap one horizontal edge per frame
            }
        }

        // Vertical snapping (X positions): left edge, center, right edge
        let xEdges: [(CGFloat, (CGFloat) -> CGFloat)] = [
            (result.minX, { dx in result.origin.x += dx; return result.minX }),
            (result.midX, { dx in result.origin.x += dx; return result.midX }),
            (result.maxX, { dx in result.origin.x += dx; return result.maxX }),
        ]
        for (edgeX, _) in xEdges {
            if let nearest = vTargets.min(by: { abs($0 - edgeX) < abs($1 - edgeX) }),
               abs(nearest - edgeX) <= threshold {
                let dx = nearest - edgeX
                result.origin.x += dx
                guides.append(SnapGuide(position: nearest, isHorizontal: false))
                snappedPositions.insert(nearest)
                break  // Only snap one vertical edge per frame
            }
        }

        // Fire haptic only when new guides appear
        let newPositions = snappedPositions.subtracting(previousGuideSet)
        if !newPositions.isEmpty {
            snapFeedback.impactOccurred(intensity: 0.4)
            // VoiceOver announcement — gated to avoid throttling during drag
            if UIAccessibility.isVoiceOverRunning {
                UIAccessibility.post(notification: .announcement,
                                     argument: "Aligned to guide")
            }
        }
        previousGuideSet = snappedPositions
        activeGuides = guides

        return result
    }

    /// Apply snapping to a resize operation. Only snaps the edges that are being moved.
    func applyResizeSnapping(
        to rect: CGRect, handle: RedactionOverlayView.ResizeHandle, excluding excludeID: UUID?, in page: Page
    ) -> CGRect {
        let threshold = ResectaTokens.Snap.proximityThreshold * page.fingerScale
        let (hTargets, vTargets) = collectGuideTargets(excluding: excludeID, in: page)

        var result = rect
        var guides: [SnapGuide] = []
        var snappedPositions: Set<CGFloat> = []

        // Determine which edges move for this handle
        let movesTop = [.topLeft, .topRight, .topCenter].contains(handle)
        let movesBottom = [.bottomLeft, .bottomRight, .bottomCenter].contains(handle)
        let movesLeft = [.topLeft, .bottomLeft, .leftCenter].contains(handle)
        let movesRight = [.topRight, .bottomRight, .rightCenter].contains(handle)

        // Snap moving horizontal edges
        if movesTop, let nearest = hTargets.min(by: { abs($0 - result.minY) < abs($1 - result.minY) }),
           abs(nearest - result.minY) <= threshold {
            let dy = nearest - result.minY
            result.origin.y += dy
            result.size.height -= dy
            guides.append(SnapGuide(position: nearest, isHorizontal: true))
            snappedPositions.insert(nearest)
        }
        if movesBottom, let nearest = hTargets.min(by: { abs($0 - result.maxY) < abs($1 - result.maxY) }),
           abs(nearest - result.maxY) <= threshold {
            result.size.height += nearest - result.maxY
            guides.append(SnapGuide(position: nearest, isHorizontal: true))
            snappedPositions.insert(nearest)
        }

        // Snap moving vertical edges
        if movesLeft, let nearest = vTargets.min(by: { abs($0 - result.minX) < abs($1 - result.minX) }),
           abs(nearest - result.minX) <= threshold {
            let dx = nearest - result.minX
            result.origin.x += dx
            result.size.width -= dx
            guides.append(SnapGuide(position: nearest, isHorizontal: false))
            snappedPositions.insert(nearest)
        }
        if movesRight, let nearest = vTargets.min(by: { abs($0 - result.maxX) < abs($1 - result.maxX) }),
           abs(nearest - result.maxX) <= threshold {
            result.size.width += nearest - result.maxX
            guides.append(SnapGuide(position: nearest, isHorizontal: false))
            snappedPositions.insert(nearest)
        }

        let newPositions = snappedPositions.subtracting(previousGuideSet)
        if !newPositions.isEmpty {
            snapFeedback.impactOccurred(intensity: 0.4)
            // VoiceOver announcement — gated to avoid throttling during
            // drag. The draw path snaps through here:
            // same announcement the move path's `applySnapping`
            // posts, so drawing and resizing both report guide alignment.
            if UIAccessibility.isVoiceOverRunning {
                UIAccessibility.post(notification: .announcement,
                                     argument: "Aligned to guide")
            }
        }
        previousGuideSet = snappedPositions
        activeGuides = guides

        return result
    }

    // MARK: - Reset

    /// Clear the active guides, the haptic de-dupe and the target cache
    /// at the end of a gesture.
    func reset() {
        activeGuides = []
        previousGuideSet = []
        cachedGuideTargets = nil
        cachedGuideExcludeID = nil
    }
}
