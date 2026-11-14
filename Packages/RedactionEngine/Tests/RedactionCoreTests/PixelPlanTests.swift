import Testing
import RedactionCore

// The pixel step's arithmetic. Expected values are worked out here from the
// rule's own sentences, not by calling the code under test a second way.

private let letterWidth = 39_168   // 612 pt in sixty-fourths
private let letterHeight = 50_688  // 792 pt
private let a4Width = 38_098       // 595.276 pt
private let a4Height = 53_881      // 841.89 pt

private func raster(_ width: Int, _ height: Int, _ dpi: Int) -> PixelPlan.Raster {
    PixelPlan.Raster(widthSixtyFourths: width, heightSixtyFourths: height, dpi: dpi)!
}

/// A coordinate, in sixty-fourths, that lies strictly inside pixel `n`
/// (n < x·d/4608 < n + 1), so it rounds down to n and up to n + 1.
private func inside(_ n: Int, dpi: Int) -> Int {
    let x = (n * 4_608) / dpi + 1
    precondition(x * dpi > n * 4_608 && x * dpi < (n + 1) * 4_608)
    return x
}

private func floorPixel(_ x: Int, dpi: Int) -> Int {
    let a = x * dpi
    return a >= 0 ? a / 4_608 : -((-a + 4_607) / 4_608)
}

private func ceilPixel(_ x: Int, dpi: Int) -> Int {
    let a = x * dpi
    return a >= 0 ? (a + 4_607) / 4_608 : -((-a) / 4_608)
}

