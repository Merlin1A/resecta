import CoreGraphics
import Foundation

/// What a box layer is: a filled rectangle, a stroked one, a disc, a ring, a
/// shadow, a path (a hatch, or a dashed outline) or a mark drawn into the
/// layer's own bitmap (a tag).
nonisolated enum StepKind: Equatable, Sendable {
    case fill, stroke, disc, ring, shadow, path, drawn
}

/// A layer's shadow: its colour, its blur as Core Graphics gives one, and
/// its offset, in overlay points.
nonisolated struct ShadowSpec: Equatable, Sendable {
    var color: ResectaTokens.Canvas.Tone
    var blur: CGFloat
    var offset: CGSize
}

/// The shape a layer's shadow takes: an ellipse in its frame, or its frame.
nonisolated enum ShadowPath: Equatable, Sendable {
    case ellipse, frame
}

/// A path layer's lines: the whole page's hatch, or a rectangle (the
/// Differentiate Without Color cue and its under-stroke).
nonisolated enum PathDescriptor: Equatable, Sendable {
    case hatch(InkStep.Hatch)
    case rect(CGRect)
}

/// A tag, as its layer draws it into its own bitmap: the ink fill with its
/// corner, its keyline, and its words, in the words' transform about the
/// tag's centre. Sizes in overlay points.
nonisolated struct DrawnMark: Equatable, Sendable {
    nonisolated struct Keyline: Equatable, Sendable {
        var color: ResectaTokens.Canvas.Tone
        var width: CGFloat
        var outset: CGFloat
        var corner: CGFloat
    }
    nonisolated struct Text: Equatable, Sendable {
        var word: String
        var size: CGFloat
        /// The font's weight on the CSS scale: 600 is semibold.
        var weight: Int
        var color: ResectaTokens.Canvas.Tone
        var x: CGFloat
        var baseline: CGFloat
    }
    var tag: CGRect
    var fill: ResectaTokens.Canvas.Tone
    var corner: CGFloat
    var keyline: Keyline
    var text: Text
    var wordsTransform: InkStep.WordsTransform
}

/// One box layer, described: where it sits and how it looks, in overlay
/// points. Nothing here draws.
nonisolated struct LayerSpec: Equatable, Sendable {
    var key: String
    var group: BoxLayerGroup
    var kind: StepKind
    var frame: CGRect
    var cornerRadius: CGFloat = 0
    var fill: ResectaTokens.Canvas.Tone? = nil
    var borderWidth: CGFloat = 0
    var borderColor: ResectaTokens.Canvas.Tone? = nil
    /// A fill's own opacity, outside the veils' group (whose group carries it).
    var opacity: CGFloat? = nil
    var dash: [CGFloat]? = nil
    var dashPhase: CGFloat? = nil
    var path: PathDescriptor? = nil
    var draw: DrawnMark? = nil
    /// A drawn mark's device pixels a point, at most `BoxLayers.contentCap`.
    var contentScale: CGFloat? = nil
    var shadow: ShadowSpec? = nil
    var shadowPath: ShadowPath? = nil
}

/// A group's opacity, and whether it is applied to the group as a whole, so
/// that overlapping members are not darker where they overlap.
nonisolated struct GroupStyle: Equatable, Sendable {
    var opacity: CGFloat
    var groupOpacity: Bool
}

