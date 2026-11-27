import CryptoKit
import Foundation
import Testing
import UIKit
@testable import ResectaApp

private final class BoxLayerCasesBundle: NSObject {}

// The boxes' drawing steps as plain values, and the layer each becomes. The
// case table is Cases/box-layers.json; its values are exact rationals, its
// rectangles in overlay points, origin top-left, y down. Each row gives a
// page's boxes and the steps a reference made for them, one for each mark,
// with each mark's key, and the layers those steps become.
@Suite("Box layers: the steps as plain values, and the layers they become")
@MainActor
struct BoxLayerSpecTests {
    /// The repo copy of the table of record (sha256 2cdfb5bf…): its rows
    /// unchanged, its prose without citations.
    static let tableSHA256 = "1869e64360e34b308fae3433828bbcdacdc6fe1a46786b261de5d6aab35992b9"
    static let rowCount = 26

    // MARK: - The table

    static func rows() throws -> [[String: Any]] {
        let url = try #require(Bundle(for: BoxLayerCasesBundle.self).url(
            forResource: "box-layers", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(digest == tableSHA256)
        let doc = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(doc["rule"] as? String == "box-layers")
        let cases = try #require(doc["cases"] as? [[String: Any]])
        #expect(cases.count == rowCount)
        return cases
    }

    static func row(_ id: String) throws -> [String: Any] {
        try #require(try rows().first { $0["id"] as? String == id }, "no row \(id)")
    }

    /// One rational, as one correctly rounded division.
    static func num(_ any: Any?) throws -> CGFloat {
        let pair = try #require(any as? [Int])
        return CGFloat(Double(pair[0]) / Double(pair[1]))
    }

    static func rect(_ any: Any?) throws -> CGRect {
        let r = try #require(any as? [String: Any])
        return CGRect(x: try num(r["x"]), y: try num(r["y"]), width: try num(r["w"]), height: try num(r["h"]))
    }

    /// A row's boxes as the canvas holds them, each region's name given an
    /// id of its own, and the names by id to read keys back.
    static func boxes(_ inputs: [String: Any]) throws -> (boxes: [InkBox], names: [UUID: String], ids: [String: UUID]) {
        let list = try #require(inputs["boxes"] as? [[String: Any]])
        var boxes: [InkBox] = [], names: [UUID: String] = [:], ids: [String: UUID] = [:]
        for b in list {
            let name = try #require(b["id"] as? String)
            let id = UUID()
            names[id] = name
            ids[name] = id
            let fills = try (b["fills"] as? [Any])?.map { try rect($0) }
            boxes.append(InkBox(id: id, tight: try rect(b["line"]), fill: try fills ?? [rect(b["paint"])],
                                isSelected: b["selected"] as? Bool ?? false, tag: b["tagWord"] as? String))
        }
        return (boxes, names, ids)
    }

    static func settings(_ inputs: [String: Any]) -> CanvasDisplaySettings {
        let s = inputs["settings"] as? [String: Any] ?? [:]
        return CanvasDisplaySettings(reduceTransparency: s["reduceTransparency"] as? Bool ?? false,
                                     increaseContrast: s["increaseContrast"] as? Bool ?? false,
                                     differentiateWithoutColor: s["differentiateWithoutColor"] as? Bool ?? false)
    }

    /// The app's own steps for a row's boxes.
    static func appSteps(_ inputs: [String: Any], boxes: [InkBox], ids: [String: UUID]) throws -> [InkStep] {
        let zoom = try num(inputs["zoom"])
        let selected = boxes.filter(\.isSelected).count
        let moving: Set<UUID> = (inputs["moving"] as? String).flatMap { ids[$0] }.map { [$0] } ?? []
        return RedactionOverlayView.inkSteps(
            boxes: boxes, selectionCount: selected, handlesActive: inputs["single"] is String, moving: moving,
            settings: settings(inputs), fingerScale: 1 / zoom, page: try rect(inputs["clip"]),
            handleScale: try num(inputs["handleScale"]))
    }

    /// A key with each id put back as the region's name.
    static func named(_ key: String, _ names: [UUID: String]) -> String {
        names.reduce(key) { $0.replacingOccurrences(of: "\($1.key)", with: $1.value) }
    }

