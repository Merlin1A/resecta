import Testing
import UIKit
@testable import ResectaApp

// The canvas's resize handles and corner dots: the tokens they are drawn
// with, where the one function for handle centres puts them, where the
// corner dots go, and the hit test reading the same function the drawing
// reads. Sizes are on-screen points; a rectangle here is drawn at
// `fingerScale` overlay points per on-screen point.

@Suite("Canvas ink: handles and corner dots")
@MainActor
struct CanvasInkLookTests {
    typealias C = ResectaTokens.Canvas
    typealias Handle = RedactionOverlayView.ResizeHandle

    /// 1 (the page at 100 %), fit (0.64) and 2× zoom.
    nonisolated static let scales: [CGFloat] = [1, 1 / 0.64, 0.5]

    private static func components(_ color: UIColor, _ style: UIUserInterfaceStyle = .light) -> [CGFloat] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b, a]
    }

    private static func near(_ x: [CGFloat], _ y: [CGFloat]) -> Bool {
        x.count == y.count && zip(x, y).allSatisfy { abs($0 - $1) <= 1.0 / 255 }
    }

    private static func centres(_ size: CGSize, _ s: CGFloat) -> [Handle: CGPoint] {
        let rect = CGRect(x: 0, y: 0, width: size.width * s, height: size.height * s)
        return Dictionary(uniqueKeysWithValues: RedactionOverlayView.handleCentres(for: rect, fingerScale: s))
    }

    @Test("The canvas tokens hold the ruled values")
    func tokensHoldTheRuledValues() {
        let teal: [CGFloat] = [0x0B / 255, 0x64 / 255, 0x6F / 255, 1]
        #expect(Self.near(Self.components(C.pageTeal.uiColor), teal))
        #expect(Self.near(Self.components(C.pageTeal.uiColor, .dark), teal), "page teal is the same in dark appearance")

        #expect(C.handle.radius == 4.5)
        #expect(Self.near(Self.components(C.handle.fill.uiColor), [1, 1, 1, 1]), "a handle is a white disc")
        #expect(C.handle.ring == C.pageTeal, "with a page-teal ring")
        #expect(C.handle.ringWidth == 1.75)
        #expect(Self.near(Self.components(C.handleShadow.uiColor), [0, 0, 0, 0.12]))
        #expect(C.handleShadowGrowth == 1.2 && C.handleShadowDrop == 0.6)

        #expect(C.selectionDot.radius == 2.75)
        #expect(C.selectionDot.fill == C.pageTeal)
        #expect(Self.near(Self.components(C.selectionDot.ring.uiColor), [1, 1, 1, 0.9]))
        #expect(C.selectionDot.ringWidth == 0.8)

        #expect(C.handlesStepOutBelow == 22 && C.handleLargestStep == 6.5 && C.edgeHandleShortestSide == 60)
        #expect(C.dotsStepOutBelow == 12 && C.dotLargestStep == 4)

        let ink: [CGFloat] = [0x14 / 255, 0x22 / 255, 0x2B / 255]
        #expect(Self.near(Self.components(C.ink.uiColor), ink + [1]))
        #expect(Self.near(Self.components(C.veil.uiColor), ink + [0.18]))
        #expect(Self.near(Self.components(C.veilReducedTransparency.uiColor), ink + [0.26]))
        #expect(Self.near(Self.components(C.edge.tone.uiColor), ink + [0.5]) && C.edge.width == 0.5)
        #expect(Self.near(Self.components(C.edgeIncreasedContrast.tone.uiColor), ink + [0.8]) && C.edgeIncreasedContrast.width == 0.5)
        #expect(C.line.tone == C.pageTeal && C.line.width == 1.4, "the resting line: page teal, 1.4")
        #expect(C.lineSelected.tone == C.pageTeal && C.lineSelected.width == 2.4, "the selected line: page teal, 2.4")
        #expect(C.line.width != C.lineSelected.width, "rest and selected differ by weight, not colour")
        #expect(Self.near(Self.components(C.keyline.tone.uiColor), [1, 1, 1, 0.9]) && C.keyline.width == 0.8 && C.keylineGap == 0.4)
        #expect(Self.near(Self.components(C.inkLine.tone.uiColor), ink + [1]) && C.inkLine.width == 1)
        #expect(C.inkLineAlways == false)
        #expect(Self.near(Self.components(C.edgeKeyline.tone.uiColor), [1, 1, 1, 0.55]) && C.edgeKeyline.width == 0.5
                && C.edgeKeylineOutset == 0.5)
    }

    @Test("Handle centres: four corners, an edge handle only on a side of 60 on-screen points, corners stepped clear of a thin box",
          arguments: scales)
    func handleCentresFollowTheRule(_ s: CGFloat) throws {
        // On a short axis the handles at its two ends step out by half the
        // shortfall under 22, at most 6.5.
        for (height, out) in [(9, 6.5), (20, 1), (22, 0), (100, 0)] as [(CGFloat, CGFloat)] {
            let c = Self.centres(CGSize(width: 120, height: height), s)
            let label = "120 x \(height) at \(s)"
            let topLeft = try #require(c[.topLeft], "\(label): a corner"), bottomRight = try #require(c[.bottomRight])
            #expect(abs(topLeft.y + out * s) < 1e-9, "\(label): the top corners \(out) above")
            #expect(abs(bottomRight.y - (height + out) * s) < 1e-9, "\(label): the bottom corners \(out) below")
            #expect(topLeft.x == 0 && bottomRight.x == 120 * s, "\(label): a long axis does not step")
            let top = try #require(c[.topCenter], "\(label): the long top side has its middle handle")
            #expect(abs(top.y + out * s) < 1e-9, "\(label): the middle handle steps with its axis")
        }
        // A middle handle only on a side of at least 60.
        #expect(Self.centres(CGSize(width: 59.9, height: 200), s)[.topCenter] == nil, "59.9: no edge handle")
        #expect(Self.centres(CGSize(width: 59.9, height: 200), s)[.leftCenter] != nil)
        #expect(Self.centres(CGSize(width: 60, height: 200), s)[.topCenter] != nil, "60: one")
        #expect(Self.centres(CGSize(width: 105, height: 200), s)[.bottomCenter] != nil, "105: one")
        #expect(Self.centres(CGSize(width: 200, height: 59.9), s)[.rightCenter] == nil)
        #expect(Self.centres(CGSize(width: 59.9, height: 59.9), s).count == 4, "a small box: the corners alone")
        #expect(Self.centres(CGSize(width: 60, height: 60), s).count == 8)
    }

    @Test("Corner dots step out under 12 points, at most 4", arguments: scales)
    func cornerDotsStepOut(_ s: CGFloat) {
        for (height, out) in [(8, 2), (11.9, 0.05), (12, 0), (30, 0), (2, 4)] as [(CGFloat, CGFloat)] {
            let dots = RedactionOverlayView.selectionDotCentres(
                for: CGRect(x: 0, y: 0, width: 120 * s, height: height * s), fingerScale: s)
            #expect(dots.count == 4, "four dots")
            #expect(dots.allSatisfy { $0.x == 0 || $0.x == 120 * s }, "\(height) at \(s): a long axis does not step")
            #expect(dots.filter { abs($0.y + out * s) < 1e-9 }.count == 2, "\(height) at \(s): two dots \(out) above")
            #expect(dots.filter { abs($0.y - (height + out) * s) < 1e-9 }.count == 2, "\(height) at \(s): two dots \(out) below")
        }
    }

    @Test("The hit test reads the drawing's handle centres", arguments: scales)
    func hitTestReadsTheDrawnCentres(_ s: CGFloat) {
        let sizes = [CGSize(width: 9, height: 120), CGSize(width: 40, height: 40), CGSize(width: 59.9, height: 200),
                     CGSize(width: 60, height: 60), CGSize(width: 200, height: 200)]
        let edges: Set<Handle> = [.topCenter, .bottomCenter, .leftCenter, .rightCenter]
        for size in sizes {
            let rect = CGRect(x: 100, y: 100, width: size.width * s, height: size.height * s)
            func resolve(_ p: CGPoint) -> Handle? {
                RedactionOverlayView.resolveResizeHandle(
                    at: p, regionRect: rect, targetHandleSize: ResectaTokens.TouchTarget.minimum * s,
                    minimumHandleSize: 22 * s, fingerScale: s)
            }
            for (handle, centre) in RedactionOverlayView.handleCentres(for: rect, fingerScale: s) {
                #expect(resolve(centre) == handle, "\(size) at \(s): the drawn \(handle) is that handle")
            }
            var shortMiddles: [CGPoint] = []
            if size.width < 60 { shortMiddles += [CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.midX, y: rect.maxY)] }
            if size.height < 60 { shortMiddles += [CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY)] }
            for p in shortMiddles {
                #expect(resolve(p).map { !edges.contains($0) } ?? true, "\(size) at \(s): a short side's middle \(p) is no edge handle")
            }
        }
    }
    // MARK: - The steps for the boxes

    private static func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                            paint: CGRect? = nil, selected: Bool = false, id: UUID = UUID()) -> InkBox {
        let tight = CGRect(x: x, y: y, width: w, height: h)
        return InkBox(id: id, tight: tight, paint: paint ?? tight, isSelected: selected)
    }

    private static func steps(_ boxes: [InkBox], selectionCount: Int? = nil, handlesActive: Bool = true,
                              moving: Set<UUID> = [], _ settings: CanvasDisplaySettings = .init()) -> [InkStep] {
        RedactionOverlayView.inkSteps(boxes: boxes, selectionCount: selectionCount ?? boxes.filter(\.isSelected).count,
                                      handlesActive: handlesActive, moving: moving, settings: settings)
    }

    private static func layers(_ steps: [InkStep]) -> [InkStep.Layer] { steps.map(\.layer) }

    private static func out(_ r: CGRect, _ by: CGFloat) -> CGRect { r.insetBy(dx: -by, dy: -by) }

    @Test("The steps for one box")
    func stepsForOneBox() throws {
        // (a) At rest, painting more than its own rectangle.
        let paint = CGRect(x: 90, y: 95, width: 140, height: 30)
        let rest = Self.box(100, 100, 120, 20, paint: paint)
        let a = Self.steps([rest])
        #expect(Self.layers(a) == [.edgeKeyline, .keyline, .veil, .edge, .line], "R1's order")
        #expect(a[0].rects == [Self.out(paint, 0.5)] && a[0].tone == C.edgeKeyline.tone && a[0].width == 0.5)
        #expect(a[1].rects == [Self.out(rest.tight, 1.1)] && a[1].tone == C.keyline.tone && a[1].width == 0.8,
                "the keyline outside the line by half its width plus 0.4")
        #expect(a[2].rects == [paint] && a[2].tone == C.veil && a[2].width == 0, "the veil over the painted area")
        #expect(a[3].rects == [paint] && a[3].tone == C.edge.tone && a[3].width == 0.5, "the faint edge on it")
        #expect(a[4].rects == [rest.tight] && a[4].tone == C.pageTeal && a[4].width == 1.4, "the teal line on its own rectangle")
        #expect(!a.contains { $0.width == 0 && $0.tone.red == 1 && $0.tone.green == 1 && $0.tone.blue == 1 }, "no white fill: the wash is out")

        // (b) Selected, the one selection: handles.
        let sel = Self.box(100, 100, 120, 20, paint: paint, selected: true)
        let b = Self.steps([sel])
        #expect(Self.layers(b) == [.edgeKeyline, .keyline, .veil, .edge, .line, .handles])
        #expect(b[1].rects == [Self.out(sel.tight, 1.6)], "the selected line's keyline: 1.2 + 0.4 out")
        #expect(b[4].tone == C.pageTeal && b[4].width == 2.4)
        #expect(b[5].rects.count == RedactionOverlayView.handleCentres(for: sel.tight).count)

        // (c) Selected without handles: Add to Selection on, then two selected.
        #expect(Self.layers(Self.steps([sel], handlesActive: false)).last == .dots)
        let two = Self.steps([sel, Self.box(300, 100, 50, 50, selected: true)])
        #expect(Self.layers(two).last == .dots && !Self.layers(two).contains(.handles))
        #expect(two.last?.rects.count == 8, "four dots per box")

        // (d) Reduce Transparency: the veil at 26 %.
        let d = Self.steps([rest], CanvasDisplaySettings(reduceTransparency: true))
        #expect(d.first { $0.layer == .veil }?.tone == C.veilReducedTransparency)

        // (e) Increase Contrast: the faint edge at 80 %, an ink line, the keyline one point further out.
        let e = Self.steps([sel], CanvasDisplaySettings(increaseContrast: true))
        #expect(Self.layers(e) == [.edgeKeyline, .keyline, .veil, .edge, .inkLine, .line, .handles, .inkRings])
        #expect(e[3].tone == C.edgeIncreasedContrast.tone)
        #expect(e[1].rects == [Self.out(sel.tight, 2.6)])
        #expect(e[4].rects == [Self.out(sel.tight, 1.7)] && e[4].width == 1 && e[4].tone == C.ink)
        #expect(e[5].width == 2.4, "the line widths do not change")

        // (f) Two regions sharing one painted area.
        let shared = CGRect(x: 50, y: 50, width: 300, height: 20)
        let left = Self.box(50, 50, 100, 20, paint: shared), right = Self.box(200, 50, 150, 20, paint: shared, selected: true)
        let f = Self.steps([left, right], selectionCount: 1)
        for layer: InkStep.Layer in [.edgeKeyline, .veil, .edge] {
            #expect(f.filter { $0.layer == layer }.flatMap(\.rects).count == 1, "one \(layer) for the shared area")
        }
        #expect(f.filter { $0.layer == .line }.map(\.rects) == [[left.tight], [right.tight]], "each keeps its own line")
        #expect(f.filter { $0.layer == .line }.map(\.width) == [1.4, 2.4], "only the selected one's line is heavy")

        // (g) Two boxes whose painted areas overlap: the veil is one fill.
        let g = Self.steps([Self.box(0, 0, 100, 40), Self.box(60, 20, 100, 40)])
        #expect(g.filter { $0.layer == .veil }.count == 1 && g.first { $0.layer == .veil }?.rects.count == 2)

        // (h) A box being moved: drawn last, whole, with neither handles nor dots.
        let other = Self.box(400, 400, 60, 60)
        let h = Self.steps([sel, other], selectionCount: 1, moving: [sel.id])
        #expect(h.filter(\.lifted).map(\.layer) == [.edgeKeyline, .keyline, .veil, .edge, .line])
        #expect(h.filter { !$0.lifted }.allSatisfy { $0.rects.allSatisfy { !$0.intersects(sel.tight) } })
        #expect(!h.contains { [.handles, .dots].contains($0.layer) })
        #expect(h.lastIndex { !$0.lifted }! < h.firstIndex { $0.lifted }!, "on top")

        // (i) Differentiate Without Color with a selection without handles.
        let i = Self.steps([sel], handlesActive: false, CanvasDisplaySettings(differentiateWithoutColor: true))
        let under = try #require(i.first { $0.layer == .cueUnder }), cue = try #require(i.first { $0.layer == .cue })
        #expect(!cue.dash.isEmpty && under.dash == cue.dash && under.rects == cue.rects)
        #expect(under.tone == C.keyline.tone && abs(under.width - (cue.width + 1.6)) < 0.001, "a white under-stroke, 1.6 wider")
        #expect(!Self.steps([sel], CanvasDisplaySettings(differentiateWithoutColor: true)).contains { $0.layer == .cue },
                "none on a box with handles")

        // Every state: a box at rest has no handle or dot; a selected box has one of the two.
        for settings in [CanvasDisplaySettings(), .init(reduceTransparency: true), .init(increaseContrast: true),
                         .init(differentiateWithoutColor: true)] {
            #expect(!Self.layers(Self.steps([rest], settings)).contains { [.handles, .dots].contains($0) })
            for active in [true, false] {
                let marks = Self.layers(Self.steps([sel], handlesActive: active, settings)).filter { [.handles, .dots].contains($0) }
                #expect(marks.count == 1)
            }
        }
    }

    @Test("The ink line is one point wide, and shows only with Increase Contrast")
    func inkLineOnlyWithIncreaseContrast() {
        #expect(C.inkLine.width == 1)
        #expect((C.inkLine.width * 2).rounded() == C.inkLine.width * 2 && (C.inkLine.width * 3).rounded() == C.inkLine.width * 3)
        #expect(C.inkLine.width >= 0.6)
        #expect(C.showsInkLine(increaseContrast: false) == C.inkLineAlways && C.inkLineAlways == false)
        #expect(C.showsInkLine(increaseContrast: true))
        let boxes = [Self.box(0, 0, 120, 20, selected: true), Self.box(200, 0, 80, 40), Self.box(400, 0, 30, 30, selected: true)]
        let on = Self.steps(boxes, CanvasDisplaySettings(increaseContrast: true))
        #expect(on.filter { $0.layer == .inkLine }.flatMap(\.rects).count == boxes.count, "one ink line for every box")
        let marks = on.filter { [.handles, .dots].contains($0.layer) }.flatMap(\.rects).count
        #expect(on.first { $0.layer == .inkRings }?.rects.count == marks, "one ink ring for every handle and dot")
        let off = Self.steps(boxes)
        #expect(!off.contains { [.inkLine, .inkRings].contains($0.layer) }, "none at the default settings")
        let keyOn = on.first { $0.layer == .keyline }!.rects[0], keyOff = off.first { $0.layer == .keyline }!.rects[0]
        #expect(abs((keyOff.minX - keyOn.minX) - 1) < 0.001, "the keyline one point further out")
    }

    @Test("A change of a display setting redraws the page's boxes")
    func displaySettingChangeRedraws() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let overlay = root.appendingPathComponent("Sources/ResectaApp/Overlay")
        let draw = try String(contentsOf: overlay.appendingPathComponent("RedactionOverlayView+Draw.swift"), encoding: .utf8)
        for name in ["differentiateWithoutColorDidChangeNotification", "reduceTransparencyStatusDidChangeNotification",
                     "darkerSystemColorsStatusDidChangeNotification"] {
            #expect(draw.contains("UIAccessibility.\(name)"), "an observer for \(name)")
        }
        let files = try FileManager.default.contentsOfDirectory(at: overlay, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        let sources = try files.map { try String(contentsOf: $0, encoding: .utf8) }
        let ink = try String(contentsOf: overlay.appendingPathComponent("RedactionOverlayView+Ink.swift"), encoding: .utf8)
        let reader = try #require(ink.range(of: "struct CanvasDisplaySettings")).lowerBound
        let readerEnd = try #require(ink.range(of: "\n}\n", range: reader..<ink.endIndex)).upperBound
        for name in ["isReduceTransparencyEnabled", "isDarkerSystemColorsEnabled", "shouldDifferentiateWithoutColor"] {
            let count = sources.map { $0.components(separatedBy: name).count - 1 }.reduce(0, +)
            #expect(count == 1, "\(name) is read once under Overlay/, not \(count) times")
            #expect(ink[reader..<readerEnd].contains(name), "\(name) is read inside CanvasDisplaySettings")
        }
    }
}
