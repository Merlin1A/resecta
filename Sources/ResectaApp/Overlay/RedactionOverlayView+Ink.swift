import PDFKit
import RedactionEngine
import UIKit

/// The three display settings the canvas reads, read in one place: Reduce
/// Transparency, Increase Contrast and Differentiate Without Color.
nonisolated struct CanvasDisplaySettings: Equatable, Sendable {
    var reduceTransparency = false
    var increaseContrast = false
    var differentiateWithoutColor = false

    /// The settings as the system has them now.
    @MainActor static var current: CanvasDisplaySettings {
        CanvasDisplaySettings(
            reduceTransparency: UIAccessibility.isReduceTransparencyEnabled,
            increaseContrast: UIAccessibility.isDarkerSystemColorsEnabled,
            differentiateWithoutColor: UIAccessibility.shouldDifferentiateWithoutColor)
    }
}

/// One committed box as the canvas draws it, in overlay points: its own
/// rectangle (`tight`, the selected text, or the drawn rectangle), the
/// rectangles a run fills it with before ink growth (`fill`: one for a box
/// that projects, several for one that does not, none when the fill could
/// not be confirmed, so that the box is drawn by its line alone), and the
/// words of its tag (nil for a box drawn by hand, or one with no word).
nonisolated struct InkBox: Equatable, Sendable {
    let id: UUID
    let tight: CGRect
    let fill: [CGRect]
    let isSelected: Bool
    var tag: String? = nil
}

/// One drawing step: every rectangle of a step is drawn as one path, in one
/// style, so a layer costs one draw however many boxes it holds, and filled
/// areas that overlap are filled once.
nonisolated struct InkStep: Equatable, Sendable {
    enum Layer: Equatable, Sendable {
        case edgeKeyline, keyline, veil, edge, inkLine, line, cueUnder, cue, handles, dots, inkRings
        case tagKeyline, tag
        case bandUnder, bandFill, band, lassoUnder, lassoFill, lasso, guideUnder, guide
    }
    let layer: Layer
    /// Stroked or filled rectangles; for handles, dots and rings, the
    /// square of each disc at full size.
    let rects: [CGRect]
    let tone: ResectaTokens.Canvas.Tone
    /// The stroke's width in overlay points; zero for a fill.
    let width: CGFloat
    var dash: [CGFloat] = []
    /// The box being moved: drawn whole, on top, under its shadow.
    var lifted = false
    /// Straight lines stroked with the rectangles, as pairs of end points.
    var lines: [CGPoint] = []
    /// Round caps, so a dash of almost nothing draws a dot.
    var roundCaps = false
    /// Each rectangle's corner radius.
    var corner: CGFloat = 0
    /// For a tag, the words drawn in each rectangle, in order.
    var words: [String] = []
}

extension RedactionOverlayView {

    /// The steps that draw `boxes`, layer by layer across all of them: the
    /// edge keylines round each rectangle of a `fill`, the keylines round
    /// each `tight`, the veil over the fills, the faint edges round each
    /// rectangle of a fill, the ink lines where they are shown, the lines
    /// round each `tight` (heavier when selected), then the tags of the boxes
    /// at rest, then the Differentiate Without Color cue, then handles or
    /// corner dots. Each different rectangle of a fill is drawn once. No colour depends on where a box came
    /// from. The boxes being moved (`moving`) are drawn last, whole, with
    /// neither tags, handles nor dots. `page` is the page in overlay points:
    /// a tag stays inside it.
    static func inkSteps(
        boxes: [InkBox], selectionCount: Int, handlesActive: Bool, moving: Set<UUID> = [],
        settings: CanvasDisplaySettings, fingerScale: CGFloat = 1, page: CGRect = .infinite
    ) -> [InkStep] {
        let resting = boxes.filter { !moving.contains($0.id) }
        let lifted = boxes.filter { moving.contains($0.id) }
        return look(for: resting, settings: settings, fingerScale: fingerScale)
            + tagSteps(for: resting, page: page, fingerScale: fingerScale)
            + marks(for: resting, selectionCount: selectionCount, handlesActive: handlesActive,
                    settings: settings, fingerScale: fingerScale)
            + look(for: lifted, settings: settings, fingerScale: fingerScale)
                .map { var s = $0; s.lifted = true; return s }
    }