    // MARK: - The steps' fields

    /// The marks the app makes, as the table names them.
    static let markOfLayer: [InkStep.Layer: String] = [
        .edgeKeyline: "edgeKeyline", .keyline: "keyline", .veil: "veil", .edge: "edge", .inkLine: "inkLine",
        .line: "line", .cueUnder: "cueUnder", .cue: "cue", .handles: "handle", .dots: "dot",
    ]

    /// The rows the app's own step maker can make: every row but the whole
    /// page's, which no step maker of the app makes yet.
    static let madeByTheApp = [
        "b1-at-rest-fit", "b2-at-rest-zoom-2", "b2-at-rest-zoom-5.12", "b3-two-overlapping-paints",
        "b4-selected-handle-scale-1", "b4-selected-handle-scale-0.5", "b6-quarter-turn", "two-regions-one-paint",
        "ic-ink-line", "rt-veil", "dots-several-selected", "lift-at-fit", "lift-at-zoom-2",
        "dwc-cue-several-selected", "dwc-cue-add-to-selection", "dwc-no-cue-with-handles", "b10-two-fill-rectangles",
    ]

    @Test("Every step keys each of its rectangles, by the table's scheme, the same in every pass; a mark on a fill hugs its own veil")
    func stepFields() throws {
        for id in Self.madeByTheApp {
            let row = try Self.row(id)
            let inputs = try #require(row["inputs"] as? [String: Any])
            let expected = try #require(row["expected"] as? [String: Any])
            let made = try Self.boxes(inputs)
            let steps = try Self.appSteps(inputs, boxes: made.boxes, ids: made.ids)
            for step in steps {
                #expect(step.keys.count == step.rects.count, "\(id): \(step.layer) has a key for each rectangle")
            }
            let all = steps.flatMap(\.keys)
            #expect(Set(all).count == all.count, "\(id): no key twice in a pass")
            let again = try Self.appSteps(inputs, boxes: made.boxes, ids: made.ids)
            #expect(again.map(\.keys) == steps.map(\.keys), "\(id): the same keys in a second pass")
            // Each mark's keys are the table's for that mark.
            let table = try #require(expected["steps"] as? [[String: Any]])
            for (layer, mark) in Self.markOfLayer {
                let given = steps.filter { $0.layer == layer }.flatMap(\.keys).map { Self.named($0, made.names) }.sorted()
                let want = table.filter { $0["mark"] as? String == mark }.compactMap { $0["key"] as? String }.sorted()
                #expect(given == want, "\(id): the keys of every \(mark)")
            }
            // Only the edge keyline and the faint edge sit on a fill.
            for step in steps {
                let onPaint = step.layer == .edgeKeyline || step.layer == .edge
                #expect(step.onPaint == onPaint, "\(id): \(step.layer) on the fill")
                let outset = step.layer == .edgeKeyline ? ResectaTokens.Canvas.edgeKeylineOutset * step.fingerScale : 0
                #expect(abs(step.outset - outset) < 1e-12, "\(id): \(step.layer)'s outset")
            }
        }
        // A fill shared by two regions: one veil, one faint edge and one edge
        // keyline, keyed by the first region in input order.
        let shared = try Self.row("two-regions-one-paint")
        let inputs = try #require(shared["inputs"] as? [String: Any])
        let made = try Self.boxes(inputs)
        let veils = try Self.appSteps(inputs, boxes: made.boxes, ids: made.ids).filter { $0.layer == .veil }
        #expect(veils.flatMap(\.keys).map { Self.named($0, made.names) } == ["veil:p"])
        // A box with two fill rectangles numbers them.
        let two = try Self.row("b10-two-fill-rectangles")
        let twoInputs = try #require(two["inputs"] as? [String: Any])
        let twoMade = try Self.boxes(twoInputs)
        let twoSteps = try Self.appSteps(twoInputs, boxes: twoMade.boxes, ids: twoMade.ids)
        for mark in ["veil", "edge", "edgeKeyline"] {
            let keys = twoSteps.flatMap(\.keys).map { Self.named($0, twoMade.names) }.filter { $0.hasPrefix(mark + ":") }
            #expect(keys == ["\(mark):name:0", "\(mark):name:1"], "b10: the \(mark)s")
        }
        // Each edge and edge keyline framed from the veil with its suffix.
        let specs = BoxLayers.specs(steps: twoSteps, toDevice: try Self.transform(twoInputs["transform"]),
                                    clip: try Self.rect(twoInputs["clip"])).specs
        func frame(_ key: String) throws -> CGRect {
            try #require(specs.first { Self.named($0.key, twoMade.names) == key }, "no \(key)").frame
        }
        let f = twoSteps.first?.fingerScale ?? 1
        let edgeWidth = ResectaTokens.Canvas.edge.width * f, keyWidth = ResectaTokens.Canvas.edgeKeyline.width * f
        let outset = ResectaTokens.Canvas.edgeKeylineOutset * f
        for i in 0 ..< 2 {
            let veil = try frame("veil:name:\(i)")
            let edge = try frame("edge:name:\(i)"), edgeKeyline = try frame("edgeKeyline:name:\(i)")
            #expect(Self.close(edge, veil.insetBy(dx: -edgeWidth / 2, dy: -edgeWidth / 2)), "edge \(i)")
            #expect(Self.close(edgeKeyline, veil.insetBy(dx: -outset - keyWidth / 2, dy: -outset - keyWidth / 2)),
                    "edge keyline \(i)")
        }
        let first = try frame("edge:name:0"), second = try frame("edge:name:1")
        #expect(first != second, "the two edges differ: the seam shows")
    }

    @Test("Each step's group is its layer's, in the boxes' order; the box being moved is on top")
    func stepGroups() {
        typealias L = InkStep.Layer
        let order: [(L, BoxLayerGroup)] = [
            (.edgeKeyline, .edgeKeylines), (.keyline, .keylines), (.veil, .veils), (.edge, .edges),
            (.inkLine, .inkLines), (.line, .lines), (.tagKeyline, .tags), (.tag, .tags),
            (.wholeHatchKey, .wholePage), (.wholeKeyline, .wholePage), (.wholeVeil, .wholePage),
            (.wholeHatch, .wholePage), (.wholeFrame, .wholePage),
            (.cueUnder, .handles), (.cue, .handles), (.handles, .handles), (.dots, .handles), (.inkRings, .handles),
        ]
        let tone = ResectaTokens.Canvas.ink
        for (layer, group) in order {
            #expect(InkStep(layer: layer, rects: [], tone: tone, width: 0).group == group, "\(layer)")
            #expect(InkStep(layer: layer, rects: [], tone: tone, width: 0, lifted: true).group == .moving, "\(layer) lifted")
        }
        for layer in [L.bandUnder, .bandFill, .band, .lassoUnder, .lassoFill, .lasso, .guideUnder, .guide] {
            #expect(InkStep(layer: layer, rects: [], tone: tone, width: 0).group == nil, "\(layer) is no box's")
        }
        #expect(BoxLayerGroup.allCases == [.edgeKeylines, .keylines, .veils, .edges, .inkLines, .lines, .tags,
                                           .wholePage, .handles, .moving])
    }

    // MARK: - The layers

    typealias Tone = ResectaTokens.Canvas.Tone

    /// A CSS colour as the table writes it: `#RRGGBB`, `rgb(R G B / A)`, or
    /// `color-mix(in srgb, #RRGGBB P%, transparent)`.
    static func tone(_ any: Any?) throws -> Tone {
        let css = try #require(any as? String)
        func hex(_ h: Substring) throws -> (CGFloat, CGFloat, CGFloat) {
            let v = try #require(Int(h.dropFirst().prefix(6), radix: 16), "\(css)")
            return (CGFloat((v >> 16) & 0xFF) / 255, CGFloat((v >> 8) & 0xFF) / 255, CGFloat(v & 0xFF) / 255)
        }
        if css.hasPrefix("#") {
            let (r, g, b) = try hex(Substring(css))
            return Tone(red: r, green: g, blue: b, alpha: 1)
        }
        if css.hasPrefix("rgb(") {
            let parts = css.dropFirst(4).dropLast().split(whereSeparator: { $0 == " " || $0 == "/" }).compactMap { Double($0) }
            #expect(parts.count == 4, "\(css)")
            guard parts.count == 4 else { return Tone(red: 0, green: 0, blue: 0, alpha: 0) }
            return Tone(red: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255, alpha: parts[3])
        }
        let words = css.split(separator: " ")
        let h = try #require(words.first { $0.hasPrefix("#") }, "\(css)")
        let share = try #require(words.first { $0.hasSuffix("%,") }.flatMap { Double($0.dropLast(2)) }, "\(css)")
        let (r, g, b) = try hex(h)
        return Tone(red: r, green: g, blue: b, alpha: share / 100)
    }

    /// A rational the table may leave out, or `fallback`.
    static func num(_ any: Any?, or fallback: CGFloat) throws -> CGFloat {
        guard let any else { return fallback }
        return try num(any)
    }

    /// A rational the table may leave out or give as null.
    static func optionalNum(_ any: Any?) throws -> CGFloat? {
        guard let any, !(any is NSNull) else { return nil }
        return try num(any)
    }

    /// A colour the table may leave out or give as null.
    static func optionalTone(_ any: Any?) throws -> Tone? {
        guard any is String else { return nil }
        return try tone(any)
    }

    static func close(_ a: CGFloat?, _ b: CGFloat?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return close(a, b)
    }

    static func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 1e-9 * max(1, abs(b)) }
    static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        close(a.minX, b.minX) && close(a.minY, b.minY) && close(a.width, b.width) && close(a.height, b.height)
    }
    static func close(_ a: Tone?, _ b: Tone?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return close(a.red, b.red) && close(a.green, b.green) && close(a.blue, b.blue) && close(a.alpha, b.alpha)
    }

    static let layerOfMark: [String: InkStep.Layer] = [
        "edgeKeyline": .edgeKeyline, "keyline": .keyline, "veil": .veil, "edge": .edge, "inkLine": .inkLine,
        "line": .line, "cueUnder": .cueUnder, "cue": .cue, "wholeHatchKey": .wholeHatchKey,
        "wholeKeyline": .wholeKeyline, "wholeVeil": .wholeVeil, "wholeHatch": .wholeHatch, "wholeFrame": .wholeFrame,
    ]

    /// A row's steps, one for each mark, as the app's steps: one rectangle
    /// each, except that a handle's shadow, disc and ring are one handle
    /// step (its disc at full size, with the handles' scale), a dot and its
    /// ring one dot step, and a tag one keyline step and one fill step.
    static func feed(_ steps: [[String: Any]], fingerScale f: CGFloat, handleScale k: CGFloat) throws -> [InkStep] {
        typealias C = ResectaTokens.Canvas
        var fed: [InkStep] = []
        for (n, s) in steps.enumerated() {
            let mark = try #require(s["mark"] as? String), key = try #require(s["key"] as? String)
            let lifted = s["group"] as? String == "moving"
            let rect = try Self.rect(s["rect"])
            let width = try num(s["width"], or: 0)
            switch mark {
            case "handleShadow", "handleRing", "dotRing":
                continue
            case "handle":
                let ring = try #require(steps.dropFirst(n + 1).first { $0["mark"] as? String == "handleRing" })
                let r = C.handle.radius * f
                let full = CGRect(x: rect.midX - r, y: rect.midY - r, width: 2 * r, height: 2 * r)
                fed.append(InkStep(layer: .handles, rects: [full], tone: try tone(ring["color"]), width: try num(ring["width"]),
                                   keys: [key], fingerScale: f, handleScale: k))
            case "dot":
                let ring = try #require(steps.dropFirst(n + 1).first { $0["mark"] as? String == "dotRing" })
                fed.append(InkStep(layer: .dots, rects: [rect], tone: try tone(s["color"]), width: try num(ring["width"]),
                                   keys: [key], fingerScale: f))
            case "tag":
                let draw = try #require(s["draw"] as? [String: Any])
                let keyline = try #require(draw["keyline"] as? [String: Any])
                let text = try #require(draw["text"] as? [String: Any])
                let tag = try Self.rect(draw["tag"]), outset = try num(keyline["outset"])
                let id = key.dropFirst("tag:".count)
                var words: [InkStep.WordsTransform] = []
                if let t = draw["wordsTransform"] as? [String: Any] {
                    words = [InkStep.WordsTransform(a: try num(t["a"]), b: try num(t["b"]), c: try num(t["c"]), d: try num(t["d"]))]
                }
                fed.append(InkStep(layer: .tagKeyline, rects: [tag.insetBy(dx: -outset, dy: -outset)],
                                   tone: try tone(keyline["color"]), width: try num(keyline["width"]),
                                   corner: try num(keyline["corner"]), keys: ["tagKeyline:\(id)"], fingerScale: f))
                fed.append(InkStep(layer: .tag, rects: [tag], tone: try tone(draw["fill"]), width: 0,
                                   corner: try num(draw["corner"]), words: [try #require(text["word"] as? String)],
                                   keys: [key], fingerScale: f, wordsTransforms: words))
            case "cueUnder", "cue":
                let path = try #require(s["path"] as? [String: Any])
                let dash = try #require(s["dash"] as? [Any]).map { try num($0) }
                fed.append(InkStep(layer: try #require(layerOfMark[mark]), rects: [try Self.rect(path["rect"])],
                                   tone: try tone(s["color"]), width: width, dash: dash, keys: [key], fingerScale: f))
            default:
                let layer = try #require(layerOfMark[mark], "no layer for \(mark)")
                var color = try tone(s["color"])
                if let opacity = try optionalNum(s["opacity"]) {
                    color = Tone(red: color.red, green: color.green, blue: color.blue, alpha: opacity)
                }
                var step = InkStep(layer: layer, rects: [rect], tone: color, width: width, lifted: lifted, keys: [key],
                                   fingerScale: f)
                step.onPaint = s["onPaint"] != nil
                step.outset = try num(s["outset"], or: 0)
                if let path = s["path"] as? [String: Any], path["type"] as? String == "hatch" {
                    step.hatch = InkStep.Hatch(angle: CGFloat(path["angle"] as? Int ?? 0),
                                               spacing: try num(path["spacing"]), phase: try num(path["phase"]))
                }
                fed.append(step)
            }
        }
        return fed
    }

    static func group(_ name: String?) -> BoxLayerGroup? {
        BoxLayerGroup.allCases.first { "\($0)" == name }
    }

    static func kind(_ name: String?) -> StepKind? {
        [StepKind.fill, .stroke, .disc, .ring, .shadow, .path, .drawn].first { "\($0)" == name }
    }

    /// Every field of a layer description against the table's; a field the
    /// table leaves out is the description's default.
    static func check(_ got: LayerSpec, _ want: [String: Any], _ at: String) throws {
        let frame = try rect(want["frame"])
        let corner = try num(want["cornerRadius"], or: 0), borderWidth = try num(want["borderWidth"], or: 0)
        let fill = try optionalTone(want["fill"]), borderColor = try optionalTone(want["borderColor"])
        // The table gives the dash phase as a whole number of points.
        let opacity = try optionalNum(want["opacity"])
        let phase = try (want["dashPhase"] as? Int).map { CGFloat($0) } ?? optionalNum(want["dashPhase"])
        let scale = try optionalNum(want["contentScale"])
        let dash = try (want["dash"] as? [Any])?.map { try num($0) }
        let dashSame = got.dash?.count == dash?.count
            && zip(got.dash ?? [], dash ?? []).allSatisfy { close($0, $1) }
        let shadowPath: ShadowPath? = want["shadowPath"] as? String == "ellipse" ? .ellipse : nil
        #expect(got.key == want["key"] as? String, "\(at): key")
        #expect(got.group == group(want["group"] as? String), "\(at): group")
        #expect(got.kind == kind(want["kind"] as? String), "\(at): kind")
        #expect(close(got.frame, frame), "\(at): frame \(got.frame), \(frame) in the table")
        #expect(close(got.cornerRadius, corner), "\(at): corner")
        #expect(close(got.fill, fill), "\(at): fill")
        #expect(close(got.borderWidth, borderWidth), "\(at): border width")
        #expect(close(got.borderColor, borderColor), "\(at): border colour")
        #expect(close(got.opacity, opacity), "\(at): opacity")
        #expect(dashSame, "\(at): dash")
        #expect(close(got.dashPhase, phase), "\(at): dash phase")
        #expect(got.shadowPath == shadowPath, "\(at): shadow path")
        #expect(close(got.contentScale, scale), "\(at): content scale")
        if let path = want["path"] as? [String: Any] {
            if path["type"] as? String == "hatch" {
                let spacing = try num(path["spacing"]), hatchPhase = try num(path["phase"])
                guard case .hatch(let given)? = got.path else { Issue.record("\(at): no hatch"); return }
                let same = given.angle == CGFloat(path["angle"] as? Int ?? -1) && close(given.spacing, spacing)
                    && close(given.phase, hatchPhase)
                #expect(same, "\(at): hatch")
            } else {
                let pathRect = try rect(path["rect"])
                guard case .rect(let given)? = got.path else { Issue.record("\(at): no rectangle path"); return }
                #expect(close(given, pathRect), "\(at): path's rectangle")
            }
        } else {
            #expect(got.path == nil, "\(at): no path")
        }
        if let shadow = want["shadow"] as? [String: Any] {
            let given = try #require(got.shadow, "\(at): no shadow")
            let offset = try #require(shadow["offset"] as? [String: Any])
            let color = try tone(shadow["color"]), blur = try num(shadow["blur"])
            let dx = try num(offset["x"]), dy = try num(offset["y"])
            #expect(close(given.color, color), "\(at): shadow colour")
            #expect(close(given.blur, blur), "\(at): shadow blur")
            #expect(close(given.offset.width, dx) && close(given.offset.height, dy), "\(at): shadow offset")
        } else {
            #expect(got.shadow == nil, "\(at): no shadow")
        }
        if let draw = want["draw"] as? [String: Any] {
            let given = try #require(got.draw, "\(at): no drawn mark")
            let keyline = try #require(draw["keyline"] as? [String: Any])
            let text = try #require(draw["text"] as? [String: Any])
            let tag = try rect(draw["tag"]), tagFill = try tone(draw["fill"]), tagCorner = try num(draw["corner"])
            let keyColor = try tone(keyline["color"]), keyWidth = try num(keyline["width"])
            let keyOutset = try num(keyline["outset"]), keyCorner = try num(keyline["corner"])
            let size = try num(text["size"]), textColor = try tone(text["color"])
            let x = try num(text["x"]), baseline = try num(text["baseline"])
            var turn = InkStep.WordsTransform.identity
            if let t = draw["wordsTransform"] as? [String: Any] {
                turn = InkStep.WordsTransform(a: try num(t["a"]), b: try num(t["b"]), c: try num(t["c"]), d: try num(t["d"]))
            }
            let word = text["word"] as? String, weight = text["weight"] as? Int
            #expect(close(given.tag, tag), "\(at): the tag")
            #expect(close(given.fill, tagFill) && close(given.corner, tagCorner), "\(at): its fill")
            #expect(close(given.keyline.color, keyColor) && close(given.keyline.width, keyWidth)
                    && close(given.keyline.outset, keyOutset) && close(given.keyline.corner, keyCorner), "\(at): its keyline")
            #expect(given.text.word == word && given.text.weight == weight, "\(at): its words")
            #expect(close(given.text.size, size) && close(given.text.color, textColor)
                    && close(given.text.x, x) && close(given.text.baseline, baseline), "\(at): its words' place")
            #expect(given.wordsTransform == turn, "\(at): its words' transform")
        } else {
            #expect(got.draw == nil, "\(at): no drawn mark")
        }
    }

    static func transform(_ any: Any?) throws -> CGAffineTransform {
        let t = try #require(any as? [String: Any])
        return CGAffineTransform(a: try num(t["a"]), b: try num(t["b"]), c: try num(t["c"]),
                                 d: try num(t["d"]), tx: try num(t["tx"]), ty: try num(t["ty"]))
    }

    @Test("Every row's steps become its layers, exactly: 26 rows")
    func layers() throws {
        var ran = 0
        for row in try Self.rows() {
            let id = try #require(row["id"] as? String)
            let inputs = try #require(row["inputs"] as? [String: Any])
            let expected = try #require(row["expected"] as? [String: Any])
            let steps = try #require(expected["steps"] as? [[String: Any]])
            let zoom = try Self.num(inputs["zoom"])
            let fed = try Self.feed(steps, fingerScale: 1 / zoom, handleScale: try Self.num(inputs["handleScale"]))
            let toDevice = try Self.transform(inputs["transform"])
            let clip = try Self.rect(inputs["clip"])
            let made = BoxLayers.specs(steps: fed, toDevice: toDevice, clip: clip)
            let want = try #require(expected["specs"] as? [[String: Any]])
            #expect(made.specs.count == want.count, "\(id): \(made.specs.count) layers, \(want.count) in the table")
            for (n, (got, spec)) in zip(made.specs, want).enumerated() {
                try Self.check(got, spec, "\(id) [\(n)]")
            }
            // The groups: the veils' carries their opacity; no other is named.
            let groups = try #require(expected["groups"] as? [String: Any])
            let veils = try #require(groups["veils"] as? [String: Any])
            let style = try #require(made.groups[.veils])
            let veilOpacity = try Self.num(veils["opacity"]), groupOpacity = veils["groupOpacity"] as? Bool
            #expect(Self.close(style.opacity, veilOpacity) && style.groupOpacity == groupOpacity, "\(id): the veils' group")
            #expect(made.groups.count == 1, "\(id): only the veils' group is named")
            // Every fill's device lines, through the screen link.
            let lines = try #require(expected["veilLines"] as? [String: [String: Int]])
            let fills = fed.filter { $0.layer == .veil || $0.layer == .wholeVeil }
            let fillKeys = fills.flatMap(\.keys).sorted(), lineKeys = lines.keys.sorted()
            #expect(fillKeys == lineKeys, "\(id): a line set for every fill")
            for step in fills {
                for (rect, key) in zip(step.rects, step.keys) {
                    let l = try #require(lines[key])
                    let x0 = try #require(l["x0"]), y0 = try #require(l["y0"])
                    let x1 = try #require(l["x1"]), y1 = try #require(l["y1"])
                    let given = ScreenLink.deviceLines(rect, toDevice: toDevice, clip: clip)
                    #expect(given == ScreenLink.DeviceLines(x0: x0, y0: y0, x1: x1, y1: y1), "\(id): \(key)'s device lines")
                }
            }
            // The groups stack in the boxes' order.
            let order = made.specs.map(\.group)
            #expect(order == order.sorted(), "\(id): the groups in order")
            ran += 1
        }
        #expect(ran == Self.rowCount)
    }

    @Test("The app's own steps give the table's layers for each box's own marks")
    func marksOnTheFill() throws {
        // The app's steps for the rows it makes give the table's layers for
        // the box's own marks, by key.
        for id in Self.madeByTheApp {
            let row = try Self.row(id)
            let inputs = try #require(row["inputs"] as? [String: Any])
            let expected = try #require(row["expected"] as? [String: Any])
            let made = try Self.boxes(inputs)
            let app = BoxLayers.specs(steps: try Self.appSteps(inputs, boxes: made.boxes, ids: made.ids),
                                      toDevice: try Self.transform(inputs["transform"]),
                                      clip: try Self.rect(inputs["clip"])).specs
            let want = try #require(expected["specs"] as? [[String: Any]])
            for spec in want {
                let key = try #require(spec["key"] as? String)
                guard ["edgeKeyline:", "keyline:", "veil:", "edge:", "inkLine:", "line:"].contains(where: key.hasPrefix)
                else { continue }
                let given = try #require(app.first { Self.named($0.key, made.names) == key }, "\(id): no \(key)")
                try Self.check(LayerSpec(key: key, group: given.group, kind: given.kind, frame: given.frame,
                                         cornerRadius: given.cornerRadius, fill: given.fill, borderWidth: given.borderWidth,
                                         borderColor: given.borderColor, opacity: given.opacity, shadow: given.shadow),
                               spec, "\(id) (the app's steps)")
            }
        }
    }
}
