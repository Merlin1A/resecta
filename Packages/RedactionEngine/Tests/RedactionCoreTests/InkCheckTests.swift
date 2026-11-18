import Foundation
import Testing
import RedactionCore

// The ink check. Each picture is drawn here in sixty-fourths of a point and
// rendered at the raster's dots per inch, so one case runs at several. The
// expected verdicts are worked out from the rule's sentences; the painted
// rectangle, the check's input, comes from the pixel step.

private let pageWidth = 12_800   // 200 pt
private let pageHeight = 6_400   // 100 pt
private let dpis = [72, 144, 150, 300]

private func pt(_ p: Double) -> Int { Int((p * 64).rounded()) }
private func rect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> PageRect64 {
    PageRect64(minX: pt(x0), minY: pt(y0), maxX: pt(x1), maxY: pt(y1))
}

/// A page's picture: white paper, black ink.
private struct Picture {
    let raster: PixelPlan.Raster
    var values: [UInt8]

    init(dpi: Int) {
        raster = PixelPlan.Raster(widthSixtyFourths: pageWidth, heightSixtyFourths: pageHeight, dpi: dpi)!
        values = [UInt8](repeating: 255, count: raster.pixelWidth * raster.pixelHeight)
    }

    var width: Int { raster.pixelWidth }
    var height: Int { raster.pixelHeight }
    var grid: InkCheck.Grid { InkCheck.Grid(width: width, height: height, values: values)! }

    /// Ink on every pixel whose centre lies in `r`.
    mutating func fill(_ r: PageRect64) {
        let d = raster.dpi
        func centreIn(_ n: Int, _ lo: Int, _ hi: Int) -> Bool {
            lo * 2 * d <= (2 * n + 1) * 4_608 && (2 * n + 1) * 4_608 < hi * 2 * d
        }
        let x0 = max(0, r.minX * d / 4_608 - 1), x1 = min(width, r.maxX * d / 4_608 + 2)
        let y0 = max(0, r.minY * d / 4_608 - 1), y1 = min(height, r.maxY * d / 4_608 + 2)
        guard x0 < x1, y0 < y1 else { return }
        for y in y0..<y1 where centreIn(y, r.minY, r.maxY) {
            for x in x0..<x1 where centreIn(x, r.minX, r.maxX) { values[y * width + x] = 0 }
        }
    }

    /// Ink on whole pixels: columns `minX..<maxX`, rows `minY..<maxY`.
    mutating func fillPixels(_ minX: Int, _ minY: Int, _ maxX: Int, _ maxY: Int) {
        for y in minY..<maxY { for x in minX..<maxX { values[y * width + x] = 0 } }
    }

    /// Letters `width` pt wide with `gap` pt between them, from `x0` to `x1`,
    /// on rows `y0..<y1`. Joined, each is tied to the next by a 1 pt bridge
    /// at its top and its bottom by turns: one piece of ink whose longest
    /// straight run spans two letters.
    mutating func letters(_ x0: Double, _ x1: Double, _ y0: Double, _ y1: Double,
                          width w: Double = 6, gap: Double = 1, joined: Bool = true) {
        var x = x0, i = 0
        while x < x1 {
            let right = min(x + w, x1)
            fill(rect(x, y0, right, y1))
            if joined, right + gap < x1 {
                fill(i % 2 == 0 ? rect(right, y1 - 1, right + gap, y1) : rect(right, y0, right + gap, y0 + 1))
            }
            x = right + gap
            i += 1
        }
    }
}

/// The ordinary word: tight 40…100 × 40…52 pt (a 12 pt line), paint 2 pt out.
private let tight = rect(40, 40, 100, 52)
private let paint = rect(38, 38, 102, 54)
private let lineHeight = pt(12)
private let halfLine = pt(6)
private let cap = pt(24)