/// The boxes' drawing steps as layer descriptions, one for each key.
nonisolated enum BoxLayers {
    /// The most device pixels a point a drawn mark is drawn at.
    static let contentCap: CGFloat = 24
    /// The lift's shadow: black at 20 %, a Core Graphics blur of 12 on-screen
    /// points, 4 on-screen points down.
    static let liftShadow = ResectaTokens.Canvas.Tone(red: 0, green: 0, blue: 0, alpha: 0.2)
    static let liftShadowBlur: CGFloat = 12
    static let liftShadowDrop: CGFloat = 4
    /// A tag's words' baseline below the tag's top, in on-screen points.
    static let tagBaseline: CGFloat = 10.9
    /// The tag's font weight on the CSS scale (semibold).
    static let tagWeight = 600

    /// One layer description for each key of `steps`, in their order, and
    /// the groups' styles: the veils' group carries the veils' opacity, so
    /// that overlapping veils are not darker where they overlap; a group not
    /// named has opacity 1. `toDevice` maps overlay points to the screen's
    /// device pixels; `clip` is the page on the canvas.
    ///
    /// A veil's frame is its fill moved outward to whole device pixel lines
    /// (`ScreenLink.fillRect`); a mark on a fill (`onPaint`) is framed from
    /// the veil whose key has the same suffix after its mark's name, grown
    /// by its `outset`; a stroke's frame is its rectangle grown by half its
    /// width; a handle gives its shadow, its disc and its ring, a dot its
    /// disc and its ring; a tag's keyline and fill give one drawn mark. The
    /// marks of drawing and choosing give none.
    static func specs(steps: [InkStep], toDevice: CGAffineTransform, clip: CGRect)
        -> (specs: [LayerSpec], groups: [BoxLayerGroup: GroupStyle]) {
        typealias C = ResectaTokens.Canvas
        func suffix(_ key: String) -> String {
            key.firstIndex(of: ":").map { String(key[key.index(after: $0)...]) } ?? key
        }
        func out(_ r: CGRect, _ by: CGFloat) -> CGRect { r.insetBy(dx: -by, dy: -by) }
        // Each veil's frame on the device's pixel lines, by its key's suffix.
        var snapped: [(suffix: String, frame: CGRect)] = []
        for step in steps where step.layer == .veil {
            for (rect, key) in zip(step.rects, step.keys) {
                snapped.append((suffix(key), ScreenLink.fillRect(rect, toDevice: toDevice, clip: clip)))
            }
        }
        func veilFrame(_ suffix: String) -> CGRect? { snapped.first { $0.suffix == suffix }?.frame }
        var tagKeylines: [String: (rect: CGRect, step: InkStep)] = [:]
        for step in steps where step.layer == .tagKeyline {
            for (rect, key) in zip(step.rects, step.keys) { tagKeylines[suffix(key)] = (rect, step) }
        }
        let scale = sqrt(abs(toDevice.a * toDevice.d - toDevice.b * toDevice.c))
        var specs: [LayerSpec] = []
        for step in steps {
            guard let group = step.group else { continue }
            let f = step.fingerScale, w = step.width
            for (i, (rect, key)) in zip(step.rects, step.keys).enumerated() {
                switch step.layer {
                case .veil where group == .veils:
                    specs.append(LayerSpec(key: key, group: group, kind: .fill, frame: veilFrame(suffix(key)) ?? rect,
                                           fill: opaque(step.tone)))
                case .veil:
                    // The box being moved: its veil carries its own opacity
                    // and the lift's shadow.
                    specs.append(LayerSpec(
                        key: key, group: group, kind: .fill,
                        frame: ScreenLink.fillRect(rect, toDevice: toDevice, clip: clip),
                        fill: opaque(step.tone), opacity: step.tone.alpha,
                        shadow: ShadowSpec(color: liftShadow, blur: liftShadowBlur * f,
                                           offset: CGSize(width: 0, height: liftShadowDrop * f))))
                case .wholeVeil:
                    specs.append(LayerSpec(key: key, group: group, kind: .fill,
                                           frame: ScreenLink.fillRect(rect, toDevice: toDevice, clip: clip),
                                           fill: opaque(step.tone), opacity: step.tone.alpha))
                case .edgeKeyline, .keyline, .edge, .inkLine, .line, .wholeKeyline, .wholeFrame:
                    let on = step.onPaint ? veilFrame(suffix(key)).map { out($0, step.outset) } : nil
                    specs.append(LayerSpec(key: key, group: group, kind: .stroke, frame: out(on ?? rect, w / 2),
                                           borderWidth: w, borderColor: step.tone))
                case .cueUnder, .cue:
                    let dashed = !step.dash.isEmpty
                    specs.append(LayerSpec(key: key, group: group, kind: .path, frame: out(rect, w / 2),
                                           borderWidth: w, borderColor: step.tone,
                                           dash: dashed ? step.dash : nil, dashPhase: dashed ? 0 : nil,
                                           path: .rect(rect)))
                case .wholeHatchKey, .wholeHatch:
                    specs.append(LayerSpec(key: key, group: group, kind: .path, frame: rect,
                                           borderWidth: w, borderColor: step.tone, path: step.hatch.map { .hatch($0) }))
                case .handles:
                    // The disc and its shadow at the handles' scale; the ring
                    // at its own width.
                    let k = step.handleScale
                    guard k > 0.001 else { continue }
                    let name = suffix(key), centre = CGPoint(x: rect.midX, y: rect.midY)
                    let r = C.handle.radius * k * f
                    let rs = (C.handle.radius + C.handleShadowGrowth) * k * f
                    let drop = C.handleShadowDrop * k * f
                    let disc = CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r)
                    let ring = out(disc, w / 2)
                    specs.append(LayerSpec(
                        key: "handleShadow:\(name)", group: group, kind: .shadow,
                        frame: CGRect(x: centre.x - rs, y: centre.y + drop - rs, width: 2 * rs, height: 2 * rs),
                        cornerRadius: rs, shadow: ShadowSpec(color: C.handleShadow, blur: 0, offset: .zero),
                        shadowPath: .ellipse))
                    specs.append(LayerSpec(key: key, group: group, kind: .disc, frame: disc, cornerRadius: r,
                                           fill: C.handle.fill))
                    specs.append(LayerSpec(key: "handleRing:\(name)", group: group, kind: .ring, frame: ring,
                                           cornerRadius: ring.width / 2, borderWidth: w, borderColor: step.tone))
                case .dots:
                    let ring = out(rect, w / 2)
                    specs.append(LayerSpec(key: key, group: group, kind: .disc, frame: rect,
                                           cornerRadius: rect.width / 2, fill: step.tone))
                    specs.append(LayerSpec(key: "dotRing:\(suffix(key))", group: group, kind: .ring, frame: ring,
                                           cornerRadius: ring.width / 2, borderWidth: w,
                                           borderColor: C.selectionDot.ring))
                case .inkRings:
                    let ring = out(rect, w / 2)
                    specs.append(LayerSpec(key: key, group: group, kind: .ring, frame: ring,
                                           cornerRadius: ring.width / 2, borderWidth: w, borderColor: step.tone))
                case .tag:
                    guard let keyline = tagKeylines[suffix(key)], i < step.words.count else { continue }
                    let mark = DrawnMark(
                        tag: rect, fill: step.tone, corner: step.corner,
                        keyline: .init(color: keyline.step.tone, width: keyline.step.width,
                                       outset: C.keylineGap * f, corner: keyline.step.corner),
                        text: .init(word: step.words[i], size: C.tag.fontSize * f, weight: tagWeight,
                                    color: C.tag.words, x: rect.minX + C.tag.padding * f,
                                    baseline: rect.minY + tagBaseline * f),
                        wordsTransform: i < step.wordsTransforms.count ? step.wordsTransforms[i] : .identity)
                    specs.append(LayerSpec(key: key, group: group, kind: .drawn,
                                           frame: out(keyline.rect, keyline.step.width / 2),
                                           draw: mark, contentScale: min(scale, contentCap)))
                case .tagKeyline, .bandUnder, .bandFill, .band, .lassoUnder, .lassoFill, .lasso, .guideUnder, .guide:
                    continue
                }
            }
        }
        let veil = steps.first { $0.layer == .veil && $0.group == .veils }
        return (specs, [.veils: GroupStyle(opacity: veil?.tone.alpha ?? C.veil.alpha, groupOpacity: true)])
    }

    /// A tone at full opacity.
    private static func opaque(_ tone: ResectaTokens.Canvas.Tone) -> ResectaTokens.Canvas.Tone {
        ResectaTokens.Canvas.Tone(red: tone.red, green: tone.green, blue: tone.blue, alpha: 1)
    }
}
