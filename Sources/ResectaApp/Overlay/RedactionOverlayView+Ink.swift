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
/// rectangle (`tight`, the selected text, or the drawn rectangle) and the
/// area a run will paint (`paint`).
nonisolated struct InkBox: Equatable, Sendable {
    let id: UUID
    let tight: CGRect
    let paint: CGRect
    let isSelected: Bool
}

/// One drawing step: every rectangle of a step is drawn as one path, in one
/// style, so a layer costs one draw however many boxes it holds, and filled
/// areas that overlap are filled once.
nonisolated struct InkStep: Equatable, Sendable {
    enum Layer: Equatable, Sendable {
        case edgeKeyline, keyline, veil, edge, inkLine, line, cueUnder, cue, handles, dots, inkRings
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
}

extension RedactionOverlayView {

    /// The steps that draw `boxes`, layer by layer across all of them: the
    /// edge keylines round each `paint`, the keylines round each `tight`,
    /// the veil over the `paint`s, the faint edges round each `paint`, the
    /// ink lines where they are shown, the lines round each `tight` (heavier
    /// when selected), the Differentiate Without Color cue, then handles or
    /// corner dots. Each different `paint` is drawn once. No colour depends
    /// on where a box came from. The boxes being moved (`moving`) are drawn
    /// last, whole, with neither handles nor dots.
    static func inkSteps(
        boxes: [InkBox], selectionCount: Int, handlesActive: Bool, moving: Set<UUID> = [],
        settings: CanvasDisplaySettings, fingerScale: CGFloat = 1
    ) -> [InkStep] {
        let resting = boxes.filter { !moving.contains($0.id) }
        let lifted = boxes.filter { moving.contains($0.id) }
        return layers(for: resting, selectionCount: selectionCount, handlesActive: handlesActive,
                      marks: true, settings: settings, fingerScale: fingerScale)
            + layers(for: lifted, selectionCount: selectionCount, handlesActive: handlesActive,
                     marks: false, settings: settings, fingerScale: fingerScale)
                .map { var s = $0; s.lifted = true; return s }
    }

    private static func layers(
        for boxes: [InkBox], selectionCount: Int, handlesActive: Bool, marks: Bool,
        settings: CanvasDisplaySettings, fingerScale f: CGFloat
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
        guard marks else { return steps.compactMap { $0 } }

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
}