private func box(tight t: PageRect64 = tight, paint p: PageRect64 = paint,
                 limitAbove: Int? = nil, limitBelow: Int? = nil, asDrawn: Bool = false) -> PaintedBox {
    PaintedBox(regionIDs: [], inner: t, paint: p, tight: t, limitAbove: limitAbove, limitBelow: limitBelow,
               exposure: .canShowLength, treatment: .notAsked, bandMade: false,
               inkEnlargedCovered: false, inkEnlargedToCap: false, asDrawn: asDrawn)
}

private func check(_ picture: Picture, _ b: PaintedBox = box(), lineHeight h: Int = lineHeight,
                   others: [PageRect64] = []) -> InkCheck.Result {
    InkCheck.evaluate(box: b, lineHeight: h, others: others, grid: picture.grid, raster: picture.raster)
}

private func painted(_ b: PaintedBox, _ picture: Picture) -> PixelPlan.PixelRect {
    PixelPlan.project(inner: b.inner, paint: b.paint, limitAbove: b.limitAbove, limitBelow: b.limitBelow,
                      raster: picture.raster)!.painted
}

/// The word's own letters, inside its tight rectangle.
private func ordinaryWord(dpi: Int) -> Picture {
    var p = Picture(dpi: dpi)
    p.letters(42, 98, 41, 51)
    return p
}

@Suite("The ink check: what fires and what does not")
struct InkCheckVerdictTests {
    @Test("An ordinary word reads clear and widens nothing", arguments: dpis)
    func ordinaryWordIsClear(dpi: Int) {
        #expect(check(ordinaryWord(dpi: dpi)) == InkCheck.Result(verdict: .clear))
    }

    @Test("A box wider than its ink reads clear (widths that overstate)", arguments: dpis)
    func widerBoxThanInkIsClear(dpi: Int) {
        var p = Picture(dpi: dpi)
        p.letters(42, 70, 41, 51)
        #expect(check(p) == InkCheck.Result(verdict: .clear))
    }

    @Test("A word whose stroke reaches past the tight rectangle but not past the paint reads clear", arguments: dpis)
    func strokeInsideThePaintIsClear(dpi: Int) {
        var p = Picture(dpi: dpi)
        p.letters(39.5, 100.5, 40, 52.5)
        #expect(check(p) == InkCheck.Result(verdict: .clear))
    }

    @Test("Letters past the right edge (widths that understate) widen that side only, in steps of half a line, and are covered",
          arguments: dpis)
    func inkPastTheRightEdgeWidensThatSide(dpi: Int) {
        var p = Picture(dpi: dpi)
        p.letters(42, 112, 41, 51)
        let r = check(p)
        #expect(r.verdict == .escaped)
        #expect(r.growth.left == 0 && r.growth.bottom == 0 && r.growth.top == 0)
        #expect(r.growth.right > 0 && r.growth.right % halfLine == 0)
        #expect(check(p, box().applying(r)).verdict == .clear)
    }

    @Test("A descender past the bottom widens the bottom only and is covered", arguments: dpis)
    func descenderWidensTheBottom(dpi: Int) {
        var p = ordinaryWord(dpi: dpi)
        p.fill(rect(60, 30, 63, 51))
        let r = check(p)
        #expect(r.verdict == .escaped)
        #expect(r.growth.left == 0 && r.growth.right == 0 && r.growth.top == 0)
        #expect(r.growth.bottom > 0 && r.growth.bottom % halfLine == 0)
        #expect(check(p, box().applying(r)).verdict == .clear)
    }

    @Test("A line drawn upward from its box (a flipped text matrix) widens the top only and is covered", arguments: dpis)
    func flippedLineWidensTheTop(dpi: Int) {
        var p = Picture(dpi: dpi)
        p.letters(42, 98, 46, 64)
        let r = check(p)
        #expect(r.verdict == .escaped)
        #expect(r.growth.left == 0 && r.growth.right == 0 && r.growth.bottom == 0)
        #expect(r.growth.top > 0 && r.growth.top % halfLine == 0)
        #expect(check(p, box().applying(r)).verdict == .clear)
    }

