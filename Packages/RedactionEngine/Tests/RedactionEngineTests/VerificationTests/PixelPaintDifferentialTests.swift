import Foundation
import Testing
@testable import RedactionEngine

// The pixel step's projection (PixelPlan.project and PixelPlan.Raster) and the
// box check's own copy of the rule are written apart from the same signed rule.
// Here they are given the same boxes, pages and qualities, and must agree on
// every pixel line, and on the size of every page's picture. Neither copy calls
// the other and no constant is shared: the expected numbers below are the
// rule's, written out. This shows the check agrees with the projection. It does
// not show the painter's pixels are the projection's: at this head the fills are
// painted by applyRedactionFills, which does not read it, and InkCheck is the
// projection's one caller. The pixel step's second half makes the fills paint
// through the projection; the test is run again there.

@Suite("The painting code and the box check's copy paint every box alike")
struct PixelPaintDifferentialTests {
    static let qualities = [300, 200, 150]
    /// 625 of each of the 18 kinds on each page: 2,500 of each kind in all.
    static let boxesPerPage = 11_250
    /// The seed of the boxes; a constant, so every run draws the same boxes.
    static let seed: UInt64 = 0x5EED_B0C5_2026_1119
    /// Comparisons of a wholly-off box that paint nothing in both copies, for this seed.
    static let nothingWhollyOff = 4_658

    /// Letter upright and turned, A4 upright and turned, in sixty-fourths.
    static let pages: [(name: String, width: Int, height: Int)] = [
        ("Letter", 39_168, 50_688), ("Letter turned", 50_688, 39_168),
        ("A4", 38_098, 53_881), ("A4 turned", 53_881, 38_098),
    ]