    /// The layers of the boxes themselves, from the edge keylines to the lines.
    private static func look(
        for boxes: [InkBox], settings: CanvasDisplaySettings, fingerScale f: CGFloat
    ) -> [InkStep] {
        typealias C = ResectaTokens.Canvas
        guard !boxes.isEmpty else { return [] }
        var paints: [CGRect] = []
        for box in boxes { for rect in box.fill where !paints.contains(rect) { paints.append(rect) } }
        let rest = boxes.filter { !$0.isSelected }.map(\.tight)
        let selected = boxes.filter(\.isSelected).map(\.tight)
        let ink = C.showsInkLine(increaseContrast: settings.increaseContrast)
        let inkWidth = ink ? C.inkLine.width : 0
        func out(_ rects: [CGRect], _ by: CGFloat) -> [CGRect] { rects.map { $0.insetBy(dx: -by * f, dy: -by * f) } }
        func stroke(_ layer: InkStep.Layer, _ rects: [CGRect], _ s: C.Stroke) -> InkStep? {
            rects.isEmpty ? nil : InkStep(layer: layer, rects: rects, tone: s.tone, width: s.width * f)
        }
        var steps: [InkStep?] = [stroke(.edgeKeyline, out(paints, C.edgeKeylineOutset), C.edgeKeyline)]
        for (rects, line) in [(rest, C.line), (selected, C.lineSelected)] {
            steps.append(stroke(.keyline, out(rects, line.width / 2 + C.keylineGap + inkWidth), C.keyline))
        }
        if !paints.isEmpty {
            steps.append(InkStep(layer: .veil, rects: paints,
                                 tone: settings.reduceTransparency ? C.veilReducedTransparency : C.veil, width: 0))
        }
        steps.append(stroke(.edge, paints, settings.increaseContrast ? C.edgeIncreasedContrast : C.edge))
        if ink {
            for (rects, line) in [(rest, C.line), (selected, C.lineSelected)] {
                steps.append(stroke(.inkLine, out(rects, line.width / 2 + C.inkLine.width / 2), C.inkLine))
            }
        }
        steps.append(stroke(.line, rest, C.line))
        steps.append(stroke(.line, selected, C.lineSelected))
        return steps.compactMap { $0 }
    }

    /// The selection's marks: the Differentiate Without Color cue, then the
    /// handles or the corner dots, then their ink rings where they are shown.
    private static func marks(
        for boxes: [InkBox], selectionCount: Int, handlesActive: Bool,
        settings: CanvasDisplaySettings, fingerScale f: CGFloat
    ) -> [InkStep] {
        typealias C = ResectaTokens.Canvas
        let ink = C.showsInkLine(increaseContrast: settings.increaseContrast)
        var steps: [InkStep?] = []
        let handles = boxes.filter {
            showsHandles(isSelected: $0.isSelected, selectionCount: selectionCount, handlesActive: handlesActive)
        }
        let dotted = boxes.filter { $0.isSelected && !handles.contains($0) }
        if settings.differentiateWithoutColor, !dotted.isEmpty,
           let cue = selectionCue(isSelected: true, selectionCount: selectionCount,
                                  differentiateWithoutColor: true, fingerScale: f, handlesActive: handlesActive) {
            let rects = dotted.map { $0.tight.insetBy(dx: -cue.lineWidth * 1.5, dy: -cue.lineWidth * 1.5) }
            steps.append(InkStep(layer: .cueUnder, rects: rects, tone: C.keyline.tone,
                                 width: cue.lineWidth + selectionCueUnderGrowth * f, dash: cue.dash))
            steps.append(InkStep(layer: .cue, rects: rects, tone: C.Tone(red: 0, green: 0, blue: 0, alpha: 1),
                                 width: cue.lineWidth, dash: cue.dash))
        }
        let handleAt = handles.flatMap { box in Self.handleCentres(for: box.tight, fingerScale: f).map(\.1) }
        let dotCentres = dotted.flatMap { selectionDotCentres(for: $0.tight, fingerScale: f) }
        if !handleAt.isEmpty {
            steps.append(InkStep(layer: .handles, rects: handleAt.map { disc(at: $0, radius: C.handle.radius * f) },
                                 tone: C.handle.ring, width: C.handle.ringWidth * f))
        }
        if !dotCentres.isEmpty {
            steps.append(InkStep(layer: .dots, rects: dotCentres.map { disc(at: $0, radius: C.selectionDot.radius * f) },
                                 tone: C.selectionDot.fill, width: C.selectionDot.ringWidth * f))
        }
        if ink {
            let rings = handleAt.map { disc(at: $0, radius: (C.handle.radius + C.handle.ringWidth / 2 + C.inkLine.width / 2) * f) }
                + dotCentres.map { disc(at: $0, radius: (C.selectionDot.radius + C.selectionDot.ringWidth / 2 + C.inkLine.width / 2) * f) }
            if !rings.isEmpty {
                steps.append(InkStep(layer: .inkRings, rects: rings, tone: C.inkLine.tone, width: C.inkLine.width * f))
            }
        }
        return steps.compactMap { $0 }
    }