    @Test("A line drawn leftward from its box (a mirrored text matrix) widens the left only and is covered", arguments: dpis)
    func mirroredLineWidensTheLeft(dpi: Int) {
        var p = Picture(dpi: dpi)
        p.letters(30, 98, 41, 51)
        let r = check(p)
        #expect(r.verdict == .escaped)
        #expect(r.growth.right == 0 && r.growth.bottom == 0 && r.growth.top == 0)
        #expect(r.growth.left > 0 && r.growth.left % halfLine == 0)
        #expect(check(p, box().applying(r)).verdict == .clear)
    }

    @Test("Letters running past the cap give past the cap, and that side grows to the cap", arguments: dpis)
    func inkPastTheCapGrowsToTheCap(dpi: Int) {
        var p = Picture(dpi: dpi)
        p.letters(42, 199, 41, 51)
        #expect(check(p) == InkCheck.Result(verdict: .pastCap, growth: InkCheck.Growth(right: cap)))
    }

    @Test("An underline three line heights long is not followed", arguments: dpis)
    func longUnderlineIsNotFollowed(dpi: Int) {
        var p = ordinaryWord(dpi: dpi)
        p.fill(rect(42, 38, 160, 41))
        #expect(check(p) == InkCheck.Result(verdict: .clear))
    }

    @Test("A rule up the page three line heights long is not followed: a table's column line through the word", arguments: dpis)
    func longRuleUpIsNotFollowed(dpi: Int) {
        var p = ordinaryWord(dpi: dpi)
        p.fill(rect(97, 10, 99, 82))
        #expect(check(p) == InkCheck.Result(verdict: .clear))
    }

    @Test("A hairline leaving the box is not counted: no column of it is thicker than an eighth of the line", arguments: dpis)
    func hairlineIsNotCounted(dpi: Int) {
        var p = ordinaryWord(dpi: dpi)
        p.fill(rect(96, 45, 115, 46))
        #expect(check(p) == InkCheck.Result(verdict: .clear))
    }

    @Test("Ink joined to the next word runs into that word's box, which the flood never enters", arguments: dpis)
    func neighbouringWordsBoxIsNotEntered(dpi: Int) {
        var p = ordinaryWord(dpi: dpi)
        p.fill(rect(97, 46, 103, 47))
        p.letters(103, 129, 41, 51)
        #expect(check(p, others: [rect(102, 40, 130, 52)]) == InkCheck.Result(verdict: .clear))
    }

    @Test("A neighbouring line's ink inside the box's bottom inset and below it is no seed", arguments: dpis)
    func insetInkIsNoSeed(dpi: Int) {
        var p = Picture(dpi: dpi)
        p.letters(42, 98, 42, 51)
        p.fill(rect(70, 25, 74, 41.2))
        #expect(check(p) == InkCheck.Result(verdict: .clear))
    }

    @Test("No ink under the box reads absent and widens nothing", arguments: dpis)
    func noInkIsAbsent(dpi: Int) {
        #expect(check(Picture(dpi: dpi)) == InkCheck.Result(verdict: .absent))
    }

    @Test("Absent is decided before a past: under 1 % ink beneath the box widens nothing")
    func absentOutranksEscape() {
        var p = Picture(dpi: 144)
        p.fill(rect(98, 46, 112, 48))
        #expect(check(p) == InkCheck.Result(verdict: .absent))
    }

    @Test("Textured surroundings read indeterminate", arguments: dpis)
    func texturedRingIsIndeterminate(dpi: Int) {
        var p = ordinaryWord(dpi: dpi)
        for y in 0..<p.height { for x in 0..<p.width where (x + y) % 2 == 0 { p.values[y * p.width + x] = 0 } }
        #expect(check(p) == InkCheck.Result(verdict: .indeterminate))
    }

