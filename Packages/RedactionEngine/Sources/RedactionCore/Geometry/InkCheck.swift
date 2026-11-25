/// The ink check: does the boxed text's own ink run past the rectangle a box
/// is painted as, read from the page's picture before any fill? It can only
/// widen a box, and only past an allowance ordinary text does not reach.
///
/// The walk, over a grid of grey values in the pixels of one raster:
/// 1. Paper is the most common value on a ring from one pixel off the painted
///    rectangle to 1.5 pt out (at least three pixels). Under 60 % of the ring
///    at that value, the surroundings are textured and nothing is judged.
/// 2. Ink is a value more than 64 levels from paper.
/// 3. Seeds are ink in the box's tight rectangle, less 12 % of the line's
///    height at its top and its bottom, so a neighbouring line's descender
///    is not taken for the box's own glyphs, and less any part inside another
///    word's box.
/// 4. The flood is 8-connected. It never enters another word's box, and never
///    travels along a straight run of ink three line heights long or longer:
///    an underline, a table rule or a field border is not the glyph's ink.
/// 5. On each side, `past` is the farthest flooded pixel beyond the painted
///    rectangle, counting a column or a row only where its flooded ink is
///    thicker than the larger of two pixels and an eighth of the line height.
///
/// The verdicts, in the order they are decided: `indeterminate`, `absent`,
/// `pastCap`, `escaped`, `residual`, `clear`. The check returns the verdict
/// and how far each side grows. It never returns how far the ink runs: an
/// escaped side grows in whole steps of half a line height, and a side past
/// the cap grows to the cap. It knows nothing of how a page is exported.
///
/// Every quantity is whole-number arithmetic on sixty-fourths of a point and
/// the raster's dots per inch, so the check gives the same answer wherever it
/// is run.
package enum InkCheck {
    /// How far from paper a value must be to count as ink, in grey levels.
    package static let inkContrast = 64

    /// A page's picture as grey values, one byte a pixel, rows from the
    /// bottom: the value at column `x` and row `y` is `values[y * width + x]`.
    package struct Grid: Sendable {
        package let width: Int
        package let height: Int
        package let values: [UInt8]

        /// Nil unless both sides are positive and there is one value a pixel.
        package init?(width: Int, height: Int, values: [UInt8]) {
            guard width > 0, height > 0, values.count == width * height else { return nil }
            self.width = width
            self.height = height
            self.values = values
        }
    }

    /// The six outcomes of the check for one box.
    package enum Verdict: String, Hashable, Sendable, CaseIterable {
        /// No flooded ink lies past the painted rectangle.
        case clear
        /// Some does, no further than the allowance: the larger of 1 pt and
        /// 0.08 of the line height. The box is not widened.
        case residual
        /// Past the allowance and short of the cap: each such side grows, in
        /// whole steps of half a line height, to cover the ink.
        case escaped
        /// Past the cap, the larger of two line heights and 24 pt, to within
        /// one pixel: each such side grows to the cap, and ink of the boxed
        /// text can still lie beyond it.
        case pastCap
        /// Under 1 % of the tight rectangle is ink: there is no evidence of
        /// where the boxed text's ink is. The box is not widened.
        case absent
        /// The surroundings are textured, or the box cannot be read on this
        /// raster. The box is not widened.
        case indeterminate
    }

    /// How far each side of a box's paint grows, in sixty-fourths of a point.
    package struct Growth: Hashable, Sendable {
        package var left: Int
        package var right: Int
        package var bottom: Int
        package var top: Int

        package init(left: Int = 0, right: Int = 0, bottom: Int = 0, top: Int = 0) {
            self.left = left
            self.right = right
            self.bottom = bottom
            self.top = top
        }

        package static let none = Growth()
        package var isNone: Bool { self == .none }
    }

    /// The check's answer for one box.
    package struct Result: Hashable, Sendable {
        package let verdict: Verdict
        /// Zero on every side unless the verdict is `escaped` or `pastCap`.
        package let growth: Growth

        package init(verdict: Verdict, growth: Growth = .none) {
            self.verdict = verdict
            self.growth = growth
        }
    }

    /// The whole pixels that hold any part of `rect` on `raster`, rounded
    /// outward and clipped to the image. Empty when nothing of it is on it.
    package static func pixels(enclosing rect: PageRect64, raster: PixelPlan.Raster) -> PixelPlan.PixelRect {
        PixelPlan.PixelRect(
            minX: min(max(raster.pixelFloor(rect.minX), 0), raster.pixelWidth),
            minY: min(max(raster.pixelFloor(rect.minY), 0), raster.pixelHeight),
            maxX: min(max(raster.pixelCeil(rect.maxX), 0), raster.pixelWidth),
            maxY: min(max(raster.pixelCeil(rect.maxY), 0), raster.pixelHeight)
        )
    }

    /// Checks one box against the page's picture.
    ///
    /// - Parameters:
    ///   - box: the box as planned. Its painted rectangle is the one the
    ///     pixel step gives (`PixelPlan.project`), its seeds come from `tight`.
    ///   - lineHeight: the height of the box's line of text, in sixty-fourths.
    ///   - others: the boxes of the page's other words, the ones the box does
    ///     not cover. The flood never enters them and takes no seed in them.
    ///   - grid: the page's picture before any fill, on `raster`.
    ///
    /// `indeterminate` when the grid is not the raster's size, the line height
    /// is not positive, the box has no painted rectangle, or its tight
    /// rectangle has no pixel on the image.
    package static func evaluate(
        box: PaintedBox, lineHeight: Int, others: [PageRect64],
        grid: Grid, raster: PixelPlan.Raster
    ) -> Result {
        guard grid.width == raster.pixelWidth, grid.height == raster.pixelHeight, lineHeight > 0,
              let painted = PixelPlan.project(
                inner: box.inner, paint: box.paint,
                limitAbove: box.limitAbove, limitBelow: box.limitBelow, raster: raster
              )?.painted
        else { return Result(verdict: .indeterminate) }
        let tight = pixels(enclosing: box.tight, raster: raster)
        guard !tight.isEmpty else { return Result(verdict: .indeterminate) }

        let dpi = raster.dpi
        let perInch = PixelPlan.sixtyFourthsPerInch
        let h = lineHeight
        // The cap, in sixty-fourths: the larger of two line heights and 24 pt.
        let cap = max(2 * h, 24 * 64)
        let capPixels = ceilDivision(cap * dpi, perInch)
        let ringPixels = max(3, ceilDivision(96 * dpi, perInch))      // 1.5 pt
        let ruleLength = ceilDivision(3 * h * dpi, perInch)           // 3H
        let thin = max(2, ceilDivision(h * dpi, 8 * perInch))         // H/8
        let insetNumerator = 12 * h * dpi, insetDenominator = 100 * perInch
        let inset = (2 * insetNumerator + insetDenominator) / (2 * insetDenominator)  // 0.12H, rounded

        let values = grid.values, width = grid.width, height = grid.height
        func value(_ x: Int, _ y: Int) -> Int { Int(values[y * width + x]) }

        // 1. Paper, from the ring.
        var histogram = [Int](repeating: 0, count: 256), ringCount = 0
        let ringMinX = max(0, painted.minX - ringPixels), ringMaxX = min(width, painted.maxX + ringPixels)
        let ringMinY = max(0, painted.minY - ringPixels), ringMaxY = min(height, painted.maxY + ringPixels)
        for y in ringMinY..<ringMaxY {
            for x in ringMinX..<ringMaxX
            where !(x >= painted.minX - 1 && x < painted.maxX + 1 && y >= painted.minY - 1 && y < painted.maxY + 1) {
                histogram[value(x, y)] += 1
                ringCount += 1
            }
        }
        var paper = 0
        for v in 1..<256 where histogram[v] > histogram[paper] { paper = v }
        guard ringCount > 0, histogram[paper] * 10 >= ringCount * 6 else { return Result(verdict: .indeterminate) }

        // 2. Ink.
        func isInk(_ x: Int, _ y: Int) -> Bool { abs(value(x, y) - paper) > inkContrast }

        // The window the flood may cover: the painted rectangle and the cap.
        let windowMinX = max(0, painted.minX - capPixels), windowMaxX = min(width, painted.maxX + capPixels)
        let windowMinY = max(0, painted.minY - capPixels), windowMaxY = min(height, painted.maxY + capPixels)
        let windowWidth = windowMaxX - windowMinX, windowHeight = windowMaxY - windowMinY
        func index(_ x: Int, _ y: Int) -> Int { (y - windowMinY) * windowWidth + (x - windowMinX) }

        // Other words' boxes: the flood never enters them.
        var blocked = [Bool](repeating: false, count: windowWidth * windowHeight)
        for other in others {
            let o = pixels(enclosing: other, raster: raster)
            let minX = max(windowMinX, o.minX), maxX = min(windowMaxX, o.maxX)
            let minY = max(windowMinY, o.minY), maxY = min(windowMaxY, o.maxY)
            guard minX < maxX, minY < maxY else { continue }
            for y in minY..<maxY { for x in minX..<maxX { blocked[index(x, y)] = true } }
        }

        // 4. A straight run of ink 3H long or longer, across or up, through a pixel.
        func isOnRule(_ x: Int, _ y: Int) -> Bool {
            var run = 1, a = x - 1, b = x + 1
            while a >= windowMinX, run < ruleLength, isInk(a, y) { run += 1; a -= 1 }
            while b < windowMaxX, run < ruleLength, isInk(b, y) { run += 1; b += 1 }
            if run >= ruleLength { return true }
            run = 1; a = y - 1; b = y + 1
            while a >= windowMinY, run < ruleLength, isInk(x, a) { run += 1; a -= 1 }
            while b < windowMaxY, run < ruleLength, isInk(x, b) { run += 1; b += 1 }
            return run >= ruleLength
        }

        var flooded = [Bool](repeating: false, count: windowWidth * windowHeight)
        var stack: [(Int, Int)] = []
        func reach(_ x: Int, _ y: Int) {
            guard x >= windowMinX, x < windowMaxX, y >= windowMinY, y < windowMaxY else { return }
            let i = index(x, y)
            guard !flooded[i], !blocked[i], isInk(x, y), !isOnRule(x, y) else { return }
            flooded[i] = true
            stack.append((x, y))
        }

        // 3. Seeds, and the ink under the tight rectangle.
        var inkUnder = 0
        for y in tight.minY..<tight.maxY {
            for x in tight.minX..<tight.maxX where isInk(x, y) { inkUnder += 1 }
        }
        let tightArea = (tight.maxX - tight.minX) * (tight.maxY - tight.minY)
        if tight.minY + inset < tight.maxY - inset {
            for y in (tight.minY + inset)..<(tight.maxY - inset) {
                for x in tight.minX..<tight.maxX { reach(x, y) }
            }
        }

        // The flood. Each pixel outside the painted rectangle widens the
        // flooded span of its column and of its row.
        var columnLow = [Int](repeating: .max, count: windowWidth), columnHigh = [Int](repeating: .min, count: windowWidth)
        var rowLow = [Int](repeating: .max, count: windowHeight), rowHigh = [Int](repeating: .min, count: windowHeight)
        while let (x, y) = stack.popLast() {
            if !(x >= painted.minX && x < painted.maxX && y >= painted.minY && y < painted.maxY) {
                let c = x - windowMinX, r = y - windowMinY
                columnLow[c] = min(columnLow[c], y); columnHigh[c] = max(columnHigh[c], y)
                rowLow[r] = min(rowLow[r], x); rowHigh[r] = max(rowHigh[r], x)
            }
            for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 { reach(x + dx, y + dy) } }
        }

        // 5. The farthest counted pixel on each side, as a coordinate.
        var farLeft: Int?, farRight: Int?, farBottom: Int?, farTop: Int?
        for c in 0..<windowWidth where columnHigh[c] >= columnLow[c] && columnHigh[c] - columnLow[c] + 1 > thin {
            let x = c + windowMinX
            if x >= painted.maxX { farRight = max(farRight ?? x, x) }
            if x < painted.minX { farLeft = min(farLeft ?? x, x) }
        }
        for r in 0..<windowHeight where rowHigh[r] >= rowLow[r] && rowHigh[r] - rowLow[r] + 1 > thin {
            let y = r + windowMinY
            if y >= painted.maxY { farTop = max(farTop ?? y, y) }
            if y < painted.minY { farBottom = min(farBottom ?? y, y) }
        }

        if inkUnder * 100 < tightArea { return Result(verdict: .absent) }

        // Each side's reach past the painted rectangle, in pixels.
        let pastLeft = farLeft.map { painted.minX - $0 } ?? 0
        let pastRight = farRight.map { $0 - painted.maxX + 1 } ?? 0
        let pastBottom = farBottom.map { painted.minY - $0 } ?? 0
        let pastTop = farTop.map { $0 - painted.maxY + 1 } ?? 0

        enum Reach: Int, Comparable {
            case none, residual, escaped, pastCap
            static func < (a: Reach, b: Reach) -> Bool { a.rawValue < b.rawValue }
        }
        // The allowance: past ≤ max(1 pt, 0.08H). The cap: within one pixel of it.
        func classify(_ past: Int) -> Reach {
            if past == 0 { return .none }
            if (past + 1) * perInch >= cap * dpi { return .pastCap }
            if past * perInch * 100 > dpi * max(6_400, 8 * h) { return .escaped }
            return .residual
        }
        let reaches = [classify(pastLeft), classify(pastRight), classify(pastBottom), classify(pastTop)]
        let worst = reaches.max()!

        // How far a side grows: to the cap past it; otherwise whole steps of
        // H/2 that cover the farthest counted pixel, never past the cap.
        func growth(_ r: Reach, need: () -> Int) -> Int {
            switch r {
            case .pastCap: return cap
            case .escaped:
                let n = need()
                let steps = max(1, ceilDivision(2 * n, h))
                return min(ceilDivision(steps * h, 2), max(n, cap))
            case .none, .residual: return 0
            }
        }
        // A paint edge at e covers pixel column x on its right when
        // ⌈e·d/4608⌉ ≥ x, on its left when ⌊e·d/4608⌋ ≤ x + 1 (the pixel step
        // adds one pixel outside each edge).
        let grown = Growth(
            left: growth(reaches[0]) { box.paint.minX - floorDivision((farLeft! + 1) * perInch, dpi) },
            right: growth(reaches[1]) { ceilDivision(farRight! * perInch, dpi) - box.paint.maxX },
            bottom: growth(reaches[2]) { box.paint.minY - floorDivision((farBottom! + 1) * perInch, dpi) },
            top: growth(reaches[3]) { ceilDivision(farTop! * perInch, dpi) - box.paint.maxY }
        )

        switch worst {
        case .pastCap: return Result(verdict: .pastCap, growth: grown)
        case .escaped: return Result(verdict: .escaped, growth: grown)
        case .residual: return Result(verdict: .residual)
        case .none: return Result(verdict: .clear)
        }
    }
}

