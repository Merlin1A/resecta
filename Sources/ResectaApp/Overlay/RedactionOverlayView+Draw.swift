import UIKit
import SwiftUI
import RedactionEngine

// The canvas drawing, moved out of `RedactionOverlayView.swift` (the hub)
// along its `// MARK: - Drawing` seam. The hub's `draw(_:)` keeps the
// context, the dirty-rect clip and the ORDER; its body's three segments
// are the three methods below, each drawn exactly as the body drew them
// (the committed regions; the search layer — live preview, highlights,
// the walk's ring; the in-progress shapes — rubber band,
// marquee, the resize label), followed by the helpers those
// segments call (resize handles, the type badge, the
// dimension label and the snap guides).

extension RedactionOverlayView {

    // MARK: - draw(_:) segments

    /// The committed regions, drawn as Ink boxes layer by layer across all
    /// of them (`inkSteps`), with their badges, the size label of a box being
    /// moved and the handles or corner dots of a selection — the first
    /// segment of `draw(_:)`.
    func drawCommittedRegions(ctx: CGContext, in rect: CGRect) {
        // The plan this page is drawn from is kept with its settings.
        coordinator?.noteDrawn(pageIndex: pageIndex, regions: regions)
        let paints = paintRects()
        // Perf: skip boxes entirely outside the dirty rect. The margin covers
        // the badge, the shadow and a handle stepped clear of a thin box
        // (16 on-screen points reach it), whichever is larger, round both
        // the box's own rectangle and the area it paints.
        let margin = max(20, 16 * fingerScale)
        var boxes: [InkBox] = []
        var shown: [(RedactionRegion, CGRect)] = []
        for region in regions {
            let tight = pdfNormalizedToOverlay(region.normalizedRect)
            let paint = paints[region.id] ?? tight
            guard tight.union(paint).insetBy(dx: -margin, dy: -margin).intersects(rect) else { continue }
            boxes.append(InkBox(id: region.id, tight: tight, paint: paint,
                                isSelected: selectedIDs.contains(region.id)))
            shown.append((region, tight))
        }
        let moving: Set<UUID> = isDraggingExistingRegion ? selectedIDs : []
        let steps = Self.inkSteps(boxes: boxes, selectionCount: selectedIDs.count,
                                  handlesActive: resizeHandlesActive, moving: moving,
                                  settings: .current, fingerScale: fingerScale)
        let marks: Set<InkStep.Layer> = [.handles, .dots, .inkRings]
        for step in steps where !step.lifted && !marks.contains(step.layer) { draw(step, ctx: ctx) }
        for (region, tight) in shown { drawRegionBadge(ctx: ctx, region: region, rect: tight) }
        for step in steps where !step.lifted && marks.contains(step.layer) { draw(step, ctx: ctx) }

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
        for (region, tight) in shown where moving.contains(region.id) {
            drawRegionBadge(ctx: ctx, region: region, rect: tight)
            drawDimensionLabel(ctx: ctx, rect: tight)
        }
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

    /// Draws one step: a fill of all its rectangles as one path, a stroke of
    /// them, or its handles, dots or rings.
    private func draw(_ step: InkStep, ctx: CGContext) {
        typealias C = ResectaTokens.Canvas
        ctx.setLineDash(phase: 0, lengths: step.dash)
        switch step.layer {
        case .veil:
            ctx.setFillColor(step.tone.uiColor.cgColor)
            ctx.addRects(step.rects)
            ctx.fillPath(using: .winding)
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
            ctx.setStrokeColor(step.tone.uiColor.cgColor)
            ctx.setLineWidth(step.width)
            ctx.addRects(step.rects)
            ctx.strokePath()
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

        // Draw search highlights on top of regions so overlaps are visible
        for highlight in searchHighlights {
            let viewRect = pdfNormalizedToOverlay(highlight.normalizedRect)
            guard viewRect.intersects(rect) else { continue }
            if highlight.isSelected {
                // Selected: amber fill 30%, amber 2pt border
                ctx.setFillColor(UIColor.systemYellow.withAlphaComponent(0.3).cgColor)
                ctx.setStrokeColor(UIColor.systemOrange.cgColor)
                ctx.setLineWidth(2.0)
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
                .insetBy(dx: -3, dy: -3)
            if ringRect.intersects(rect) {
                ctx.setStrokeColor(UIColor(ResectaTokens.BrandTeal.tint).cgColor)
                ctx.setLineWidth(2.0)
                ctx.stroke(ringRect)
            }
        }
    }

    /// The in-progress shapes — the rubber band, the lasso marquee and the
    /// resize dimension label — the last segment of `draw(_:)`.
    func drawInProgressShapes(ctx: CGContext) {
        // Draw in-progress rubber-band rectangle
        if let dragRect = currentDragRect {
            ctx.setFillColor(UIColor.systemBlue.withAlphaComponent(0.15).cgColor)
            ctx.setStrokeColor(UIColor.systemBlue.cgColor)
            ctx.setLineWidth(2.0)
            ctx.setLineDash(phase: 0, lengths: [6, 3])
            ctx.addRect(dragRect)
            ctx.drawPath(using: .fillStroke)
            // Dimension label during drawing
            drawDimensionLabel(ctx: ctx, rect: dragRect)
        }

        // Draw in-progress lasso marquee. Distinguished from the
        // new-region rubber-band by a tint-only system-purple stroke + a
        // sparser dash so the user sees this rectangle as a selection
        // cursor rather than a region commitment. No dimension label —
        // the marquee is transient and the user does not care about its
        // exact size, only the regions it overlaps.
        if let marqueeRect {
            ctx.setFillColor(UIColor.systemPurple.withAlphaComponent(0.10).cgColor)
            ctx.setStrokeColor(UIColor.systemPurple.cgColor)
            ctx.setLineWidth(1.5)
            ctx.setLineDash(phase: 0, lengths: [4, 4])
            ctx.addRect(marqueeRect)
            ctx.drawPath(using: .fillStroke)
        }

        // Dimension label during resize
        if activeResizeHandle != nil, let selectedID,
           let region = regions.first(where: { $0.id == selectedID }) {
            let resizeRect = pdfNormalizedToOverlay(region.normalizedRect)
            drawDimensionLabel(ctx: ctx, rect: resizeRect)
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
    nonisolated static func selectionDotCentres(for rect: CGRect, fingerScale: CGFloat = 1) -> [CGPoint] {
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

    // MARK: - Region Badge

    /// Draw a small type badge at the top-right corner of detected regions.
    /// Suppressed for manual regions, selected regions (resize handles
    /// overlap top-right corner), and regions too small to fit (<30pt width).
    private func drawRegionBadge(ctx: CGContext, region: RedactionRegion, rect: CGRect) {
        guard region.source != .manual,
              region.id != selectedID,
              rect.width >= 30,
              let metadata = coordinator?.redactionState?.regionMetadata[region.id]
        else { return }

        let label = metadata.badgeLabel as NSString
        let fontSize: CGFloat = 9
        let font = UIFont.systemFont(ofSize: fontSize, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white,
        ]
        let textSize = label.size(withAttributes: attributes)
        let badgePadding: CGFloat = ResectaTokens.Spacing.xxs + 1 // 3pt
        let badgeSize = CGSize(
            width: textSize.width + badgePadding * 2,
            height: textSize.height + badgePadding
        )

        // Position: top-right corner of the region rect, inset slightly
        let badgeOrigin = CGPoint(
            x: rect.maxX - badgeSize.width - 2,
            y: rect.minY + 2
        )
        let badgeRect = CGRect(origin: badgeOrigin, size: badgeSize)

        // Badge background — orange for PII, purple for faces
        let badgeColor: UIColor = switch region.source {
        case .detectedPII: .systemOrange
        case .detectedFace: .systemPurple
        case .manual: .systemRed // Unreachable due to guard
        case .searchMatch: .systemGreen
        }
        let path = UIBezierPath(
            roundedRect: badgeRect,
            cornerRadius: ResectaTokens.CornerRadius.small / 2
        )
        ctx.setFillColor(badgeColor.cgColor)
        ctx.addPath(path.cgPath)
        ctx.fillPath()

        // Hairline outer stroke for dark-mode contrast. Drawn
        // after the fill so the stroke sits on the perimeter, not the
        // interior. `UIColor.separator` adapts across light/dark trait.
        ctx.setStrokeColor(UIColor.separator.cgColor)
        ctx.setLineWidth(Self.badgeOuterStrokeWidth)
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.addPath(path.cgPath)
        ctx.strokePath()

        // Badge text
        label.draw(
            at: CGPoint(
                x: badgeOrigin.x + badgePadding,
                y: badgeOrigin.y + badgePadding / 2
            ),
            withAttributes: attributes
        )
    }

    // MARK: - Dimension Label

    /// Draw a dimension label (W x H) near the bottom-right of a rect.
    /// Small regions (<40pt tall) prefer above so the label
    /// doesn't crowd a thin strip from below; taller regions retain the
    /// legacy below posture. When neither above nor below has room inside
    /// the overlay, the label is suppressed rather than clamped on top
    /// of the region.
    private func drawDimensionLabel(ctx: CGContext, rect: CGRect) {
        // The value is page points; the pill keeps one on-screen size.
        let text = "\(Int(rect.width)) \u{00D7} \(Int(rect.height))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.dimensionLabelFont(fingerScale: fingerScale),
            .foregroundColor: UIColor.label,
        ]
        let padding = 4 * fingerScale
        let pillSize = Self.dimensionLabelPillSize(for: text, fingerScale: fingerScale)

        let position = Self.dimensionLabelPosition(
            regionRect: rect,
            pillHeight: pillSize.height,
            overlayHeight: bounds.height,
            gap: 4 * fingerScale
        )

        let pillY: CGFloat
        switch position {
        case .suppressed:
            return
        case .above(let y), .below(let y):
            pillY = y
        }

        // Horizontal: align to the right edge of the region, clamped to
        // overlay bounds so the pill never spills past the left/right edge.
        let rawX = rect.maxX - pillSize.width
        let pillOrigin = CGPoint(
            x: max(0, min(rawX, bounds.width - pillSize.width)),
            y: pillY
        )

        let pillRect = CGRect(origin: pillOrigin, size: pillSize)

        // Background pill
        let pillPath = UIBezierPath(roundedRect: pillRect, cornerRadius: 4 * fingerScale)
        ctx.saveGState()
        ctx.setFillColor(UIColor.systemBackground.withAlphaComponent(0.85).cgColor)
        ctx.addPath(pillPath.cgPath)
        ctx.fillPath()
        ctx.restoreGState()

        // Text
        text.draw(
            at: CGPoint(x: pillOrigin.x + padding, y: pillOrigin.y + padding / 2),
            withAttributes: attributes
        )
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

    static func dimensionLabelFont(fingerScale: CGFloat) -> UIFont {
        UIFont.monospacedDigitSystemFont(ofSize: 11 * fingerScale, weight: .medium)
    }

    /// The size label's pill: the text plus 4 on-screen points of padding.
    static func dimensionLabelPillSize(for text: NSString, fingerScale: CGFloat) -> CGSize {
        let textSize = text.size(withAttributes: [.font: dimensionLabelFont(fingerScale: fingerScale)])
        let padding = 4 * fingerScale
        return CGSize(width: textSize.width + padding * 2, height: textSize.height + padding)
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
    /// Contrast (the faint edge, the ink line and rings). One observer each.
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

    /// Draw active snap guide lines spanning the full overlay.
    func drawSnapGuides(ctx: CGContext) {
        guard !snapEngine.activeGuides.isEmpty else { return }

        ctx.saveGState()
        ctx.setStrokeColor(ResectaTokens.Snap.guideColor.cgColor)
        ctx.setLineWidth(ResectaTokens.Snap.guideLineWidth)
        ctx.setLineDash(phase: 0, lengths: [])

        for guide in snapEngine.activeGuides {
            if guide.isHorizontal {
                ctx.move(to: CGPoint(x: 0, y: guide.position))
                ctx.addLine(to: CGPoint(x: bounds.width, y: guide.position))
            } else {
                ctx.move(to: CGPoint(x: guide.position, y: 0))
                ctx.addLine(to: CGPoint(x: guide.position, y: bounds.height))
            }
        }
        ctx.strokePath()
        ctx.restoreGState()
    }
}