    /// How much wider than the dashed cue its white under-stroke is, in
    /// on-screen points.
    static let selectionCueUnderGrowth: CGFloat = 1.6

    // MARK: - Tags

    /// The tags of the boxes at rest: each tag's keyline, then its ink fill
    /// with its words. A box being moved or selected shows none.
    private static func tagSteps(for boxes: [InkBox], page: CGRect, fingerScale f: CGFloat) -> [InkStep] {
        typealias C = ResectaTokens.Canvas
        var rects: [CGRect] = [], words: [String] = []
        for box in boxes where !box.isSelected {
            guard let word = box.tag, let rect = tagRect(for: box.tight, words: word, page: page, fingerScale: f)
            else { continue }
            rects.append(rect)
            words.append(word)
        }
        guard !rects.isEmpty else { return [] }
        let gap = C.keylineGap * f
        return [
            InkStep(layer: .tagKeyline, rects: rects.map { $0.insetBy(dx: -gap, dy: -gap) },
                    tone: C.keyline.tone, width: C.keyline.width * f, corner: (C.tag.corner + C.keylineGap) * f),
            InkStep(layer: .tag, rects: rects, tone: C.tag.fill, width: 0, corner: C.tag.corner * f, words: words),
        ]
    }

    /// The tag's font at one on-screen size.
    static func tagFont(fingerScale f: CGFloat) -> UIFont {
        UIFont.systemFont(ofSize: ResectaTokens.Canvas.tag.fontSize * f, weight: .semibold)
    }

    /// A tag's width on screen: its words plus the padding each side.
    static func tagWidth(_ words: String) -> CGFloat {
        let tag = ResectaTokens.Canvas.tag
        let text = (words as NSString).size(withAttributes: [.font: tagFont(fingerScale: 1)])
        return text.width.rounded(.up) + tag.padding * 2
    }

    /// Where the tag of a box whose own rectangle is `tight` sits, in overlay
    /// points, or nil when the box shows none: shorter on screen than
    /// `Canvas.tagShortestBox`, narrower on screen than its tag, or with room
    /// for the tag neither above it nor below it inside `page`. Its leading
    /// edge is flush with the resting line's outer edge; it sits its gap
    /// above the box, or below the box when above would leave the page.
    static func tagRect(for tight: CGRect, words: String, page: CGRect, fingerScale f: CGFloat) -> CGRect? {
        typealias C = ResectaTokens.Canvas
        let width = tagWidth(words)
        guard tight.height / f >= C.tagShortestBox - 1e-9, tight.width / f >= width - 1e-9 else { return nil }
        let height = C.tag.height * f, gap = C.tag.gap * f
        let x = tight.minX - C.line.width / 2 * f
        var y = tight.minY - gap - height
        if y < page.minY { y = tight.maxY + gap }
        guard y + height <= page.maxY else { return nil }
        return CGRect(x: x, y: y, width: width * f, height: height)
    }

    // MARK: - The marks of drawing and choosing

    /// The box being drawn: its white under-stroke, its fill, then its
    /// dashed stroke, page teal (ink under Increase Contrast).
    static func bandSteps(_ rect: CGRect, settings: CanvasDisplaySettings, fingerScale f: CGFloat = 1) -> [InkStep] {
        markSteps(ResectaTokens.Canvas.band, rects: [rect], layers: (.bandUnder, .bandFill, .band),
                  settings: settings, fingerScale: f)
    }