extension PaintedBox {
    /// The box after the ink check: its paint grown on the sides the check
    /// widened, each such side's limit line removed, so the pixel step's hold
    /// cannot keep the paint off the ink, and the one flag of the outcome set.
    /// Unchanged for a verdict that does not widen and for a box painted as
    /// drawn. Which boxes are checked is the caller's: a Search or Scan box on
    /// a typed page, never a hand-drawn box or one placed on ink already.
    package func applying(_ result: InkCheck.Result) -> PaintedBox {
        guard !asDrawn, !result.growth.isNone,
              result.verdict == .escaped || result.verdict == .pastCap
        else { return self }
        var box = self
        let g = result.growth
        box.paint = PageRect64(
            minX: paint.minX - g.left, minY: paint.minY - g.bottom,
            maxX: paint.maxX + g.right, maxY: paint.maxY + g.top
        )
        if g.top > 0 { box.limitAbove = nil }
        if g.bottom > 0 { box.limitBelow = nil }
        switch result.verdict {
        case .escaped: box.inkEnlargedCovered = true
        case .pastCap: box.inkEnlargedToCap = true
        case .clear, .residual, .absent, .indeterminate: break
        }
        return box
    }
}

/// ⌊a / b⌋ for a positive `b`, for any sign of `a`.
private func floorDivision(_ a: Int, _ b: Int) -> Int {
    let q = a / b
    return (a % b != 0 && a < 0) ? q - 1 : q
}

