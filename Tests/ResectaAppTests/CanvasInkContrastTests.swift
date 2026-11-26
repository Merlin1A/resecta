import Testing
import CoreGraphics
@testable import ResectaApp

// The Ink box's contrast, from the token values. A colour `a` over `d` is
// a·S + (1 − a)·D per channel on 0 to 255; luminance per WCAG 2; ratio
// (L₁ + 0.05) / (L₂ + 0.05). The teal line is opaque, so it is measured
// against the ground as it is; the keylines sit on the ground; the faint
// ink edge sits on the veil; "better" is the larger of a mark and its
// keyline against the ground. These are limits, not passes of 3 : 1: where
// the better figure is under 3 the case says so.

@Suite("Canvas ink: contrast")
@MainActor
struct CanvasInkContrastTests {
    typealias C = ResectaTokens.Canvas
    typealias RGB = (Double, Double, Double)

    // MARK: - The model

    nonisolated static func luminance(_ p: RGB) -> Double {
        func l(_ c: Double) -> Double {
            let x = c / 255
            return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * l(p.0) + 0.7152 * l(p.1) + 0.0722 * l(p.2)
    }

    nonisolated static func ratio(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    nonisolated static func over(_ s: RGB, _ a: Double, _ d: RGB) -> RGB {
        (a * s.0 + (1 - a) * d.0, a * s.1 + (1 - a) * d.1, a * s.2 + (1 - a) * d.2)
    }

    static func rgb(_ t: C.Tone) -> RGB { (Double(t.red) * 255, Double(t.green) * 255, Double(t.blue) * 255) }

    static var teal: RGB { rgb(C.pageTeal) }
    static var ink: RGB { rgb(C.ink) }
    static let white: RGB = (255, 255, 255)

    /// The figures for one ground: the teal line, its keyline, the better
    /// of the two, the line against its own keyline, and the painted edge's
    /// better (the faint edge over the veil, or the edge keyline).
    static func figures(_ g: RGB, veil: Double = Double(C.veil.alpha), edge: Double = Double(C.edge.tone.alpha))
        -> (line: Double, keyline: Double, better: Double, lineKeyline: Double, edge: Double) {
        let key = over(white, Double(C.keyline.tone.alpha), g)
        let line = ratio(teal, g), keyline = ratio(key, g)
        let veiled = over(ink, veil, g)
        let faint = ratio(over(ink, edge, veiled), g)
        let edgeKey = ratio(over(white, Double(C.edgeKeyline.tone.alpha), g), g)
        return (line, keyline, max(line, keyline), ratio(teal, key), max(faint, edgeKey))
    }

    /// The grid: R, G and B each 0, 5, …, 255.
    static var grid: [RGB] {
        let steps = stride(from: 0.0, through: 255, by: 5).map { $0 }
        return steps.flatMap { r in steps.flatMap { g in steps.map { b in (r, g, b) } } }
    }

    // MARK: - The tests

    @Test("The contrast table")
    func contrastTable() {
        let table: [(String, RGB, [Double])] = [
            ("white", (255, 255, 255), [6.85, 1.00, 6.85, 6.85, 4.21]),
            ("the sample's shaded row", (0xF2, 0xF4, 0xF4), [6.20, 1.09, 6.20, 6.78, 4.08]),
            ("grey field", (0xD9, 0xD9, 0xD9), [4.85, 1.37, 4.85, 6.63, 3.73]),
            ("blue field", (0xDC, 0xE6, 0xF1), [5.42, 1.23, 5.42, 6.70, 3.89]),
            ("mid grey", (0x80, 0x80, 0x80), [1.73, 3.54, 3.54, 6.13, 2.34]),
            ("chat blue", (0x0A, 0x84, 0xFF), [1.88, 3.23, 3.23, 6.07, 2.47]),
            ("dark table header", (0x40, 0x40, 0x40), [1.51, 8.77, 8.77, 5.79, 4.41]),
            ("navy bar", (0x1F, 0x4E, 0x79), [1.27, 7.37, 7.37, 5.83, 3.85]),
            ("dark bubble", (0x26, 0x26, 0x28), [2.21, 12.48, 12.48, 5.66, 5.60]),
            ("dark page", (0x1C, 0x1C, 0x1E), [2.48, 13.93, 13.93, 5.61, 5.97]),
            ("black", (0, 0, 0), [3.07, 16.75, 16.75, 5.46, 6.27]),
        ]
        for (name, ground, want) in table {
            let f = Self.figures(ground)
            let got = [f.line, f.keyline, f.better, f.lineKeyline, f.edge]
            for (g, w) in zip(got, want) {
                #expect(abs(g - w) <= 0.01, "\(name): \(got.map { ($0 * 100).rounded() / 100 }) against \(want)")
            }
        }
    }

    /// The minima over the grid, named limits.
    static let lineBetterFloor = 2.47, lineKeylineFloor = 5.46, edgeFloor = 2.27, handleFloor = 2.61
    static let inkLineFloor = 3.69, inkHandleFloor = 4.02
    static let edgeFloorReducedTransparency = 2.33, edgeFloorIncreasedContrast = 2.53
    static let groundsUnderThreeForTheLine = 24_983, groundsUnderThreeForAHandle = 17_453

    @Test("The limits over every ground of the step-5 grid")
    func limitsOverTheGrid() {
        let key = Double(C.keyline.tone.alpha), dotRing = Double(C.selectionDot.ring.alpha)
        var minimum = (line: 99.0, lineKeyline: 99.0, edge: 99.0, handle: 99.0, ink: 99.0, inkDot: 99.0, inkHandle: 99.0,
                       edgeRT: 99.0, edgeIC: 99.0)
        var lineUnderThree = 0, handleUnderThree = 0, inkUnderThree = 0
        for g in Self.grid {
            let f = Self.figures(g)
            let line = f.line, inkFigure = Self.ratio(Self.ink, g), disc = Self.ratio(Self.white, g)
            minimum.line = min(minimum.line, f.better)
            minimum.lineKeyline = min(minimum.lineKeyline, f.lineKeyline)
            minimum.edge = min(minimum.edge, f.edge)
            let handle = max(line, disc)
            minimum.handle = min(minimum.handle, handle)
            let withInk = max(line, inkFigure, Self.ratio(Self.over(Self.white, key, g), g))
            let dotWithInk = max(line, Self.ratio(Self.over(Self.white, dotRing, g), g), inkFigure)
            let handleWithInk = max(line, disc, inkFigure)
            minimum.ink = min(minimum.ink, withInk)
            minimum.inkDot = min(minimum.inkDot, dotWithInk)
            minimum.inkHandle = min(minimum.inkHandle, handleWithInk)
            minimum.edgeRT = min(minimum.edgeRT, Self.figures(g, veil: Double(C.veilReducedTransparency.alpha)).edge)
            minimum.edgeIC = min(minimum.edgeIC, Self.figures(g, edge: Double(C.edgeIncreasedContrast.tone.alpha)).edge)
            if f.better < 3 { lineUnderThree += 1 }
            if handle < 3 { handleUnderThree += 1 }
            if min(withInk, dotWithInk, handleWithInk) < 3 { inkUnderThree += 1 }
        }
        #expect(minimum.line >= Self.lineBetterFloor, "the line's better: \(minimum.line)")
        #expect(minimum.lineKeyline >= Self.lineKeylineFloor, "the line against its keyline: \(minimum.lineKeyline)")
        #expect(minimum.edge >= Self.edgeFloor, "the painted edge's better: \(minimum.edge)")
        #expect(minimum.handle >= Self.handleFloor, "a handle's better: \(minimum.handle)")
        #expect(handleUnderThree == Self.groundsUnderThreeForAHandle, "a handle under 3 : 1 on \(handleUnderThree) grounds")
        #expect(minimum.ink >= Self.inkLineFloor && minimum.inkDot >= Self.inkLineFloor, "with the ink line: \(minimum.ink), dots \(minimum.inkDot)")
        #expect(minimum.inkHandle >= Self.inkHandleFloor, "a handle with its ink ring: \(minimum.inkHandle)")
        #expect(inkUnderThree == 0, "with the ink line no ground is under 3 : 1")
        #expect(abs(minimum.edgeRT - Self.edgeFloorReducedTransparency) < 0.01 && minimum.edgeRT >= Self.edgeFloorReducedTransparency,
                "the painted edge with Reduce Transparency: \(minimum.edgeRT)")
        #expect(abs(minimum.edgeIC - Self.edgeFloorIncreasedContrast) < 0.01 && minimum.edgeIC >= Self.edgeFloorIncreasedContrast,
                "the painted edge with Increase Contrast: \(minimum.edgeIC)")
        #expect(lineUnderThree == Self.groundsUnderThreeForTheLine, "the line under 3 : 1 on \(lineUnderThree) grounds")

        // On greys the line's better figure is under 3 : 1 from #8E to #AB, worst 2.52 at #9C.
        let greys = (0...255).map { v in (v, Self.figures((Double(v), Double(v), Double(v))).better) }
        let under = greys.filter { $0.1 < 3 }.map(\.0)
        #expect(under.first == 0x8E && under.last == 0xAB && under.count == 0xAB - 0x8E + 1)
        let worst = greys.min { $0.1 < $1.1 }!
        #expect(worst.0 == 0x9C && abs(worst.1 - 2.52) < 0.005)
    }

    @Test("Words under the veil")
    func wordsUnderTheVeil() {
        let grey: RGB = (0x5B, 0x5B, 0x5B), dark: RGB = (0x1A, 0x1A, 0x1A), shaded: RGB = (0xF2, 0xF4, 0xF4)
        func under(_ text: RGB, _ ground: RGB, _ veil: Double) -> Double {
            Self.ratio(Self.over(Self.ink, veil, text), Self.over(Self.ink, veil, ground))
        }
        let v = Double(C.veil.alpha), rt = Double(C.veilReducedTransparency.alpha)
        let cases: [(Double, Double)] = [
            (under(grey, Self.white, v), 5.56), (under(grey, shaded, v), 5.07),
            (under(dark, Self.white, v), 11.94), (under(dark, shaded, v), 10.88),
            (under(grey, Self.white, rt), 5.00), (under(grey, shaded, rt), 4.58),
        ]
        for (got, want) in cases { #expect(abs(got - want) <= 0.01, "\(got) against \(want)") }
        for g in [under(grey, Self.white, v), under(grey, shaded, v), under(grey, Self.white, rt), under(grey, shaded, rt)] {
            #expect(g >= 4.5, "grey text under the veil holds 4.5 : 1")
        }
    }
}