    /// SplitMix64: a small fixed generator, so the boxes never depend on the platform's.
    struct Draw {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ range: ClosedRange<Int>) -> Int {
            range.lowerBound + Int(next() % UInt64(range.upperBound - range.lowerBound + 1))
        }
    }

    enum Kind: String, CaseIterable {
        case bothLimits = "both limits"
        case limitAbove = "a limit above only"
        case limitBelow = "a limit below only"
        case noLimit = "no limit"
        case handDrawn = "paint equal to inner"
        case limitFar = "a limit far from the margin"
        case limitNearMargin = "a limit within 2 pixels of the margin's end"
        case limitInsideBlock = "a limit between inner and the block edge"
        case widenedBand = "a widened band"
        case pastLeft = "past the left edge"
        case pastRight = "past the right edge"
        case pastTop = "past the top edge"
        case pastBottom = "past the bottom edge"
        case oneSixtyFourthPast = "one sixty-fourth past the page"
        case whollyOff = "wholly off the page"
        case edgeOnGridLine = "inner's edges on 8-pixel lines"
        case noArea = "an inner with no area"
        case subPixel = "an inner smaller than a pixel"
    }

    struct Box {
        let kind: Kind
        let inner: PageRect64
        let paint: PageRect64
        let above: Int?
        let below: Int?
        /// For an `edgeOnGridLine` box, the quality whose 8-pixel lines its four edges lie on.
        let gridDpi: Int?
    }

    /// A sixty-fourth coordinate that lies exactly on pixel line `line` at quality `d`.
    static func onLine(_ line: Int, dpi d: Int) -> Int? {
        let x = line * 4608
        return x % d == 0 ? x / d : nil
    }

    static func box(_ kind: Kind, page: (name: String, width: Int, height: Int), draw: inout Draw) -> Box {
        let w = page.width, h = page.height
        let lineHeight = draw.int(400...1200)
        var gridDpi: Int? = nil
        var x0 = draw.int(0...(w - 4000)), y0 = draw.int(lineHeight...(h - 2 * lineHeight))
        var x1 = x0 + draw.int(64...3800), y1 = y0 + lineHeight
        switch kind {
        case .widenedBand: x0 = draw.int(0...900); x1 = w - draw.int(0...900)
        case .pastLeft: x0 = -draw.int(1...2000)
        case .pastRight: x1 = w + draw.int(1...2000)
        case .pastTop: y1 = h + draw.int(1...399); y0 = y1 - lineHeight
        case .pastBottom: y0 = -draw.int(1...600)
        case .oneSixtyFourthPast:
            switch draw.int(0...1) {
            case 0: x1 = w + 1
            default: y1 = h + 1; y0 = y1 - lineHeight
            }
        case .whollyOff:
            switch draw.int(0...3) {
            case 0: x1 = -draw.int(1...500); x0 = x1 - draw.int(64...2000)
            case 1: x0 = w + draw.int(1...500); x1 = x0 + draw.int(64...2000)
            case 2: y1 = -draw.int(1...500); y0 = y1 - lineHeight
            default: y0 = h + draw.int(1...500); y1 = y0 + lineHeight
            }
        case .edgeOnGridLine:
            // All four edges on 8-pixel lines of one of the three qualities, each on a whole
            // sixty-fourth. A pixel line lies on a whole sixty-fourth at 150, 200 and 300 dpi when it
            // is a multiple of 25, so columns are multiples of 200 from the left edge. Rows count
            // from the picture's top: a row line r is a multiple of 8 and the frame's height less r
            // a multiple of 25, which holds for r = r0 + 200k.
            let d = qualities[draw.int(0...2)]
            gridDpi = d
            let frameWidth = (w * d + 4607) / 4608, frameHeight = (h * d + 4607) / 4608
            let left = 200 * draw.int(0...(frameWidth / 200 - 1))
            let r0 = (0..<200).first { $0 % 8 == 0 && (frameHeight - $0) % 25 == 0 }!
            let top = r0 + 200 * draw.int(0...((frameHeight - r0) / 200 - 1))
            x0 = onLine(left, dpi: d)!; x1 = onLine(left + 200, dpi: d)!
            y1 = onLine(frameHeight - top, dpi: d)!; y0 = onLine(frameHeight - top - 200, dpi: d)!
        case .noArea:
            switch draw.int(0...2) {
            case 0: x1 = x0
            case 1: y1 = y0
            default: x1 = x0 - draw.int(1...64)
            }
        case .subPixel:
            // Under one pixel at 300 dpi (15.36 sixty-fourths) in both directions.
            x1 = x0 + draw.int(1...15); y1 = y0 + draw.int(1...15)
        default: break
        }
        let inner = PageRect64(minX: x0, minY: y0, maxX: x1, maxY: y1)
        let grow = kind == .handDrawn ? 0 : draw.int(0...300)
        let paint = PageRect64(minX: x0 - grow, minY: y0 - grow, maxX: x1 + grow, maxY: y1 + grow)
        var above: Int? = nil, below: Int? = nil
        switch kind {
        case .bothLimits: above = paint.maxY + draw.int(0...800); below = paint.minY - draw.int(0...800)
        case .limitAbove: above = paint.maxY + draw.int(0...800)
        case .limitBelow: below = paint.minY - draw.int(0...800)
        case .limitFar: above = paint.maxY + draw.int(2000...6000); below = paint.minY - draw.int(2000...6000)
        case .limitNearMargin:
            // Within 2 pixels at 150 dpi (61 sixty-fourths) of the paint's edge, either side of it.
            above = paint.maxY + draw.int(-61...61); below = paint.minY + draw.int(-61...61)
        case .limitInsideBlock:
            // Between inner and the block edge, which lies at most one block (8 pixels at 150 dpi: 246 sixty-fourths) out.
            above = inner.maxY + draw.int(1...245); below = inner.minY - draw.int(1...245)
        case .edgeOnGridLine, .widenedBand: if draw.int(0...1) == 0 { above = paint.maxY + draw.int(0...400) }
        default: break
        }
        if let a = above, a < inner.maxY { above = inner.maxY }
        if let b = below, b > inner.minY { below = inner.minY }
        return Box(kind: kind, inner: inner, paint: kind == .handDrawn ? inner : paint, above: above, below: below, gridDpi: gridDpi)
    }

    /// The painting code's rectangle as the check's lines (rows from the top), or nil when it paints nothing.
    static func painted(_ b: Box, width w: Int, height h: Int, dpi d: Int) -> PixelPaintRule.Lines? {
        guard let raster = PixelPlan.Raster(widthSixtyFourths: w, heightSixtyFourths: h, dpi: d),
              let p = PixelPlan.project(inner: b.inner, paint: b.paint, limitAbove: b.above, limitBelow: b.below, raster: raster)
        else { return nil }
        let rows = raster.pixelHeight
        return PixelPaintRule.Lines(left: p.painted.minX, top: rows - p.painted.maxY, right: p.painted.maxX, bottom: rows - p.painted.minY)
    }

    /// The check's copy, or nil when it paints nothing.
    static func checked(_ b: Box, width w: Int, height h: Int, dpi d: Int) -> PixelPaintRule.Lines? {
        let fw = PixelPaintRule.frameSide(w, dpi: d), fh = PixelPaintRule.frameSide(h, dpi: d)
        let l = PixelPaintRule.pixelPaint(inner: b.inner, paint: b.paint, limitAbove: b.above, limitBelow: b.below,
                                          dpi: d, width: fw, height: fh)
        return l.isEmpty ? nil : l
    }

    /// Whether all four edges of `inner` lie on 8-pixel lines at quality `d`, each on a whole
    /// sixty-fourth: columns counted from the picture's left edge, rows from its top edge.
    static func onGrid(_ inner: PageRect64, height h: Int, dpi d: Int) -> Bool {
        let frameHeight = (h * d + 4607) / 4608
        let edges = [inner.minX, inner.maxX, inner.minY, inner.maxY]
        guard edges.allSatisfy({ ($0 * d) % 4608 == 0 }) else { return false }
        let columns = [inner.minX * d / 4608, inner.maxX * d / 4608]
        let rows = [frameHeight - inner.maxY * d / 4608, frameHeight - inner.minY * d / 4608]
        return (columns + rows).allSatisfy { $0 % 8 == 0 }
    }

    @Test("45,000 boxes at three qualities: the two copies give the same four pixel lines, or both paint nothing")
    func boxesAgree() {
        var draw = Draw(state: Self.seed)
        var compared = 0, differ = 0, nothingPainted = 0, onGrid = 0
        var first: String?
        var mix: [Kind: Int] = [:], nothingByKind: [Kind: Int] = [:]
        for page in Self.pages {
            for i in 0..<Self.boxesPerPage {
                let kind = Kind.allCases[i % Kind.allCases.count]
                let b = Self.box(kind, page: page, draw: &draw)
                mix[kind, default: 0] += 1
                if let g = b.gridDpi, Self.onGrid(b.inner, height: page.height, dpi: g) { onGrid += 1 }
                for d in Self.qualities {
                    compared += 1
                    let a = Self.painted(b, width: page.width, height: page.height, dpi: d)
                    let c = Self.checked(b, width: page.width, height: page.height, dpi: d)
                    if a == nil, c == nil { nothingPainted += 1; nothingByKind[kind, default: 0] += 1 }
                    if a != c {
                        differ += 1
                        if first == nil {
                            first = "\(page.name) at \(d) dpi, \(kind.rawValue): inner \(b.inner), paint \(b.paint), "
                                + "limits \(String(describing: b.above)) above and \(String(describing: b.below)) below; "
                                + "painting code \(String(describing: a)), check \(String(describing: c))"
                        }
                    }
                }
            }
        }
        print("Boxes by kind: " + Kind.allCases.map { "\($0.rawValue) \(mix[$0] ?? 0)" }.joined(separator: ", ")
              + "; painting nothing at a quality: \(nothingPainted) (wholly off the page \(nothingByKind[.whollyOff] ?? 0), "
              + "no area \(nothingByKind[.noArea] ?? 0)); on 8-pixel lines: \(onGrid)")
        #expect(compared == 135_000)
        #expect(mix.values.reduce(0, +) == 45_000)
        #expect(Kind.allCases.allSatisfy { mix[$0] == 2_500 }, "every kind of the mix is drawn 2,500 times")
        #expect(onGrid == 2_500, "every box of the grid-line kind has its four edges on 8-pixel lines")
        // Only a box with no area, or one wholly off the page, paints nothing: the first at every
        // quality; the second where neither its margin's extra pixel nor its block edge reaches the
        // picture. A seeded run draws the same boxes, so the second count is pinned.
        #expect(nothingByKind[.noArea] == 7_500)
        #expect(nothingByKind[.whollyOff] == Self.nothingWhollyOff)
        #expect(nothingPainted == 7_500 + Self.nothingWhollyOff, "only boxes with no area or wholly off the page paint nothing")
        #expect(differ == 0, "\(differ) of \(compared) differ; the first: \(first ?? "")")
    }

    @Test("Every page side from 10 pt to 5,000 pt, at three qualities: the same picture size")
    func sizesAgree() {
        var compared = 0, differ = 0
        var first: String?
        for s in 640...320_000 {
            for d in Self.qualities {
                compared += 1
                let painting = PixelPlan.Raster(widthSixtyFourths: s, heightSixtyFourths: s, dpi: d)!
                if painting.pixelWidth != PixelPaintRule.frameSide(s, dpi: d) || painting.pixelHeight != PixelPaintRule.frameSide(s, dpi: d) {
                    differ += 1
                    if first == nil { first = "side \(s) at \(d) dpi: painting code \(painting.pixelWidth), check \(PixelPaintRule.frameSide(s, dpi: d))" }
                }
            }
        }
        #expect(compared == 958_083)
        #expect(differ == 0, "\(differ) of \(compared) differ; the first: \(first ?? "")")
    }

    @Test("A box with no area has no unit and paints nothing in the check's copy, at every quality")
    func noAreaPaintsNothing() {
        let paint = PageRect64(minX: 6_300, minY: 28_900, maxX: 7_100, maxY: 30_100)
        // Zero width on a pixel line and off one, zero height, and a side of less than zero.
        let inners = [PageRect64(minX: 6_912, minY: 29_000, maxX: 6_912, maxY: 30_000),
                      PageRect64(minX: 6_400, minY: 29_000, maxX: 6_400, maxY: 30_000),
                      PageRect64(minX: 6_400, minY: 29_000, maxX: 7_000, maxY: 29_000),
                      PageRect64(minX: 7_000, minY: 29_000, maxX: 6_400, maxY: 30_000)]
        var checked = 0
        for inner in inners {
            for d in Self.qualities {
                let w = PixelPaintRule.frameSide(39_168, dpi: d), h = PixelPaintRule.frameSide(50_688, dpi: d)
                #expect(PixelPaintRule.unit(inner: inner, dpi: d, width: w, height: h) == nil, "\(inner) at \(d) dpi")
                #expect(PixelPaintRule.pixelPaint(inner: inner, paint: paint, limitAbove: nil, limitBelow: nil,
                                                  dpi: d, width: w, height: h).isEmpty, "\(inner) at \(d) dpi")
                checked += 1
            }
        }
        #expect(checked == 12)
    }

    @Test("The differential's planted failures are five, each a patch in the repository's Mutants folder")
    func plantedFailures() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../../Mutants").standardized
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("paint-rule-copy-") && $0.hasSuffix(".patch") }
        #expect(names.count == 5, "\(names.sorted())")
    }
}