/// ⌈a / b⌉ for a positive `b`, for any sign of `a`.
extension InkCheck {
    /// The default band's net: whether the page's picture, before any fill,
    /// shows ink in the pixels of `band` that `lineMargin` does not hold, by
    /// the check's own ink: more than `inkContrast` grey levels from paper,
    /// paper the most common value on a ring from one pixel off `band` to
    /// 1.5 pt out (at least three pixels). True too when under 60 % of the
    /// ring is at that value, or the grid is not the raster's size: the net
    /// can only withdraw a band, never grant one.
    package static func inkInSlot(band: PixelPlan.PixelRect, lineMargin: PixelPlan.PixelRect,
                                  grid: Grid, raster: PixelPlan.Raster) -> Bool {
        guard grid.width == raster.pixelWidth, grid.height == raster.pixelHeight else { return true }
        let width = grid.width, height = grid.height
        func value(_ x: Int, _ y: Int) -> Int { Int(grid.values[y * width + x]) }
        let ring = max(3, ceilDivision(96 * raster.dpi, PixelPlan.sixtyFourthsPerInch))
        var histogram = [Int](repeating: 0, count: 256), count = 0
        let rx0 = max(0, band.minX - ring), rx1 = min(width, band.maxX + ring)
        let ry0 = max(0, band.minY - ring), ry1 = min(height, band.maxY + ring)
        if rx0 < rx1 && ry0 < ry1 {
            for y in ry0..<ry1 {
                for x in rx0..<rx1
                where !(x >= band.minX - 1 && x < band.maxX + 1 && y >= band.minY - 1 && y < band.maxY + 1) {
                    histogram[value(x, y)] += 1
                    count += 1
                }
            }
        }
        var paper = 0
        for v in 1..<256 where histogram[v] > histogram[paper] { paper = v }
        guard count > 0, histogram[paper] * 10 >= count * 6 else { return true }
        let x0 = max(0, band.minX), x1 = min(width, band.maxX)
        let y0 = max(0, band.minY), y1 = min(height, band.maxY)
        guard x0 < x1 && y0 < y1 else { return false }
        for y in y0..<y1 {
            for x in x0..<x1
            where !(x >= lineMargin.minX && x < lineMargin.maxX && y >= lineMargin.minY && y < lineMargin.maxY) {
                if abs(value(x, y) - paper) > inkContrast { return true }
            }
        }
        return false
    }
}

private func ceilDivision(_ a: Int, _ b: Int) -> Int {
    let q = a / b
    return (a % b != 0 && a > 0) ? q + 1 : q
}
