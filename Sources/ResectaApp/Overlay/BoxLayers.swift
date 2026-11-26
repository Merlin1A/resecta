import CoreGraphics
import Foundation
import RedactionEngine
import UIKit

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

// MARK: - The layers

/// Which box layers a pass applies: every one; those of the boxes whose
/// region ids these are (as their `uuidString`), with every box that shares
/// a fill with one of them; or the handles and dots.
enum BoxLayerScope: Equatable {
    case all
    case keys(Set<String>)
    case handles
}

/// One pass's description of a page's box layers, from the overlay.
struct BoxLayerPass {
    var specs: [LayerSpec]
    var groups: [BoxLayerGroup: GroupStyle]
    /// The kept plan's boxes the steps were made from.
    var planBoxes: [DrawnPlan.Box]
}

/// Where a host's passes come from: the overlay, given the map from its
/// points to the screen's device pixels.
@MainActor
protocol BoxLayerSource: AnyObject {
    func boxLayerPass(toDevice: CGAffineTransform) -> BoxLayerPass
}

/// The committed boxes' layers of one overlay: one container, clipped to the
/// overlay's bounds, holding a plain layer for each group in the boxes'
/// order, each holding a layer for each key. It is the only code that
/// touches them. A pass is asked for with `mark(_:)` and runs in the
/// container's `layoutSublayers(of:)`, once a transaction, never through the
/// view's `layoutSubviews`.
///
/// The look's colours are the same in light and dark, so no layer follows the
/// appearance. A box mark given a dynamic colour would need the layers
/// applied on a trait change too.
@MainActor
final class BoxLayerHost: NSObject, CALayerDelegate {
    /// The container, beneath the top canvas in the overlay's layer.
    let root = CALayer()
    weak var source: BoxLayerSource?
    /// The view the boxes lie in, whose window gives the device's pixels.
    weak var view: UIView?
    private(set) var groupLayers: [BoxLayerGroup: CALayer] = [:]
    private(set) var layers: [String: CALayer] = [:]
    private var applied: [String: LayerSpec] = [:]
    private var lastPlanBoxes: [DrawnPlan.Box]?
    private var pendingAll = false
    private var pendingRegions: Set<String> = []
    private var pendingHandles = false
    /// The passes run, and the keys the last one applied, for the tests.
    private(set) var boxPassCount = 0
    private(set) var lastAppliedKeys: [String] = []

    /// The properties the host sets, each with its implicit action off.
    static let quietActions: [String: CAAction] = Dictionary(uniqueKeysWithValues: [
        "bounds", "position", "frame", "contents", "contentsScale", "backgroundColor", "borderColor",
        "borderWidth", "cornerRadius", "opacity", "hidden", "sublayers", "onOrderIn", "onOrderOut",
        "shadowColor", "shadowOpacity", "shadowRadius", "shadowOffset", "shadowPath",
        "path", "strokeColor", "fillColor", "lineWidth", "lineDashPattern", "lineDashPhase",
    ].map { ($0, NSNull() as CAAction) })

    override init() {
        super.init()
        root.masksToBounds = true
        root.actions = Self.quietActions
        root.delegate = self
        for group in BoxLayerGroup.allCases {
            let layer = CALayer()
            layer.actions = Self.quietActions
            root.addSublayer(layer)
            groupLayers[group] = layer
        }
    }

    /// Whether a pass is asked for and not yet run.
    var isPassPending: Bool { pendingAll || !pendingRegions.isEmpty || pendingHandles }

    /// Asks for a pass over `scope`; scopes asked for in one turn merge by
    /// the union of their keys, and `.all` takes in every other.
    func mark(_ scope: BoxLayerScope) {
        switch scope {
        case .all: pendingAll = true
        case .keys(let keys): pendingRegions.formUnion(keys)
        case .handles: pendingHandles = true
        }
        root.setNeedsLayout()
    }

    nonisolated func action(for layer: CALayer, forKey event: String) -> CAAction? { NSNull() }

    nonisolated func layoutSublayers(of layer: CALayer) {
        let laidOut = ObjectIdentifier(layer)
        MainActor.assumeIsolated {
            guard laidOut == ObjectIdentifier(root) else { return }
            applyPendingPass()
        }
    }

