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
// segments call (polygon fill, resize handles, the type badge, the
// dimension label and the snap guides).

extension RedactionOverlayView {

    // MARK: - draw(_:) segments

    /// The committed regions with their lift, badge, dimension label and
    /// resize handles — the first segment of `draw(_:)`.
    func drawCommittedRegions(ctx: CGContext, in rect: CGRect) {
        // Draw committed regions
        for region in regions {
            let viewRect = pdfNormalizedToOverlay(region.normalizedRect)
            // Perf: Skip regions entirely outside the dirty rect.
            // 20pt expansion accounts for resize handles, badges, and shadow.
            guard viewRect.insetBy(dx: -20, dy: -20).intersects(rect) else { continue }
            let isSelected = selectedIDs.contains(region.id)
            let color = region.displayColor(isSelected: isSelected)
            let isBeingMoved = isSelected && isDraggingExistingRegion

            // Lift effect during move — 1.02× scale + drop shadow
            let drawRect: CGRect
            if isBeingMoved {
                let dx = viewRect.width * 0.01
                let dy = viewRect.height * 0.01
                drawRect = viewRect.insetBy(dx: -dx, dy: -dy)
                ctx.saveGState()
                // The shadow falls on the page, which is white in either
                // appearance, so one dark shadow reads in both; its offset
                // and blur keep one on-screen size at every zoom.
                ctx.setShadow(
                    offset: CGSize(width: 0, height: 4 * fingerScale),
                    blur: 12 * fingerScale,
                    color: Self.liftShadowColor.cgColor
                )
            } else {
                drawRect = viewRect
            }

            // Fill at 30% opacity (60% when reduceTransparency enabled),
            // the border opaque. Stroke: 2 on-screen points unselected, 2.5 selected.
            let fillOpacity: CGFloat = UIAccessibility.isReduceTransparencyEnabled ? 0.6 : 0.3
            ctx.setFillColor(color.withAlphaComponent(fillOpacity).cgColor)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(Self.regionStrokeWidth(isSelected: isSelected, fingerScale: fingerScale))
            ctx.setLineDash(phase: 0, lengths: [])
            // Polygon regions render as filled polygons (even-odd
            // rule). The lift effect for moves still uses the bounding
            // box (drawRect) — the polygon itself is drawn at its real
            // shape inside that box.
            if let vertices = region.vertices, vertices.count >= 3 {
                drawPolygonRegion(
                    ctx: ctx, vertices: vertices
                )
            } else {
                ctx.addRect(drawRect)
                ctx.drawPath(using: .fillStroke)
            }

            if isBeingMoved {
                ctx.restoreGState()
            }

            // PII type badge for detected regions
            drawRegionBadge(ctx: ctx, region: region, rect: drawRect)

            // Dimension label during move
            if isBeingMoved {
                drawDimensionLabel(ctx: ctx, rect: drawRect)
            }

            // Resize handles for selected region (suppressed during move)
            if isSelected && !isBeingMoved && resizeHandlesActive {
                drawResizeHandles(ctx: ctx, rect: drawRect)
            }
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

    /// Draw a committed polygon region. Translates normalized
    /// vertices into overlay-space and fills the closed path with the
    /// caller's current fill color (set by `draw(_:)` before calling
    /// in). Even-odd rule matches the engine fill path (PixelOperations
    /// `fillPath(using: .evenOdd)`).
    private func drawPolygonRegion(
        ctx: CGContext,
        vertices: [CGPoint]
    ) {
        let overlayPoints = vertices.map(normalizedPointToOverlay)
        guard overlayPoints.count >= 3 else { return }
        ctx.beginPath()
        ctx.move(to: overlayPoints[0])
        for p in overlayPoints.dropFirst() {
            ctx.addLine(to: p)
        }
        ctx.closePath()
        ctx.drawPath(using: .eoFillStroke)
    }

    /// Convert a normalized point (0–1, bottom-left origin) into
    /// overlay-space (UIKit top-left origin).
    private func normalizedPointToOverlay(_ point: CGPoint) -> CGPoint {
        let w = bounds.width
        let h = bounds.height
        return CGPoint(x: point.x * w, y: (1.0 - point.y) * h)
    }

    private func drawResizeHandles(ctx: CGContext, rect: CGRect) {
        // Scale handles by animated handleScale (0 = hidden, 1 = full size)
        guard handleScale > 0.001 else { return }

        let handleRadius: CGFloat = 5.0 * handleScale * fingerScale
        // Mid-gray outer ring scales together with the handle so
        // it animates in/out alongside the white-fill / blue-stroke disc.
        let outerStroke = Self.handleRingWidth(handleScale: handleScale, fingerScale: fingerScale)
        let points = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY),
        ]

        ctx.setLineDash(phase: 0, lengths: [])

        for p in points {
            // Mid-gray outer ring drawn under the handle. Pads
            // the handle radius by `outerStroke` on each side so the visible
            // band of grey sits outside the handle's blue border, giving the
            // handle a visible perimeter against white page margins.
            let outerRadius = handleRadius + outerStroke
            let outerRect = CGRect(
                x: p.x - outerRadius, y: p.y - outerRadius,
                width: outerRadius * 2, height: outerRadius * 2
            )
            ctx.setFillColor(UIColor.systemGray2.cgColor)
            ctx.fillEllipse(in: outerRect)

            let handleRect = CGRect(
                x: p.x - handleRadius, y: p.y - handleRadius,
                width: handleRadius * 2, height: handleRadius * 2
            )
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.setStrokeColor(UIColor.systemBlue.cgColor)
            ctx.setLineWidth(1.5 * fingerScale)
            ctx.fillEllipse(in: handleRect)
            ctx.strokeEllipse(in: handleRect)
        }
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

    /// A region's outline: 2.5 on-screen points selected, 2 otherwise.
    static func regionStrokeWidth(isSelected: Bool, fingerScale: CGFloat) -> CGFloat {
        (isSelected ? 2.5 : 2.0) * fingerScale
    }

    /// The grey ring around a resize handle, grown in with `handleScale`.
    static func handleRingWidth(handleScale: CGFloat, fingerScale: CGFloat) -> CGFloat {
        selectionHandleOuterStrokeWidth * handleScale * fingerScale
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