    @Test("A grid of another size, no line height, or a box off the image reads indeterminate")
    func unreadableInputsAreIndeterminate() {
        let p = ordinaryWord(dpi: 144)
        let small = InkCheck.Grid(width: 10, height: 10, values: [UInt8](repeating: 255, count: 100))!
        #expect(InkCheck.evaluate(box: box(), lineHeight: lineHeight, others: [], grid: small, raster: p.raster).verdict
                == .indeterminate)
        #expect(check(p, lineHeight: 0).verdict == .indeterminate)
        let off = rect(300, 40, 360, 52)
        #expect(check(p, box(tight: off, paint: rect(298, 38, 362, 54))).verdict == .indeterminate)
    }

    @Test("A grid with a value count that is not width × height is refused")
    func gridSizeIsChecked() {
        #expect(InkCheck.Grid(width: 3, height: 3, values: [0, 0]) == nil)
        #expect(InkCheck.Grid(width: 0, height: 3, values: []) == nil)
    }
}

@Suite("The ink check: the allowance, the cap and the steps")
struct InkCheckThresholdTests {
    /// The word with a block of ink 16 px tall joined to its last letter,
    /// running `past` pixels beyond the painted rectangle's right edge, at 144
    /// dpi (2 px a point).
    private func blockPast(_ past: Int) -> Picture {
        var p = ordinaryWord(dpi: 144)
        let right = painted(box(), p).maxX
        p.fillPixels(190, 84, right - 1 + past + 1, 100)
        return p
    }

    @Test("At a 12 pt line the allowance is 1 pt: 2 px past reads residual, 3 px escaped")
    func allowanceAtOnePoint() {
        #expect(check(blockPast(2)) == InkCheck.Result(verdict: .residual))
        #expect(check(blockPast(3)).verdict == .escaped)
    }

    @Test("At a 25 pt line the allowance is 0.08 of it, 2 pt: 4 px past reads residual, 5 px escaped")
    func allowanceAtEightHundredths() {
        let h = pt(25)
        #expect(check(blockPast(4), lineHeight: h) == InkCheck.Result(verdict: .residual))
        #expect(check(blockPast(5), lineHeight: h).verdict == .escaped)
    }

    @Test("The cap is 24 pt, 48 px, to within one pixel: 46 px past is escaped, 47 px past the cap")
    func capToWithinOnePixel() {
        #expect(check(blockPast(46)).verdict == .escaped)
        #expect(check(blockPast(47)) == InkCheck.Result(verdict: .pastCap, growth: InkCheck.Growth(right: cap)))
    }

    @Test("The cap is two line heights for a line over 12 pt")
    func capIsTwoLineHeights() {
        var p = Picture(dpi: 144)
        p.letters(42, 199, 41, 51)
        #expect(check(p, lineHeight: pt(14)) == InkCheck.Result(verdict: .pastCap, growth: InkCheck.Growth(right: pt(28))))
    }

    @Test("A side grows in whole half-line steps, so ink that ends at different places within one step gives one growth")
    func growthIsInSteps() {
        func grown(to x: Double) -> Int {
            var p = Picture(dpi: 144)
            p.letters(42, x, 41, 51)
            let r = check(p)
            #expect(r.verdict == .escaped)
            return r.growth.right
        }
        #expect(grown(to: 104) == halfLine)
        #expect(grown(to: 107) == halfLine)
        #expect(grown(to: 110) == 2 * halfLine)
    }
}