private func box(_ minX: Int, _ minY: Int, _ maxX: Int, _ maxY: Int) -> PageRect64 {
    PageRect64(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
}

private func grown(_ r: PageRect64, by m: Int) -> PageRect64 {
    box(r.minX - m, r.minY - m, r.maxX + m, r.maxY + m)
}

/// The blocks `inner` touches, as the rule defines them: columns from the
/// image's left edge, rows from its top edge, every 8 pixels, cut at the
/// image's edges.
private func blockHull(_ inner: PageRect64, _ r: PixelPlan.Raster) -> PixelPlan.PixelRect {
    let w = r.pixelWidth, h = r.pixelHeight, d = r.dpi
    let l = floorPixel(inner.minX, dpi: d), rt = ceilPixel(inner.maxX, dpi: d)
    let b = floorPixel(inner.minY, dpi: d), t = ceilPixel(inner.maxY, dpi: d)
    func down8(_ v: Int) -> Int { v >= 0 ? v / 8 * 8 : -((-v + 7) / 8 * 8) }
    func up8(_ v: Int) -> Int { -down8(-v) }
    return PixelPlan.PixelRect(
        minX: max(down8(l), 0), minY: max(h - up8(h - b), 0),
        maxX: min(up8(rt), w), maxY: min(h - down8(h - t), h))
}

private func contains(_ outer: PixelPlan.PixelRect, _ inner: PixelPlan.PixelRect) -> Bool {
    outer.minX <= inner.minX && outer.minY <= inner.minY && outer.maxX >= inner.maxX && outer.maxY >= inner.maxY
}

// MARK: - The side and the raster

@Suite struct PixelPlanSideTests {
    @Test(arguments: [
        (612.0, 39_168, [2_550, 1_700, 1_275]),
        (792.0, 50_688, [3_300, 2_200, 1_650]),
        (595.276, 38_098, [2_481, 1_654, 1_241]),
        (841.89, 53_881, [3_508, 2_339, 1_754]),
    ])
    func aSideBecomesWholeSixtyFourthsAndItsPixelsAtEachQuality(side: Double, sixtyFourths: Int, pixels: [Int]) throws {
        let s = try #require(PixelPlan.sixtyFourths(ofSide: side))
        #expect(s == sixtyFourths)
        for (dpi, expected) in zip([300, 200, 150], pixels) {
            #expect(raster(s, s, dpi).pixelWidth == expected)
            #expect(raster(s, s, dpi).pixelHeight == expected)
        }
    }

    @Test func aSideReadAHairAboveAWholeSixtyFourthIsThatSixtyFourth() {
        #expect(PixelPlan.sixtyFourths(ofSide: 792.0.nextUp) == 50_688)
        #expect(raster(39_168, PixelPlan.sixtyFourths(ofSide: 792.0.nextUp)!, 300).pixelHeight == 3_300)
    }

    @Test func aSideAThousandthOfAPointAboveIsTheNextSixtyFourth() {
        #expect(PixelPlan.sixtyFourths(ofSide: 792 + 0x1p-10) == 50_689)
    }

    @Test func aSideReadAHairBelowAWholeSixtyFourthIsThatSixtyFourth() {
        #expect(PixelPlan.sixtyFourths(ofSide: 792.0.nextDown) == 50_688)
    }

    @Test func aSideThatIsNotAPositiveFiniteNumberHasNoSixtyFourths() {
        for side in [0.0, -1.0, .nan, .infinity, -.infinity, 0x1p30] {
            #expect(PixelPlan.sixtyFourths(ofSide: side) == nil)
        }
    }

    @Test func aRasterNeedsPositiveSidesAndQuality() {
        #expect(PixelPlan.Raster(widthSixtyFourths: 0, heightSixtyFourths: 64, dpi: 300) == nil)
        #expect(PixelPlan.Raster(widthSixtyFourths: 64, heightSixtyFourths: -1, dpi: 300) == nil)
        #expect(PixelPlan.Raster(widthSixtyFourths: 64, heightSixtyFourths: 64, dpi: 0) == nil)
    }
}

// MARK: - The paint rule's ten cases (the projection's table)

/// One row: its name and what it found wrong (empty when the row holds).
struct PaintRuleCase: Sendable, CustomTestStringConvertible {
    let name: String
    let failures: @Sendable () -> [String]
    var testDescription: String { name }
}

private func check(_ ok: Bool, _ what: @autoclosure () -> String) -> [String] { ok ? [] : [what()] }

private let paintRuleCases: [PaintRuleCase] = [
    PaintRuleCase(name: "A margin that ends well short of its limit ends at the margin's edge") {
        let r = raster(letterWidth, letterHeight, 300)
        let inner = box(6_400, 29_000, 12_800, 30_000)
        let paint = grown(inner, by: 64)
        // paint's top 30,064 lies at 1,957.3 px: rounded up 1,958, plus one 1,959.
        // The limit at 31,000 lies at 2,018.2 px, far above.
        guard let p = PixelPlan.project(inner: inner, paint: paint, limitAbove: 31_000, limitBelow: nil, raster: r) else { return ["no rectangle"] }
        return check(p.marginEdge.maxY == 1_959, "margin top \(p.marginEdge.maxY)")
            + check(p.painted.maxY == max(1_959, blockHull(inner, r).maxY), "top \(p.painted.maxY)")
    },
    PaintRuleCase(name: "A margin a fraction of a pixel short of its limit is held: no row past the limit") {
        let r = raster(letterWidth, letterHeight, 300)
        // paint's top 30,238 lies at 1,968.6 px: up to 1,969, plus one 1,970, which
        // would end 0.05 pt past the limit at 30,256 (1,969.8 px). Held: 1,969.
        // inner's top 30,160 is at 1,963.5 px, up to 1,964, itself a block line
        // (3,300 − 8 × 167), so the block does not reach the limit.
        let inner = box(6_400, 29_000, 12_800, 30_160)
        let paint = box(6_336, 28_936, 12_864, 30_238)
        guard let p = PixelPlan.project(inner: inner, paint: paint, limitAbove: 30_256, limitBelow: nil, raster: r) else { return ["no rectangle"] }
        return check(blockHull(inner, r).maxY == 1_964, "block top \(blockHull(inner, r).maxY)")
            + check(p.marginEdge.maxY == 1_969, "margin top \(p.marginEdge.maxY)")
            + check(p.painted.maxY == 1_969, "top \(p.painted.maxY)")
    },
    PaintRuleCase(name: "A limit between the selection and the block edge does not pull the block edge back") {
        let r = raster(letterWidth, letterHeight, 300)
        // inner's top 30,190 is at 1,965.5 px (up to 1,966); the block line above it is
        // 1,972 (3,300 − 8 × 166). The limit at 30,260 is at 1,970.1 px, between them.
        let inner = box(6_400, 29_000, 12_800, 30_190)
        let paint = box(6_336, 28_936, 12_864, 30_206)
        guard let p = PixelPlan.project(inner: inner, paint: paint, limitAbove: 30_260, limitBelow: nil, raster: r) else { return ["no rectangle"] }
        return check(p.painted.maxY == 1_972, "top \(p.painted.maxY)")
            + check(p.marginEdge.maxY == 1_968, "margin top \(p.marginEdge.maxY)")
    },
    PaintRuleCase(name: "With no limit lines each side is the further out of the margin's edge and the block edge") {
        var failures: [String] = []
        let r = raster(letterWidth, letterHeight, 300)
        let inner = box(6_401, 29_001, 12_801, 30_001)
        let cases: [(PageRect64, Int?, Int?)] = [
            (inner, nil, nil),                       // a hand-drawn box: paint equals inner
            (grown(inner, by: 40), nil, 20_000),     // on a page's first line: none above
            (grown(inner, by: 40), 40_000, nil),     // on its last line: none below
        ]
        for (paint, above, below) in cases {
            guard let p = PixelPlan.project(inner: inner, paint: paint, limitAbove: above, limitBelow: below, raster: r) else { failures.append("no rectangle"); continue }
            let hull = blockHull(inner, r)
            if above == nil {
                failures += check(p.painted.maxY == max(ceilPixel(paint.maxY, dpi: 300) + 1, hull.maxY), "top \(p.painted.maxY)")
            }
            if below == nil {
                failures += check(p.painted.minY == min(floorPixel(paint.minY, dpi: 300) - 1, hull.minY), "bottom \(p.painted.minY)")
            }
            failures += check(p.painted.minX == min(floorPixel(paint.minX, dpi: 300) - 1, hull.minX), "left \(p.painted.minX)")
            failures += check(p.painted.maxX == max(ceilPixel(paint.maxX, dpi: 300) + 1, hull.maxX), "right \(p.painted.maxX)")
        }
        return failures
    },
    PaintRuleCase(name: "A selection edge exactly on a block line takes no further block on that side") {
        let r = raster(letterWidth, letterHeight, 300)
        // 3,072 sixty-fourths is exactly pixel 200, a block line; 47,616 is exactly
        // row 3,100, which is 3,300 − 8 × 25. A hand-drawn box.
        let inner = box(3_072, 40_000, 9_000, 47_616)
        guard let p = PixelPlan.project(inner: inner, paint: inner, limitAbove: nil, limitBelow: nil, raster: r) else { return ["no rectangle"] }
        return check(p.painted.minX == 199, "left \(p.painted.minX)")
            + check(p.painted.maxY == 3_101, "top \(p.painted.maxY)")
    },
    PaintRuleCase(name: "A box at the image's edge, and one reaching past it, is clipped to the image") {
        let r = raster(letterWidth, letterHeight, 300)
        guard let atEdge = PixelPlan.project(inner: box(0, 0, 1_000, 1_000), paint: box(0, 0, 1_000, 1_000), limitAbove: nil, limitBelow: nil, raster: r),
              let past = PixelPlan.project(inner: box(-500, 49_000, letterWidth + 500, letterHeight + 1), paint: box(-600, 48_900, letterWidth + 600, letterHeight + 100), limitAbove: nil, limitBelow: nil, raster: r)
        else { return ["no rectangle"] }
        return check(atEdge.painted.minX == 0 && atEdge.painted.minY == 0, "at the edge \(atEdge.painted)")
            + check(past.painted.minX == 0 && past.painted.maxX == 2_550 && past.painted.maxY == 3_300, "past the edge \(past.painted)")
            + check(past.marginEdge.minX == 0 && past.marginEdge.maxX == 2_550 && past.marginEdge.maxY == 3_300, "past the edge, margin \(past.marginEdge)")
    },
    PaintRuleCase(name: "On a Letter page each quality covers every block the selection touches, and 150 dpi reaches at least as far as 300 dpi's blocks") {
        var failures: [String] = []
        let inner = box(7_013, 23_417, 15_991, 24_389)
        let paint = grown(inner, by: 51)
        var results: [Int: (PixelPlan.PixelRect, PixelPlan.PixelRect)] = [:]
        for dpi in [300, 200, 150] {
            let r = raster(letterWidth, letterHeight, dpi)
            guard let p = PixelPlan.project(inner: inner, paint: paint, limitAbove: nil, limitBelow: nil, raster: r) else { return ["no rectangle at \(dpi)"] }
            let hull = blockHull(inner, r)
            failures += check(contains(p.painted, hull), "at \(dpi) the blocks \(hull) are not inside \(p.painted)")
            results[dpi] = (p.painted, hull)
        }
        // In page points, a 150 dpi pixel line x lies at x × 2 in 300 dpi pixels.
        let (p150, _) = results[150]!, (_, hull300) = results[300]!
        failures += check(p150.minX * 2 <= hull300.minX, "left 150 \(p150.minX) past 300's block \(hull300.minX)")
        failures += check(p150.maxX * 2 >= hull300.maxX, "right 150 \(p150.maxX) short of 300's block \(hull300.maxX)")
        failures += check(p150.minY * 2 <= hull300.minY, "bottom 150 \(p150.minY) past 300's block \(hull300.minY)")
        failures += check(p150.maxY * 2 >= hull300.maxY, "top 150 \(p150.maxY) short of 300's block \(hull300.maxY)")
        return failures
    },
    PaintRuleCase(name: "At each of four rotations the rectangle is the rule's in that picture, its limits heights in that picture") {
        var failures: [String] = []
        // The page as it is rasterised at 0°, 90°, 180° and 270°: the box as the plan
        // gives it in each picture's own frame, with a limit above and below.
        let frames: [(Int, Int, PageRect64)] = [
            (letterWidth, letterHeight, box(5_011, 30_007, 20_003, 30_901)),
            (letterHeight, letterWidth, box(30_007, 19_165, 30_901, 34_157)),
            (letterWidth, letterHeight, box(19_165, 19_787, 34_157, 20_681)),
            (letterHeight, letterWidth, box(19_787, 5_011, 20_681, 20_003)),
        ]
        for (w, h, inner) in frames {
            let r = raster(w, h, 300)
            let paint = grown(inner, by: 45)
            let above = inner.maxY + 90, below = inner.minY - 90
            guard let p = PixelPlan.project(inner: inner, paint: paint, limitAbove: above, limitBelow: below, raster: r) else { failures.append("no rectangle"); continue }
            let hull = blockHull(inner, r)
            failures += check(contains(p.painted, hull), "blocks not covered in \(w)×\(h)")
            failures += check(p.marginEdge.maxY <= floorPixel(above, dpi: 300), "margin past the limit above in \(w)×\(h)")
            failures += check(p.marginEdge.minY >= ceilPixel(below, dpi: 300), "margin past the limit below in \(w)×\(h)")
            failures += check(p.painted.maxY == max(p.marginEdge.maxY, hull.maxY), "top is not the further edge in \(w)×\(h)")
            failures += check(p.painted.minY == min(p.marginEdge.minY, hull.minY), "bottom is not the further edge in \(w)×\(h)")
        }
        return failures
    },
    PaintRuleCase(name: "A selection with no area gets no rectangle") {
        let r = raster(letterWidth, letterHeight, 300)
        return check(PixelPlan.project(inner: box(6_400, 29_000, 6_400, 30_000), paint: box(6_300, 28_900, 6_500, 30_100), limitAbove: nil, limitBelow: nil, raster: r) == nil, "a zero-width selection was projected")
            + check(PixelPlan.project(inner: box(6_400, 29_000, 7_000, 29_000), paint: box(6_300, 28_900, 7_100, 29_100), limitAbove: nil, limitBelow: nil, raster: r) == nil, "a zero-height selection was projected")
    },
    PaintRuleCase(name: "Two plans whose selected words differ inside one widened band paint the same pixels") {
        let r = raster(letterWidth, letterHeight, 200)
        // inner is the band in both plans; the selection inside it is not an input.
        let band = box(4_608, 30_000, 34_560, 30_900)
        let first = PixelPlan.project(inner: band, paint: grown(band, by: 38), limitAbove: 31_500, limitBelow: 29_400, raster: r)
        let second = PixelPlan.project(inner: band, paint: grown(band, by: 38), limitAbove: 31_500, limitBelow: 29_400, raster: r)
        return check(first != nil && first == second, "the two plans paint differently")
    },
]

@Suite struct PixelPlanPaintRuleTests {
    @Test func theTableHoldsTheTenCases() {
        #expect(paintRuleCases.count == 10)
    }

    @Test(arguments: paintRuleCases)
    func paintRule(_ row: PaintRuleCase) {
        let failures = row.failures()
        #expect(failures.isEmpty, "\(failures)")
    }
}

// MARK: - The projection's boundaries

@Suite struct PixelPlanBoundaryTests {
    /// For each tier and each grid phase 0…7, a hand-drawn box mid-page whose
    /// edge falls that many pixels past a block line (left, bottom) or short of
    /// one (right, top). With `paint` equal to `inner`, the margin's edge is one
    /// pixel out from `inner`'s, so it is the further out only at phase 0.
    @Test(arguments: [300, 200, 150])
    func everyGridPhaseOnEachSide(dpi: Int) {
        let r = raster(letterWidth, letterHeight, dpi)
        let h = r.pixelHeight
        let line = 640           // a block line from the left: 8 × 80
        let rowLine = h - 8 * 40 // a block line from the top, in rows from the bottom
        for phase in 0..<8 {
            // left: inner's left pixel is line + phase
            let l = PixelPlan.project(inner: box(inside(line + phase, dpi: dpi), 20_000, inside(line + 200, dpi: dpi), 21_000), paint: box(inside(line + phase, dpi: dpi), 20_000, inside(line + 200, dpi: dpi), 21_000), limitAbove: nil, limitBelow: nil, raster: r)
            #expect(l?.painted.minX == (phase == 0 ? line - 1 : line), "left, phase \(phase), \(dpi) dpi")
            // right: inner rounds up to line + 8 − phase … with phase 0 on the line itself
            let rightPixel = phase == 0 ? line + 8 : line + 8 - phase
            let rx = PixelPlan.project(inner: box(inside(line - 100, dpi: dpi), 20_000, inside(rightPixel - 1, dpi: dpi), 21_000), paint: box(inside(line - 100, dpi: dpi), 20_000, inside(rightPixel - 1, dpi: dpi), 21_000), limitAbove: nil, limitBelow: nil, raster: r)
            #expect(rx?.painted.maxX == (phase == 0 ? line + 9 : line + 8), "right, phase \(phase), \(dpi) dpi")
            // bottom: inner's bottom row is rowLine + phase
            let b = PixelPlan.project(inner: box(10_000, inside(rowLine + phase, dpi: dpi), 11_000, inside(rowLine + 100, dpi: dpi)), paint: box(10_000, inside(rowLine + phase, dpi: dpi), 11_000, inside(rowLine + 100, dpi: dpi)), limitAbove: nil, limitBelow: nil, raster: r)
            #expect(b?.painted.minY == (phase == 0 ? rowLine - 1 : rowLine), "bottom, phase \(phase), \(dpi) dpi")
            // top: inner rounds up to rowLine − phase, with phase 0 on the line itself
            let topPixel = rowLine - phase
            let t = PixelPlan.project(inner: box(10_000, inside(rowLine - 100, dpi: dpi), 11_000, inside(topPixel - 1, dpi: dpi)), paint: box(10_000, inside(rowLine - 100, dpi: dpi), 11_000, inside(topPixel - 1, dpi: dpi)), limitAbove: nil, limitBelow: nil, raster: r)
            #expect(t?.painted.maxY == (phase == 0 ? rowLine + 1 : rowLine), "top, phase \(phase), \(dpi) dpi")
        }
    }

    /// Rows count 8 from the top, so the last block is cut by the bottom edge:
    /// at 300 dpi it holds rows 0…3 (3,300 = 8 × 412 + 4), at 150 dpi rows 0…1
    /// (1,650 = 8 × 205 + 2). The box holds rows 1…3. At 300 dpi its block ends
    /// at 4 and the margin's edge one row higher, 5, is the further out; at
    /// 150 dpi it also touches the block of rows 2…9, which ends at 10.
    @Test(arguments: [(300, 3_300, 5), (150, 1_650, 10)])
    func aBoxOnTheLastBlockRowOfALetterPageReachesTheBottomEdge(dpi: Int, rows: Int, top: Int) {
        let r = raster(letterWidth, letterHeight, dpi)
        #expect(r.pixelHeight == rows)
        let inner = box(9_000, inside(1, dpi: dpi), 12_000, inside(3, dpi: dpi))
        let p = PixelPlan.project(inner: inner, paint: inner, limitAbove: nil, limitBelow: nil, raster: r)
        #expect(p?.painted.minY == 0)
        #expect(p?.painted.maxY == top)
    }

    @Test func aRasterWhoseHeightIsNotAMultipleOfEightCutsTheBottomBlock() {
        let r = raster(64_000, 64_000, 300)    // 1,000 pt: 4,167 rows
        #expect(r.pixelHeight == 4_167)
        let inner = box(9_000, inside(2, dpi: 300), 12_000, inside(5, dpi: 300))
        let p = PixelPlan.project(inner: inner, paint: inner, limitAbove: nil, limitBelow: nil, raster: r)
        #expect(p?.painted.minY == 0)
        #expect(p?.painted.maxY == 7)          // the block from the top that holds rows 0…6
    }

    @Test func anAsPlacedBoxHasItsMarginEdgeOnePixelOutFromItsOwnPixels() {
        let r = raster(letterWidth, letterHeight, 300)
        let placed = box(inside(400, dpi: 300), inside(1_200, dpi: 300), inside(700, dpi: 300), inside(1_260, dpi: 300))
        let p = PixelPlan.project(inner: placed, paint: placed, limitAbove: nil, limitBelow: nil, raster: r)
        #expect(p?.marginEdge == PixelPlan.PixelRect(minX: 399, minY: 1_199, maxX: 702, maxY: 1_262))
    }

    @Test func aWidenedBoxCoversItsWholeBand() {
        let r = raster(letterWidth, letterHeight, 300)
        let band = box(2_304, 30_000, 36_864, 30_900)
        let p = PixelPlan.project(inner: band, paint: grown(band, by: 38), limitAbove: 31_500, limitBelow: 29_400, raster: r)
        #expect(p.map { contains($0.painted, blockHull(band, r)) } == true)
    }

    @Test func aBoxWhollyOffTheImageGetsNoRectangle() {
        let r = raster(letterWidth, letterHeight, 300)
        #expect(PixelPlan.project(inner: box(-9_000, 1_000, -5_000, 2_000), paint: box(-9_100, 900, -4_900, 2_100), limitAbove: nil, limitBelow: nil, raster: r) == nil)
    }
}

// MARK: - Properties over seeded boxes

/// A small seeded generator, so the boxes are the same on every run.
private struct SplitMix64 {
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

@Suite struct PixelPlanPropertyTests {
    @Test func everyBoxCoversItsSelectionOnTheImageItsBlocksAndItsMarginEdge() {
        var g = SplitMix64(state: 0x5EED_0F_B0C5)
        let pages = [(letterWidth, letterHeight), (letterHeight, letterWidth), (a4Width, a4Height), (a4Height, a4Width)]
        var projected = 0
        for (w, h) in pages {
            for dpi in [300, 200, 150] {
                let r = raster(w, h, dpi)
                for _ in 0..<1_000 {
                    let x0 = g.int(-800...(w + 200)), y0 = g.int(-800...(h + 200))
                    let inner = box(x0, y0, x0 + g.int(1...12_000), y0 + g.int(1...2_000))
                    let m = g.int(0...256)
                    let paint = g.int(0...4) == 0 ? inner : grown(inner, by: m)
                    let above: Int? = g.int(0...2) == 0 ? nil : inner.maxY + g.int(0...400)
                    let below: Int? = g.int(0...2) == 0 ? nil : inner.minY - g.int(0...400)
                    guard let p = PixelPlan.project(inner: inner, paint: paint, limitAbove: above, limitBelow: below, raster: r) else {
                        // Only a box with nothing on the image gets no rectangle.
                        #expect(blockHull(inner, r).isEmpty)
                        continue
                    }
                    projected += 1
                    let hull = blockHull(inner, r)
                    let own = PixelPlan.PixelRect(
                        minX: max(floorPixel(inner.minX, dpi: dpi), 0), minY: max(floorPixel(inner.minY, dpi: dpi), 0),
                        maxX: min(ceilPixel(inner.maxX, dpi: dpi), r.pixelWidth), maxY: min(ceilPixel(inner.maxY, dpi: dpi), r.pixelHeight))
                    #expect(contains(p.painted, own), "inner's pixels on the image")
                    #expect(contains(p.painted, hull), "the blocks inner touches")
                    #expect(contains(p.painted, p.marginEdge) || p.marginEdge.isEmpty, "the margin's edge lies inside the paint")
                    if let above, !p.marginEdge.isEmpty {
                        #expect(p.marginEdge.maxY <= max(floorPixel(above, dpi: dpi), 0), "the margin passes the limit above")
                        #expect(p.painted.maxY <= max(floorPixel(above, dpi: dpi), hull.maxY), "a side passes the limit only where a block does")
                    }
                    if let below, !p.marginEdge.isEmpty {
                        #expect(p.marginEdge.minY >= min(ceilPixel(below, dpi: dpi), r.pixelHeight), "the margin passes the limit below")
                        #expect(p.painted.minY >= min(ceilPixel(below, dpi: dpi), hull.minY), "a side passes the limit only where a block does")
                    }
                    #expect(p.painted.minX >= 0 && p.painted.minY >= 0 && p.painted.maxX <= r.pixelWidth && p.painted.maxY <= r.pixelHeight)
                }
            }
        }
        #expect(projected > 9_000)
    }
}