    /// The lasso: its white under-stroke, its fill, then its dotted stroke,
    /// page teal (ink under Increase Contrast).
    static func lassoSteps(_ rect: CGRect, settings: CanvasDisplaySettings, fingerScale f: CGFloat = 1) -> [InkStep] {
        markSteps(ResectaTokens.Canvas.lasso, rects: [rect], layers: (.lassoUnder, .lassoFill, .lasso),
                  settings: settings, fingerScale: f)
    }

    /// The alignment guides, given as pairs of end points: a white
    /// under-stroke, then the guide, page teal (ink under Increase Contrast).
    static func guideSteps(lines: [CGPoint], settings: CanvasDisplaySettings, fingerScale f: CGFloat = 1) -> [InkStep] {
        typealias C = ResectaTokens.Canvas
        guard !lines.isEmpty else { return [] }
        return [
            InkStep(layer: .guideUnder, rects: [], tone: C.underStroke,
                    width: (C.guide.width + C.underStrokeGrowth) * f, lines: lines),
            InkStep(layer: .guide, rects: [], tone: settings.increaseContrast ? C.ink : C.guide.tone,
                    width: C.guide.width * f, lines: lines),
        ]
    }

    /// The rejected band's look, for the view that shrinks and fades: its
    /// fill, its border's colour and its border's width in overlay points.
    static func rejectedBandStyle(fingerScale f: CGFloat) -> (fill: UIColor, border: UIColor, width: CGFloat) {
        let mark = ResectaTokens.Canvas.rejectedBand
        return (mark.fill.uiColor, mark.stroke.tone.uiColor, mark.stroke.width * f)
    }

    private static func markSteps(
        _ mark: ResectaTokens.Canvas.Mark, rects: [CGRect],
        layers: (under: InkStep.Layer, fill: InkStep.Layer, stroke: InkStep.Layer),
        settings: CanvasDisplaySettings, fingerScale f: CGFloat
    ) -> [InkStep] {
        typealias C = ResectaTokens.Canvas
        let dash = mark.dash.map { $0 * f }
        return [
            InkStep(layer: layers.under, rects: rects, tone: C.underStroke,
                    width: (mark.stroke.width + C.underStrokeGrowth) * f, dash: dash, roundCaps: mark.roundCaps),
            InkStep(layer: layers.fill, rects: rects, tone: mark.fill, width: 0),
            InkStep(layer: layers.stroke, rects: rects, tone: settings.increaseContrast ? C.ink : mark.stroke.tone,
                    width: mark.stroke.width * f, dash: dash, roundCaps: mark.roundCaps),
        ]
    }
}

// MARK: - The boxes, with their fills checked

/// What the box maker found for its page: every fill confirmed, one or more
/// not confirmed (a check failed), or nothing checked (the canvas is not yet
/// placed by its PDF view, or no plan is kept for the page).
nonisolated enum CanvasFillCheck: Equatable, Sendable {
    case confirmed, unconfirmed, unchecked
}

extension RedactionOverlayView {