@Suite("The ink check: tight pages and bands")
struct InkCheckNeighbourTests {
    @Test("On a tight page whose line boxes overlap by an eighth, with letters touching across lines, no box widens",
          arguments: dpis)
    func tightPageWidensNoBox(dpi: Int) {
        var p = Picture(dpi: dpi)
        let lines = (0..<3).map { i in rect(40, 20 + 14 * Double(i), 100, 36 + 14 * Double(i)) }
        for i in 0..<3 { p.letters(42, 98, 20.5 + 14 * Double(i), 35.5 + 14 * Double(i), width: 2, gap: 5, joined: false) }
        for (i, line) in lines.enumerated() {
            let b = box(tight: line, paint: PageRect64(minX: line.minX - 64, minY: line.minY - 64,
                                                       maxX: line.maxX + 64, maxY: line.maxY + 64))
            let others = lines.enumerated().filter { $0.offset != i }.map(\.element)
            #expect(check(p, b, lineHeight: pt(16), others: others) == InkCheck.Result(verdict: .clear), "line \(i)")
        }
    }

    @Test("A band: the value's flood enters no other word, in the band or outside it, and another word's tall accent is not the value's",
          arguments: dpis)
    func bandFloodsOnlyTheValue(dpi: Int) {
        var p = Picture(dpi: dpi)
        p.letters(42, 68, 41, 51)                // the value
        p.fill(rect(67, 46, 75, 47))             // joined to the next word
        p.letters(74, 98, 41, 51)                // another word in the band
        p.fill(rect(85, 50, 88, 62))             // its tall accent, past the band's top
        p.fill(rect(97, 46, 106, 47))            // joined to a word outside the band
        p.letters(105, 139, 41, 51)
        let value = rect(40, 40, 70, 52)
        let band = box(tight: value, paint: paint)
        let others = [rect(72, 40, 100, 52), rect(104, 40, 140, 52)]
        #expect(check(p, band, others: others) == InkCheck.Result(verdict: .clear))
    }
}

@Suite("The ink check's outcome on the box")
struct InkCheckApplyingTests {
    @Test("Escaped: the paint grows by the growth, and only the flag 'enlarged, ink covered' is set")
    func escapedSetsCoveredOnly() {
        var p = Picture(dpi: 144)
        p.letters(42, 112, 41, 51)
        let r = check(p)
        let b = box().applying(r)
        #expect(b.inkEnlargedCovered && !b.inkEnlargedToCap)
        #expect(b.paint == PageRect64(minX: paint.minX, minY: paint.minY, maxX: paint.maxX + r.growth.right, maxY: paint.maxY))
    }

    @Test("Past the cap: the side grows to the cap, and only the flag 'enlarged to the cap' is set")
    func pastCapSetsToCapOnly() {
        var p = Picture(dpi: 144)
        p.letters(42, 199, 41, 51)
        let b = box().applying(check(p))
        #expect(b.inkEnlargedToCap && !b.inkEnlargedCovered)
        #expect(b.paint.maxX == paint.maxX + cap)
    }

    @Test("A side that grows loses its limit line, so the pixel step's hold cannot keep the paint off the ink; the other keeps its own",
          arguments: dpis)
    func grownSideLosesItsLimit(dpi: Int) {
        var p = Picture(dpi: dpi)
        p.letters(42, 98, 46, 64)
        let held = box(limitAbove: paint.maxY, limitBelow: paint.minY)
        let r = check(p, held)
        #expect(r.verdict == .escaped)
        let b = held.applying(r)
        #expect(b.limitAbove == nil && b.limitBelow == paint.minY)
        #expect(check(p, b).verdict == .clear)
    }

    @Test("A verdict that does not widen, or a box painted as drawn, leaves the box as it was")
    func nothingElseChangesTheBox() {
        for v in [InkCheck.Verdict.clear, .residual, .absent, .indeterminate] {
            #expect(box().applying(InkCheck.Result(verdict: v)) == box())
        }
        let drawn = box(asDrawn: true)
        #expect(drawn.applying(InkCheck.Result(verdict: .escaped, growth: InkCheck.Growth(right: halfLine))) == drawn)
    }

    @Test("The result carries no measure of the ink: only the verdict and each side's growth")
    func resultCarriesNoExtent() {
        let labels = Mirror(reflecting: InkCheck.Result(verdict: .clear)).children.compactMap(\.label)
        #expect(labels == ["verdict", "growth"])
    }
}
