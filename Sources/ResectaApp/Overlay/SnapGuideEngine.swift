import UIKit
import RedactionEngine

// The canvas's snap guides, moved out of `RedactionOverlayView.swift` (the
// hub) along its `// MARK: - Snap State` and `// MARK: - Snap Engine`
// seams. One engine per overlay: it reads the other regions once per drag,
// snaps a moved, drawn or resized rect to the edges of the regions beside
// it, keeps the active guides the draw pass strokes, and fires the haptic
// and the VoiceOver "Aligned to guide" announcement when a guide holds. The overlay
// passes its page on each call and resets the engine when a gesture ends.

final class SnapGuideEngine {

    /// A snap guide line to draw during interaction.
    struct SnapGuide: Hashable {
        let position: CGFloat
        let isHorizontal: Bool  // true = horizontal line at Y position
    }

    /// Currently active snap guides, populated during drag/resize/move.
    private(set) var activeGuides: [SnapGuide] = []
    /// The guides of the previous frame, and those already announced while
    /// they hold, for the one haptic per held guide.
    private var previousGuides: Set<SnapGuide> = []
    private var announcedGuides: Set<SnapGuide> = []

    /// The other regions' rects for the current drag, read once: regions
    /// cannot change during a drag (the overlay's `isActivelyDragging`
    /// blocks configure). Invalidated on drag end.
    private var cachedOthers: [CGRect]?
    private var cachedExcludeID: UUID?

    /// Haptic for a guide that holds.
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

    private func otherRects(excluding excludeID: UUID?, in page: Page) -> [CGRect] {
        if let cachedOthers, cachedExcludeID == excludeID { return cachedOthers }
        let rects = page.regions.filter { $0.id != excludeID }.map { page.toOverlay($0.normalizedRect) }
        cachedOthers = rects
        cachedExcludeID = excludeID
        return rects
    }

    /// The guides for `rect`: the top and bottom edges of the boxes that
    /// share part of its x-range, and the left and right edges of those
    /// that share part of its y-range. Edges only: no midlines, no page
    /// margins, no page centre.
    static func guideTargets(for rect: CGRect, among others: [CGRect]) -> (horizontal: [CGFloat], vertical: [CGFloat]) {
        var horizontal: [CGFloat] = [], vertical: [CGFloat] = []
        for other in others {
            if other.maxX > rect.minX && other.minX < rect.maxX { horizontal += [other.minY, other.maxY] }
            if other.maxY > rect.minY && other.minY < rect.maxY { vertical += [other.minX, other.maxX] }
        }
        return (horizontal, vertical)
    }

    /// The nearest edge-to-guide pair within `threshold`, or nil.
    static func nearest(_ edges: [CGFloat], to targets: [CGFloat], within threshold: CGFloat) -> (edge: CGFloat, target: CGFloat)? {
        var best: (edge: CGFloat, target: CGFloat)?
        for edge in edges {
            for target in targets where abs(target - edge) <= threshold {
                if best == nil || abs(target - edge) < abs(best!.target - best!.edge) { best = (edge, target) }
            }
        }
        return best
    }

    /// Snap a moved rect: on each axis, the nearer of its two edges aligns
    /// to the nearest guide within reach. Returns the adjusted rect.
    func applySnapping(to rect: CGRect, excluding excludeID: UUID?, in page: Page) -> CGRect {
        let threshold = ResectaTokens.Snap.proximityThreshold * page.fingerScale
        let targets = Self.guideTargets(for: rect, among: otherRects(excluding: excludeID, in: page))
        var result = rect
        var guides: [SnapGuide] = []
        if let y = Self.nearest([rect.minY, rect.maxY], to: targets.horizontal, within: threshold) {
            result.origin.y += y.target - y.edge
            guides.append(SnapGuide(position: y.target, isHorizontal: true))
        }
        if let x = Self.nearest([rect.minX, rect.maxX], to: targets.vertical, within: threshold) {
            result.origin.x += x.target - x.edge
            guides.append(SnapGuide(position: x.target, isHorizontal: false))
        }
        noteGuides(guides)
        return result
    }

    /// Snap a resize (or a drawn band): only the edges `handle` moves align.
    func applyResizeSnapping(
        to rect: CGRect, handle: RedactionOverlayView.ResizeHandle, excluding excludeID: UUID?, in page: Page
    ) -> CGRect {
        let threshold = ResectaTokens.Snap.proximityThreshold * page.fingerScale
        let targets = Self.guideTargets(for: rect, among: otherRects(excluding: excludeID, in: page))
        let edges = RedactionOverlayView.movingEdges(handle)
        var result = rect
        var guides: [SnapGuide] = []
        if edges.top, let y = Self.nearest([result.minY], to: targets.horizontal, within: threshold) {
            result.origin.y = y.target
            result.size.height -= y.target - y.edge
            guides.append(SnapGuide(position: y.target, isHorizontal: true))
        }
        if edges.bottom, let y = Self.nearest([result.maxY], to: targets.horizontal, within: threshold) {
            result.size.height += y.target - y.edge
            guides.append(SnapGuide(position: y.target, isHorizontal: true))
        }
        if edges.left, let x = Self.nearest([result.minX], to: targets.vertical, within: threshold) {
            result.origin.x = x.target
            result.size.width -= x.target - x.edge
            guides.append(SnapGuide(position: x.target, isHorizontal: false))
        }
        if edges.right, let x = Self.nearest([result.maxX], to: targets.vertical, within: threshold) {
            result.size.width += x.target - x.edge
            guides.append(SnapGuide(position: x.target, isHorizontal: false))
        }
        noteGuides(guides)
        return result
    }

    /// Keep the active guides for the draw pass, and give one haptic (and,
    /// under VoiceOver, one "Aligned to guide") for each guide that has held
    /// two frames: a guide the finger passes over in one frame is silent.
    /// Both the move and the resize/draw paths report through here.
    private func noteGuides(_ guides: [SnapGuide]) {
        let now = Set(guides)
        let held = now.intersection(previousGuides).subtracting(announcedGuides)
        if !held.isEmpty {
            snapFeedback.impactOccurred(intensity: 0.4)
            if UIAccessibility.isVoiceOverRunning {
                UIAccessibility.post(notification: .announcement,
                                     argument: "Aligned to guide")
            }
        }
        announcedGuides = announcedGuides.union(held).intersection(now)
        previousGuides = now
        activeGuides = guides
    }

    // MARK: - Reset

    /// Clear the active guides, the haptic de-dupe and the target cache
    /// at the end of a gesture.
    func reset() {
        activeGuides = []
        previousGuides = []
        announcedGuides = []
        cachedOthers = nil
        cachedExcludeID = nil
    }
}