    /// The key's region id: the first part after the mark's name.
    static func regionID(of key: String) -> Substring {
        let parts = key.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        return parts.count > 1 ? parts[1] : Substring(key)
    }

    /// A handle's or a dot's key.
    static func isHandleKey(_ key: String) -> Bool {
        let mark = key.prefix { $0 != ":" }
        return ["handle", "handleRing", "handleShadow", "handleInkRing", "dot", "dotRing", "dotInkRing"]
            .contains(String(mark))
    }

    /// Runs the pass asked for, if one is.
    func applyPendingPass() {
        guard isPassPending, let source else { return }
        let all = pendingAll, handles = pendingHandles
        var regions = pendingRegions
        pendingAll = false; pendingRegions = []; pendingHandles = false
        let (toDevice, unsnapped) = deviceMap()
        let pass = source.boxLayerPass(toDevice: toDevice)
        // Per touch, every box whose plan box changed since the last pass
        // comes too, so a neighbour follows when a join forms or breaks.
        if !all, let last = lastPlanBoxes {
            let now = pass.planBoxes
            for box in now where !last.contains(box) { regions.formUnion(box.regionIDs.map(\.uuidString)) }
            for box in last where !now.contains(box) { regions.formUnion(box.regionIDs.map(\.uuidString)) }
        }
        // A box's keys are those of every region in its plan box.
        for box in pass.planBoxes {
            let ids = Set(box.regionIDs.map(\.uuidString))
            if !ids.isDisjoint(with: regions) { regions.formUnion(ids) }
        }
        lastPlanBoxes = pass.planBoxes
        func inScope(_ key: String) -> Bool {
            all || (handles && Self.isHandleKey(key)) || regions.contains(String(Self.regionID(of: key)))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for group in BoxLayerGroup.allCases {
            guard let layer = groupLayers[group] else { continue }
            layer.frame = root.bounds
            let style = pass.groups[group] ?? GroupStyle(opacity: 1, groupOpacity: false)
            layer.opacity = Float(style.opacity)
            layer.allowsGroupOpacity = style.groupOpacity
        }
        var appliedKeys: [String] = []
        var given = Set<String>()
        for spec in pass.specs where inScope(spec.key) {
            apply(spec)
            appliedKeys.append(spec.key)
            given.insert(spec.key)
        }
        for key in Array(layers.keys) where inScope(key) && !given.contains(key) {
            layers[key]?.removeFromSuperlayer()
            layers[key] = nil
            applied[key] = nil
        }
        // Within a group, the layers lie in the steps' order.
        var order: [BoxLayerGroup: [CALayer]] = [:]
        for spec in pass.specs { if let layer = layers[spec.key] { order[spec.group, default: []].append(layer) } }
        for (group, wanted) in order {
            guard let parent = groupLayers[group] else { continue }
            let now = parent.sublayers ?? []
            if now.count != wanted.count || !zip(now, wanted).allSatisfy({ $0 === $1 }) { parent.sublayers = wanted }
        }
        CATransaction.commit()
        lastAppliedKeys = appliedKeys
        boxPassCount += 1
        // With no window the frames are unsnapped: the pass is still needed,
        // and the window's arrival asks for it.
        if unsnapped { pendingAll = true }
    }

    /// The map from the view's points to the screen's device pixels: where
    /// the view puts its origin and two unit points in its window, times the
    /// screen's scale. With no window, the identity, and the frames are not
    /// on the pixel lines.
    func deviceMap() -> (toDevice: CGAffineTransform, unsnapped: Bool) {
        guard let view, let window = view.window else { return (.identity, true) }
        let o = view.convert(CGPoint.zero, to: nil)
        let x = view.convert(CGPoint(x: 1, y: 0), to: nil)
        let y = view.convert(CGPoint(x: 0, y: 1), to: nil)
        let k = window.screen.scale
        let toDevice = CGAffineTransform(a: (x.x - o.x) * k, b: (x.y - o.y) * k,
                                         c: (y.x - o.x) * k, d: (y.y - o.y) * k,
                                         tx: o.x * k, ty: o.y * k)
        // The boxes are snapped to whole pixels only on a screen that is
        // square to the view, or a quarter turn of it.
        assert(ScreenLink.isAxisAligned(toDevice) || ScreenLink.isQuarterTurn(toDevice),
               "the boxes' view is turned or sheared on the screen")
        return (toDevice, false)
    }

    /// Makes, updates or moves the layer of one key.
    private func apply(_ spec: LayerSpec) {
        guard let parent = groupLayers[spec.group] else { return }
        let layer: CALayer
        if let existing = layers[spec.key], Self.fits(existing, spec.kind) {
            layer = existing
        } else {
            layers[spec.key]?.removeFromSuperlayer()
            layer = Self.make(spec.kind)
            layer.actions = Self.quietActions
            layers[spec.key] = layer
            applied[spec.key] = nil
        }
        if layer.superlayer !== parent { parent.addSublayer(layer) }
        guard applied[spec.key] != spec else { return }
        applied[spec.key] = spec
        Self.configure(layer, spec, scale: root.contentsScale)
    }

    private static func fits(_ layer: CALayer, _ kind: StepKind) -> Bool {
        switch kind {
        case .path: layer is CAShapeLayer
        case .drawn: layer is DrawnMarkLayer
        default: !(layer is CAShapeLayer) && !(layer is DrawnMarkLayer)
        }
    }

    private static func make(_ kind: StepKind) -> CALayer {
        switch kind {
        case .path: CAShapeLayer()
        case .drawn: DrawnMarkLayer()
        default: CALayer()
        }
    }

    private static func cg(_ tone: ResectaTokens.Canvas.Tone?) -> CGColor? {
        tone.map { UIColor(red: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha).cgColor }
    }

    /// Sets every property a kind uses, and clears the rest.
    private static func configure(_ layer: CALayer, _ spec: LayerSpec, scale: CGFloat) {
        layer.frame = spec.frame
        layer.cornerRadius = spec.cornerRadius
        // A fill outside the veils' group carries its own opacity, and its
        // shadow fades with it, as a shadow cast by a faint fill does.
        layer.opacity = Float(spec.opacity ?? 1)
        switch spec.kind {
        case .fill, .disc:
            layer.backgroundColor = cg(spec.fill)
            layer.borderWidth = 0
        case .stroke, .ring:
            layer.backgroundColor = nil
            layer.borderWidth = spec.borderWidth
            layer.borderColor = cg(spec.borderColor)
        case .shadow, .path, .drawn:
            layer.backgroundColor = nil
            layer.borderWidth = 0
        }
        if let shadow = spec.shadow {
            let tone = shadow.color
            layer.shadowColor = UIColor(red: tone.red, green: tone.green, blue: tone.blue, alpha: 1).cgColor
            layer.shadowOpacity = Float(tone.alpha)
            // Core Graphics' blur is about twice Core Animation's radius.
            layer.shadowRadius = shadow.blur / 2
            layer.shadowOffset = shadow.offset
            let bounds = CGRect(origin: .zero, size: spec.frame.size)
            layer.shadowPath = spec.shadowPath == .ellipse ? CGPath(ellipseIn: bounds, transform: nil)
                : CGPath(rect: bounds, transform: nil)
        } else {
            layer.shadowOpacity = 0
            layer.shadowPath = nil
        }
        if let shape = layer as? CAShapeLayer {
            shape.fillColor = nil
            shape.strokeColor = cg(spec.borderColor)
            shape.lineWidth = spec.borderWidth
            shape.lineDashPattern = spec.dash?.map { NSNumber(value: Double($0)) }
            shape.lineDashPhase = spec.dashPhase ?? 0
            shape.path = path(spec.path, frame: spec.frame)
        }
        if let drawn = layer as? DrawnMarkLayer {
            drawn.contentsScale = spec.contentScale ?? scale
            drawn.mark = spec.draw
            drawn.setNeedsDisplay()
        }
    }

    /// A path layer's lines, in the layer's own space.
    static func path(_ descriptor: PathDescriptor?, frame: CGRect) -> CGPath? {
        guard let descriptor else { return nil }
        let toLayer = CGAffineTransform(translationX: -frame.minX, y: -frame.minY)
        switch descriptor {
        case .rect(let r):
            return CGPath(rect: r, transform: [toLayer])
        case .hatch(let h):
            let path = CGMutablePath()
            for (a, b) in hatchSegments(h, in: frame) { path.move(to: a.applying(toLayer)); path.addLine(to: b.applying(toLayer)) }
            return path
        }
    }

    /// The hatch's lines cut to `rect`, in overlay points: lines at `angle`
    /// degrees, rising to the right, `spacing` apart measured square to them,
    /// the line n · p = phase + k × spacing for each whole k, n the lines'
    /// normal, so the first lies `phase` from the overlay's origin.
    static func hatchSegments(_ h: InkStep.Hatch, in rect: CGRect) -> [(CGPoint, CGPoint)] {
        guard h.spacing > 0, !rect.isEmpty, !rect.isNull else { return [] }
        let t = h.angle * .pi / 180
        let n = CGPoint(x: sin(t), y: cos(t)), d = CGPoint(x: cos(t), y: -sin(t))
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
        let along = corners.map { $0.x * n.x + $0.y * n.y }
        guard let lo = along.min(), let hi = along.max() else { return [] }
        var k = ((lo - h.phase) / h.spacing).rounded(.up)
        var out: [(CGPoint, CGPoint)] = []
        while h.phase + k * h.spacing <= hi {
            let c = h.phase + k * h.spacing
            let p0 = CGPoint(x: n.x * c, y: n.y * c)
            // Cut the line p0 + s d to the rectangle.
            var s0 = -CGFloat.infinity, s1 = CGFloat.infinity
            for (pos, dir, minV, maxV) in [(p0.x, d.x, rect.minX, rect.maxX), (p0.y, d.y, rect.minY, rect.maxY)] {
                if abs(dir) < 1e-12 {
                    if pos < minV || pos > maxV { s0 = 1; s1 = 0 }
                } else {
                    let a = (minV - pos) / dir, b = (maxV - pos) / dir
                    s0 = max(s0, min(a, b)); s1 = min(s1, max(a, b))
                }
            }
            if s0 < s1 {
                out.append((CGPoint(x: p0.x + s0 * d.x, y: p0.y + s0 * d.y), CGPoint(x: p0.x + s1 * d.x, y: p0.y + s1 * d.y)))
            }
            k += 1
        }
        return out
    }
}

/// A tag's layer: its fill, its keyline and its words, drawn into its own
/// bitmap at its `contentsScale`, in the words' transform about the tag's
/// centre.
nonisolated final class DrawnMarkLayer: CALayer {
    var mark: DrawnMark?

    override func draw(in ctx: CGContext) {
        guard let mark else { return }
        let toLayer = CGAffineTransform(translationX: -frame.minX, y: -frame.minY)
        let tag = mark.tag.applying(toLayer)
        let k = mark.keyline
        let keyline = tag.insetBy(dx: -k.outset, dy: -k.outset)
        ctx.setStrokeColor(UIColor(red: k.color.red, green: k.color.green, blue: k.color.blue, alpha: k.color.alpha).cgColor)
        ctx.setLineWidth(k.width)
        ctx.addPath(UIBezierPath(roundedRect: keyline, cornerRadius: k.corner).cgPath)
        ctx.strokePath()
        let f = mark.fill
        ctx.setFillColor(UIColor(red: f.red, green: f.green, blue: f.blue, alpha: f.alpha).cgColor)
        ctx.addPath(UIBezierPath(roundedRect: tag, cornerRadius: mark.corner).cgPath)
        ctx.fillPath()
        let text = mark.text, w = mark.wordsTransform
        let font = UIFont.systemFont(ofSize: text.size, weight: text.weight >= 600 ? .semibold : .regular)
        let colour = UIColor(red: text.color.red, green: text.color.green, blue: text.color.blue, alpha: text.color.alpha)
        UIGraphicsPushContext(ctx)
        ctx.saveGState()
        ctx.translateBy(x: tag.midX, y: tag.midY)
        ctx.concatenate(CGAffineTransform(a: w.a, b: w.b, c: w.c, d: w.d, tx: 0, ty: 0))
        ctx.translateBy(x: -tag.midX, y: -tag.midY)
        let origin = CGPoint(x: text.x - frame.minX, y: text.baseline - frame.minY - font.ascender)
        (text.word as NSString).draw(at: origin, withAttributes: [.font: font, .foregroundColor: colour])
        ctx.restoreGState()
        UIGraphicsPopContext()
    }
}