    /// The canvas's boxes for every region of the page, each with the fill
    /// the run makes for it before ink growth, and whether the page's fills
    /// could be confirmed where they are drawn. Every region of the page is
    /// checked, whatever a pass then draws.
    ///
    /// A fill is the kept plan's pixels for its box (`DrawnPlan.Box.fill`),
    /// each as a share of the page as displayed (`ScreenLink.share`) through
    /// `map`, the canvas's one draw map, unsnapped, cut to `clip` (the page
    /// on the canvas, within its bounds). It is confirmed when:
    /// the plan is this page's; the page on the canvas, `page`, is the
    /// geometry's crop size unturned to 0.01 pt; the plan's two sides are
    /// the geometry's displayed sides to 0.016 pt (a side is held in whole
    /// sixty-fourths, rounded up); and each box's fill, cut to `clip`, holds
    /// each of its regions' outlines cut to `clip`, to 1e-6 pt. A page that
    /// fails gives every box no fill; a box that fails gives itself none. A
    /// canvas not yet placed, or a page with no plan, gives no fill and
    /// checks nothing. A region the plan holds no box for has no fill: the
    /// run does not paint it.
    static func inkBoxes(
        regions: [RedactionRegion], plan: DrawnPlan?, pageIndex: Int, geometry: RunRecord.PageGeometry,
        placed: Bool, page: CGRect, clip: CGRect, selectedIDs: Set<UUID>, tags: [UUID: String],
        map: (CGRect) -> CGRect
    ) -> (boxes: [InkBox], check: CanvasFillCheck) {
        let outlines = regions.map { map($0.normalizedRect) }
        func box(_ i: Int, fill: [CGRect]) -> InkBox {
            let id = regions[i].id
            return InkBox(id: id, tight: outlines[i], fill: fill, isSelected: selectedIDs.contains(id), tag: tags[id])
        }
        let lineOnly = regions.indices.map { box($0, fill: []) }
        guard placed, let plan else { return (lineOnly, .unchecked) }
        let crop = geometry.cropBox.size
        let turned = geometry.rotation == 90 || geometry.rotation == 270
        let shown = turned ? CGSize(width: crop.height, height: crop.width) : crop
        guard plan.pageIndex == pageIndex,
              abs(page.width - crop.width) <= 0.01, abs(page.height - crop.height) <= 0.01,
              let w64 = plan.widthSixtyFourths, let h64 = plan.heightSixtyFourths,
              abs(CGFloat(w64) / 64 - shown.width) <= 0.016, abs(CGFloat(h64) / 64 - shown.height) <= 0.016
        else { return (lineOnly, .unconfirmed) }
        var check = CanvasFillCheck.confirmed
        let boxes = regions.indices.map { i -> InkBox in
            guard let planned = plan.boxes.first(where: { $0.regionIDs.contains(regions[i].id) }) else {
                return box(i, fill: [])
            }
            let fill = planned.fill.map { pixels in
                map(ScreenLink.share(
                    pixel: ScreenLink.PixelBox(minX: Int(pixels.minX.rounded()), minY: Int(pixels.minY.rounded()),
                                               maxX: Int(pixels.maxX.rounded()), maxY: Int(pixels.maxY.rounded())),
                    quality: plan.exportDPI, displayedSize: shown))
            }
            let cut = fill.map { $0.intersection(clip) }.filter { !$0.isNull && !$0.isEmpty }
            let outline = outlines[i].intersection(clip)
            guard outline.isNull || outline.isEmpty || fillHolds(outline: outline, fill: cut) else {
                check = .unconfirmed
                return box(i, fill: [])
            }
            return box(i, fill: cut)
        }
        return (boxes, check)
    }

    /// True when the set `fill`'s rectangles cover holds `outline`, never
    /// their bounding box: the outline is cut along every edge of the
    /// rectangles that crosses it, and each piece must lie in one rectangle
    /// grown by 1e-6 pt on each side.
    nonisolated static func fillHolds(outline: CGRect, fill: [CGRect], slack: CGFloat = 1e-6) -> Bool {
        guard !fill.isEmpty else { return false }
        let grown = fill.map { $0.insetBy(dx: -slack, dy: -slack) }
        func cuts(_ lo: CGFloat, _ hi: CGFloat, _ edges: [CGFloat]) -> [CGFloat] {
            Array(Set([lo, hi] + edges.filter { $0 > lo && $0 < hi })).sorted()
        }
        let xs = cuts(outline.minX, outline.maxX, fill.flatMap { [$0.minX, $0.maxX] })
        let ys = cuts(outline.minY, outline.maxY, fill.flatMap { [$0.minY, $0.maxY] })
        let xSpans = xs.count == 1 ? [(xs[0], xs[0])] : zip(xs, xs.dropFirst()).map { ($0, $1) }
        let ySpans = ys.count == 1 ? [(ys[0], ys[0])] : zip(ys, ys.dropFirst()).map { ($0, $1) }
        for (x0, x1) in xSpans {
            for (y0, y1) in ySpans {
                let held = grown.contains { r in r.minX <= x0 && r.minY <= y0 && r.maxX >= x1 && r.maxY >= y1 }
                if !held { return false }
            }
        }
        return true
    }

    /// True once PDFKit has placed this canvas: it has its PDF view, and the
    /// view's document has the canvas's page, so the page's rectangle on the
    /// canvas comes from PDFKit and not from the fallback.
    var isPlacedOnItsPage: Bool {
        guard let view = hostPDFView else { return false }
        return view.document?.page(at: pageIndex) != nil
    }
}
