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
/// area a run will paint (`paint`), and the words of its tag (nil for a box
/// drawn by hand, or one with no word).
nonisolated struct InkBox: Equatable, Sendable {
    let id: UUID
    let tight: CGRect
    let paint: CGRect
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
    /// edge keylines round each `paint`, the keylines round each `tight`,
    /// the veil over the `paint`s, the faint edges round each `paint`, the
    /// ink lines where they are shown, the lines round each `tight` (heavier
    /// when selected), then the tags of the boxes at rest, then the
    /// Differentiate Without Color cue, then handles or corner dots. Each
    /// different `paint` is drawn once. No colour depends on where a box came
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
        for box in boxes where !paints.contains(box.paint) { paints.append(box.paint) }
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
        steps.append(InkStep(layer: .veil, rects: paints,
                             tone: settings.reduceTransparency ? C.veilReducedTransparency : C.veil, width: 0))
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
