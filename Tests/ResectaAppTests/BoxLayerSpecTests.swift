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

    @Test("Every step keys each of its rectangles, by the table's scheme, the same in every pass")
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
}
