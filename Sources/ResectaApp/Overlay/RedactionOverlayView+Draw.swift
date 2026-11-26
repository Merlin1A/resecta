import UIKit
import SwiftUI
import RedactionEngine

// The canvas drawing, moved out of `RedactionOverlayView.swift` (the hub)
// along its `// MARK: - Drawing` seam. The hub's `draw(_:)` keeps the
// context, the dirty-rect clip and the ORDER; its body's three segments
// are the three methods below, each drawn exactly as the body drew them
// (the committed regions; the search layer — live preview, highlights,
// the walk's ring; the in-progress shapes — the box being drawn and the
// lasso), followed by the helpers those segments call (the steps' drawing
// and the snap guides).

extension RedactionOverlayView {

    // MARK: - draw(_:) segments

    /// The committed regions, drawn as Ink boxes layer by layer across all
    /// of them (`inkSteps`), with the tags of the boxes at rest and the
    /// handles or corner dots of a selection — the first segment of `draw(_:)`.
    func drawCommittedRegions(ctx: CGContext, in rect: CGRect) {
        // The plan this page is drawn from is kept with its settings.
        coordinator?.noteDrawn(pageIndex: pageIndex, regions: regions)
        let paints = paintRects()
        // Perf: skip boxes entirely outside the dirty rect. The margin covers
        // the shadow (20 overlay points), and whichever reaches further of a
        // handle stepped clear of a thin box (16 on-screen points) and a tag
        // with its gap and keyline, round both the box's own rectangle and
        // the area it paints.
        typealias C = ResectaTokens.Canvas
        let tagReach = C.tag.height + C.tag.gap + C.keylineGap + C.keyline.width
        let margin = max(20, max(16, tagReach) * fingerScale)
        let metadata = coordinator?.redactionState?.regionMetadata
        var boxes: [InkBox] = []
        for region in regions {
            let tight = pdfNormalizedToOverlay(region.normalizedRect)
            let paint = paints[region.id] ?? tight
            guard tight.union(paint).insetBy(dx: -margin, dy: -margin).intersects(rect) else { continue }
            let tag = region.source == .manual ? nil : metadata?[region.id]?.badgeLabel
            boxes.append(InkBox(id: region.id, tight: tight, paint: paint,
                                isSelected: selectedIDs.contains(region.id), tag: tag))
        }
        let moving: Set<UUID> = isDraggingExistingRegion ? selectedIDs : []
        let steps = Self.inkSteps(boxes: boxes, selectionCount: selectedIDs.count,
                                  handlesActive: resizeHandlesActive, moving: moving,
                                  settings: .current, fingerScale: fingerScale, page: bounds)
        for step in steps where !step.lifted { draw(step, ctx: ctx) }

        // The box being moved is drawn whole, on top, on its own rectangles:
        // the shadow alone marks it. The shadow falls on the page, which is
        // white in either appearance, so one dark shadow reads in both; its
        // offset and blur keep one on-screen size at every zoom.
        let lifted = steps.filter(\.lifted)
        guard !lifted.isEmpty else { return }
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 4 * fingerScale), blur: 12 * fingerScale,
                      color: Self.liftShadowColor.cgColor)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        for step in lifted { draw(step, ctx: ctx) }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// Each region's painted area, in overlay points, from the plan this
    /// page was last drawn from; a region the plan holds no box for paints
    /// its own rectangle.
    private func paintRects() -> [UUID: CGRect] {
        guard let plan = coordinator?.redactionState?.drawnPlans[pageIndex] else { return [:] }
        var paints: [UUID: CGRect] = [:]
        for box in plan.boxes {
            let paint = pdfNormalizedToOverlay(box.paint)
            for id in box.regionIDs { paints[id] = paint }
        }
        return paints
    }

    /// Draws one step: a fill of all its rectangles as one path (a width of
    /// zero), a stroke of them and of its lines, or its handles, dots or
    /// rings; a tag's words over its fill.
    private func draw(_ step: InkStep, ctx: CGContext) {
        typealias C = ResectaTokens.Canvas
        ctx.setLineDash(phase: 0, lengths: step.dash)
        switch step.layer {
        case .handles:
            // The disc and its shadow grow in with `handleScale`; the ring
            // keeps its width.
            guard handleScale > 0.001 else { return }
            let radius = C.handle.radius * handleScale * fingerScale
            let shadowRadius = (C.handle.radius + C.handleShadowGrowth) * handleScale * fingerScale
            let drop = C.handleShadowDrop * handleScale * fingerScale
            for p in step.rects.map({ CGPoint(x: $0.midX, y: $0.midY) }) {
                ctx.setFillColor(C.handleShadow.uiColor.cgColor)
                ctx.fillEllipse(in: Self.disc(at: CGPoint(x: p.x, y: p.y + drop), radius: shadowRadius))
                let disc = Self.disc(at: p, radius: radius)
                ctx.setFillColor(C.handle.fill.uiColor.cgColor)
                ctx.fillEllipse(in: disc)
                ctx.setStrokeColor(step.tone.uiColor.cgColor)
                ctx.setLineWidth(step.width)
                ctx.strokeEllipse(in: disc)
            }
        case .dots:
            for dot in step.rects {
                ctx.setFillColor(step.tone.uiColor.cgColor)
                ctx.fillEllipse(in: dot)
                ctx.setStrokeColor(C.selectionDot.ring.uiColor.cgColor)
                ctx.setLineWidth(step.width)
                ctx.strokeEllipse(in: dot)
            }
        case .inkRings:
            ctx.setStrokeColor(step.tone.uiColor.cgColor)
            ctx.setLineWidth(step.width)
            for ring in step.rects { ctx.strokeEllipse(in: ring) }
        default:
            ctx.saveGState()
            ctx.setLineCap(step.roundCaps ? .round : .butt)
            for r in step.rects {
                ctx.addPath(step.corner > 0
                    ? UIBezierPath(roundedRect: r, cornerRadius: step.corner).cgPath
                    : CGPath(rect: r, transform: nil))
            }
            if step.width == 0 {
                ctx.setFillColor(step.tone.uiColor.cgColor)
                ctx.fillPath(using: .winding)
            } else {
                for i in stride(from: 0, to: step.lines.count - 1, by: 2) {
                    ctx.move(to: step.lines[i])
                    ctx.addLine(to: step.lines[i + 1])
                }
                ctx.setStrokeColor(step.tone.uiColor.cgColor)
                ctx.setLineWidth(step.width)
                ctx.strokePath()
            }
            ctx.restoreGState()
            if step.layer == .tag { drawTagWords(step) }
        }
    }

    /// A tag's words, white, centred on its height after its leading padding.
    private func drawTagWords(_ step: InkStep) {
        let tag = ResectaTokens.Canvas.tag
        let font = Self.tagFont(fingerScale: fingerScale)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: tag.words.uiColor]
        for (rect, words) in zip(step.rects, step.words) {
            (words as NSString).draw(
                at: CGPoint(x: rect.minX + tag.padding * fingerScale, y: rect.midY - font.lineHeight / 2),
                withAttributes: attributes)
        }
    }

    /// The search layer over the regions — the live-preview fills, the
    /// search highlights and the result walk's ring — the second segment
    /// of `draw(_:)`.
    func drawSearchLayer(ctx: CGContext, in rect: CGRect) {
        // Live-preview highlights — drawn under committed search highlights
        // so the visual transition (faint → solid yellow) signals "preview →
        // confirmed result". 20% yellow fill, no border.
        if !livePreviewRects.isEmpty {
            ctx.setFillColor(UIColor.systemYellow.withAlphaComponent(0.20).cgColor)
            for normalizedRect in livePreviewRects {
                let viewRect = pdfNormalizedToOverlay(normalizedRect)
                guard viewRect.intersects(rect) else { continue }
                ctx.fill([viewRect])
            }
        }

        // The border and the ring are sized in screen points.
        let strokes = Self.searchMarkStrokes(fingerScale: fingerScale)

        // Draw search highlights on top of regions so overlaps are visible
        for highlight in searchHighlights {
            let viewRect = pdfNormalizedToOverlay(highlight.normalizedRect)
            guard viewRect.intersects(rect) else { continue }
            if highlight.isSelected {
                // Selected: amber fill 30%, amber 2pt border
                ctx.setFillColor(UIColor.systemYellow.withAlphaComponent(0.3).cgColor)
                ctx.setStrokeColor(UIColor.systemOrange.cgColor)
                ctx.setLineWidth(strokes.border)
                ctx.addRect(viewRect)
                ctx.drawPath(using: .fillStroke)
            } else {
                // Deselected: yellow fill 15%, no border
                ctx.setFillColor(UIColor.systemYellow.withAlphaComponent(0.15).cgColor)
                ctx.fill([viewRect])
            }
        }

        // The result walk's current match wears
        // ONE 2-pt brand-tint ring drawn 3 pt OUTSIDE its highlight
        // rect so it sits clear of the selected state's orange border.
        // Fills untouched, no animation (Reduce Motion moot). The tint
        // is the dynamic token (`AccentColorLockstepTests` resolves both
        // appearances from this same UIColor conversion) and `cgColor`
        // resolves against the trait collection UIKit installs for
        // `draw(_:)`.
        if let focusedHighlightID,
           let focused = searchHighlights.first(where: { $0.id == focusedHighlightID }) {
            let ringRect = pdfNormalizedToOverlay(focused.normalizedRect)
                .insetBy(dx: -strokes.ringOutset, dy: -strokes.ringOutset)
            if ringRect.intersects(rect) {
                ctx.setStrokeColor(UIColor(ResectaTokens.BrandTeal.tint).cgColor)
                ctx.setLineWidth(strokes.ring)
                ctx.stroke(ringRect)
            }
        }
    }

    /// The in-progress shapes — the box being drawn and the lasso — the
    /// last segment of `draw(_:)`. Each keeps one on-screen size at every zoom.
    func drawInProgressShapes(ctx: CGContext) {
        let settings = CanvasDisplaySettings.current
        if let dragRect = currentDragRect {
            for step in Self.bandSteps(dragRect, settings: settings, fingerScale: fingerScale) { draw(step, ctx: ctx) }
        }
        if let marqueeRect {
            for step in Self.lassoSteps(marqueeRect, settings: settings, fingerScale: fingerScale) { draw(step, ctx: ctx) }
        }
    }

    /// The square that holds a disc of `radius` centred on `centre`.
    static func disc(at centre: CGPoint, radius: CGFloat) -> CGRect {
        CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
    }

    /// Whether a selected box draws handles: it is the one selected box and
    /// Add to Selection is off. Any other selected box draws corner dots.
    static func showsHandles(isSelected: Bool, selectionCount: Int, handlesActive: Bool) -> Bool {
        isSelected && selectionCount == 1 && handlesActive
    }

    /// The corner dots' centres, in overlay points: the four corners, each
    /// stepped outward on an axis shorter on screen than
    /// `Canvas.dotsStepOutBelow` by half the shortfall, at most
    /// `Canvas.dotLargestStep`.
    static func selectionDotCentres(for rect: CGRect, fingerScale: CGFloat = 1) -> [CGPoint] {
        typealias C = ResectaTokens.Canvas
        func step(_ length: CGFloat) -> CGFloat {
            let onScreen = length / fingerScale
            guard onScreen < C.dotsStepOutBelow else { return 0 }
            return min(C.dotLargestStep, (C.dotsStepOutBelow - onScreen) / 2) * fingerScale
        }
        let dx = step(rect.width), dy = step(rect.height)
        return [
            CGPoint(x: rect.minX - dx, y: rect.minY - dy), CGPoint(x: rect.maxX + dx, y: rect.minY - dy),
            CGPoint(x: rect.minX - dx, y: rect.maxY + dy), CGPoint(x: rect.maxX + dx, y: rect.maxY + dy),
        ]
    }

    // MARK: - On-screen sizes

    /// Overlay points are page points, shown at 1 / `fingerScale`; each size
    /// below is multiplied by `fingerScale` so it keeps one on-screen size.

    /// The lift shadow's colour: the page is white in either appearance.
    static let liftShadowColor = UIColor.black.withAlphaComponent(0.20)

    /// A box's line round its own rectangle, in overlay points:
    /// `Canvas.lineSelected` selected, `Canvas.line` at rest.
    static func regionLineWidth(isSelected: Bool, fingerScale: CGFloat) -> CGFloat {
        (isSelected ? ResectaTokens.Canvas.lineSelected : ResectaTokens.Canvas.line).width * fingerScale
    }

    /// The search layer's two strokes, in overlay units: the picked
    /// highlight's border, 2 on-screen points; the result walk's ring,
    /// 2 on-screen points wide and 3 outside its highlight.
    static func searchMarkStrokes(fingerScale: CGFloat) -> (border: CGFloat, ring: CGFloat, ringOutset: CGFloat) {
        (border: 2 * fingerScale, ring: 2 * fingerScale, ringOutset: 3 * fingerScale)
    }

    /// The selection cue under Differentiate Without Color: a dashed outline
    /// 2 on-screen points wide on every selected box that shows no handles
    /// (a multi-selection, or one box with Add to Selection on), nil
    /// otherwise (a single selection shows its handles).
    static func selectionCue(
        isSelected: Bool, selectionCount: Int, differentiateWithoutColor: Bool, fingerScale: CGFloat,
        handlesActive: Bool = true
    ) -> (lineWidth: CGFloat, dash: [CGFloat])? {
        guard differentiateWithoutColor, isSelected,
              !showsHandles(isSelected: isSelected, selectionCount: selectionCount, handlesActive: handlesActive)
        else { return nil }
        return (2 * fingerScale, [4 * fingerScale, 3 * fingerScale])
    }

    /// Redraw when a display setting the boxes read changes: Differentiate
    /// Without Color (the cue), Reduce Transparency (the veil) and Increase
    /// Contrast (the faint edge, the ink line and rings, and the ink strokes
    /// of the band, the lasso and the guides). One observer each.
    func observeDifferentiateWithoutColor() {
        for name in [UIAccessibility.differentiateWithoutColorDidChangeNotification,
                     UIAccessibility.reduceTransparencyStatusDidChangeNotification,
                     UIAccessibility.darkerSystemColorsStatusDidChangeNotification] {
            NotificationCenter.default.removeObserver(self, name: name, object: nil)
            NotificationCenter.default.addObserver(
                self, selector: #selector(displaySettingDidChange), name: name, object: nil)
        }
    }

    @objc private func displaySettingDidChange() { setNeedsDisplay() }

    /// Draw the active snap guides, each the overlay's full width or height.
    func drawSnapGuides(ctx: CGContext) {
        guard !snapEngine.activeGuides.isEmpty else { return }
        let lines = snapEngine.activeGuides.flatMap { guide in
            guide.isHorizontal
                ? [CGPoint(x: 0, y: guide.position), CGPoint(x: bounds.width, y: guide.position)]
                : [CGPoint(x: guide.position, y: 0), CGPoint(x: guide.position, y: bounds.height)]
        }
        for step in Self.guideSteps(lines: lines, settings: .current, fingerScale: fingerScale) { draw(step, ctx: ctx) }
    }
}
