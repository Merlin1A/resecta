import XCTest

/// Reads the canvas from a screenshot, since regions are drawn and not in
/// the accessibility tree: where the page sits at the fit zoom, whether a
/// point shows the canvas background or the page (the zoom's proof), and
/// the boxes' geometry first, then their colour: where two shots differ,
/// how much of a rectangle's sides a tint covers, how thick a line is, and
/// the contrast of two points. Every box's line is page teal and its inside
/// the veil, whatever placed it. All points are window points.
///
/// nonisolated: an XCUITest drives a separate process and touches no
/// @MainActor state.
nonisolated struct CanvasPixelProbe {

    enum Tint {
        case red, blue, green, teal, veil, tagFill

        func matches(_ r: Int, _ g: Int, _ b: Int) -> Bool {
            switch self {
            case .red: return r > 190 && r - g > 30 && r - b > 30
            case .blue: return b > 190 && b - r > 35 && b - g > 15
            case .green: return g > 150 && g - r > 22 && g - b > 12
            // The brand teal of an active tool glyph (ResultWalkUITests' ring rule).
            // Page teal (11, 100, 111) passes it too: every box's line.
            case .teal: return b - r > 50 && g - r > 50 && r < 90 && (70...175).contains(g) && (80...190).contains(b)
            // The veil over white is 213, 215, 217.
            case .veil: return [r, g, b].allSatisfy { (205...224).contains($0) } && max(r, g, b) - min(r, g, b) <= 8
            // A tag's opaque ink fill, 20, 34, 43; black text never matches.
            case .tagFill: return abs(r - 20) <= 10 && abs(g - 34) <= 10 && abs(b - 43) <= 10 && b - r >= 15
            }
        }
    }

    let windowSize: CGSize
    private let width: Int
    private let height: Int
    private let scale: CGFloat
    private let data: [UInt8]

    init?(_ shot: XCUIScreenshot, windowSize: CGSize) {
        guard let cg = shot.image.cgImage, windowSize.width > 0, let pixels = DevicePixels(cg) else { return nil }
        self.windowSize = windowSize
        width = pixels.width
        height = pixels.height
        scale = CGFloat(pixels.width) / windowSize.width
        data = pixels.data
    }

    func rgb(_ x: CGFloat, _ y: CGFloat) -> (Int, Int, Int) {
        let px = min(max(Int(x * scale), 0), width - 1)
        let py = min(max(Int(y * scale), 0), height - 1)
        let i = (py * width + px) * 4
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
    }

    /// The canvas background (the grouped background, light or dark), not
    /// the page: just above the fit page it reads background, and page-white
    /// once the page is zoomed past it.
    func isBackground(_ p: CGPoint) -> Bool {
        let (r, g, b) = rgb(p.x, p.y)
        return (abs(r - 242) < 6 && abs(g - 242) < 6 && abs(b - 247) < 6) || (r < 12 && g < 12 && b < 12)
    }

    private func isWhite(_ c: (Int, Int, Int)) -> Bool { c.0 >= 250 && c.1 >= 250 && c.2 >= 250 }

    /// The fit page: the longest white vertical run at x = 12 gives the top,
    /// the longest white horizontal run `sideRow` points below it (15 unless
    /// given; a row clear of the page's text) the sides, the height from the
    /// page's aspect (Letter unless given). Nil when the page fills the width
    /// (zoomed past fit).
    func fitPage(aspect: CGFloat = 792.0 / 612.0, sideRow: CGFloat = 15) -> CGRect? {
        func longestRun(_ count: Int, _ white: (Int) -> Bool) -> (Int, Int)? {
            var best: (Int, Int)?
            var start: Int?
            for i in 0...count {
                let w = i < count && white(i)
                if w, start == nil { start = i }
                if !w, let s0 = start {
                    if best == nil || (i - s0) > (best!.1 - best!.0) { best = (s0, i) }
                    start = nil
                }
            }
            return best
        }
        let h = Int(windowSize.height), w = Int(windowSize.width)
        guard let v = longestRun(h, { isWhite(rgb(12, CGFloat($0))) }), v.1 - v.0 > 200 else { return nil }
        let top = CGFloat(v.0)
        guard let hr = longestRun(w, { isWhite(rgb(CGFloat($0), top + sideRow)) }), hr.1 - hr.0 > 200 else { return nil }
        let left = CGFloat(hr.0), pageWidth = CGFloat(hr.1 - hr.0)
        if left <= 0 && pageWidth >= windowSize.width - 1 { return nil }
        return CGRect(x: left, y: top, width: pageWidth, height: pageWidth * aspect)
    }

    /// The bounds of a tint inside `rect`, nil under 12 matching points.
    func tintBounds(_ tint: Tint, in rect: CGRect) -> CGRect? {
        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        var n = 0
        var y = max(rect.minY, 0)
        while y < min(rect.maxY, windowSize.height) {
            var x = max(rect.minX, 0)
            while x < min(rect.maxX, windowSize.width) {
                let (r, g, b) = rgb(x, y)
                if tint.matches(r, g, b) {
                    n += 1
                    minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                }
                x += 1
            }
            y += 1
        }
        guard n >= 12 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    // MARK: - Geometry, then colour

    /// One pixel's width in points.
    var pixel: CGFloat { 1 / scale }

    /// The bounds of a tint inside `rect`, read pixel by pixel, exact to a
    /// pixel where `tintBounds` steps whole points from `rect`'s corner (up
    /// to a point out); nil under 12 matching pixels.
    func tintPixelBounds(_ tint: Tint, in rect: CGRect) -> CGRect? {
        let x0 = max(Int((rect.minX * scale).rounded(.down)), 0), x1 = min(Int((rect.maxX * scale).rounded(.up)), width)
        let y0 = max(Int((rect.minY * scale).rounded(.down)), 0), y1 = min(Int((rect.maxY * scale).rounded(.up)), height)
        guard x0 < x1, y0 < y1 else { return nil }
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        var n = 0
        for py in y0..<y1 {
            for px in x0..<x1 {
                // The pixel's centre, so `rgb` reads this pixel and not its neighbour.
                let (r, g, b) = rgb((CGFloat(px) + 0.5) / scale, (CGFloat(py) + 0.5) / scale)
                if tint.matches(r, g, b) {
                    n += 1
                    minX = min(minX, px); minY = min(minY, py); maxX = max(maxX, px); maxY = max(maxY, py)
                }
            }
        }
        guard n >= 12 else { return nil }
        return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }

    /// Where this shot differs from `other` by more than 24 levels in a
    /// channel, inside `rect`, read pixel by pixel; nil where nothing does.
    func differenceBounds(from other: CanvasPixelProbe, in rect: CGRect) -> CGRect? {
        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        var y = max(rect.minY, 0)
        while y < min(rect.maxY, windowSize.height) {
            var x = max(rect.minX, 0)
            while x < min(rect.maxX, windowSize.width) {
                let a = rgb(x, y), b = other.rgb(x, y)
                if abs(a.0 - b.0) > 24 || abs(a.1 - b.1) > 24 || abs(a.2 - b.2) > 24 {
                    minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                }
                x += pixel
            }
            y += pixel
        }
        guard minX.isFinite else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + pixel, height: maxY - minY + pixel)
    }

    /// The share of one-point steps along the four sides of `rect` where
    /// `tint` shows, at the side or a pixel either side of it.
    func edgeCoverage(of rect: CGRect, _ tint: Tint) -> Double {
        var points: [(CGPoint, Bool)] = []
        var x = rect.minX
        while x <= rect.maxX {
            points.append((CGPoint(x: x, y: rect.minY), true)); points.append((CGPoint(x: x, y: rect.maxY), true))
            x += 1
        }
        var y = rect.minY
        while y <= rect.maxY {
            points.append((CGPoint(x: rect.minX, y: y), false)); points.append((CGPoint(x: rect.maxX, y: y), false))
            y += 1
        }
        guard !points.isEmpty else { return 0 }
        let hits = points.filter { p, horizontal in
            [-pixel, 0, pixel].contains { d in
                let q = horizontal ? CGPoint(x: p.x, y: p.y + d) : CGPoint(x: p.x + d, y: p.y)
                let (r, g, b) = rgb(q.x, q.y)
                return tint.matches(r, g, b)
            }
        }
        return Double(hits.count) / Double(points.count)
    }

    /// The length in points of the run of `tint` through `p`, read pixel by
    /// pixel, up and down (`vertical`) or left and right; zero when `p`
    /// itself does not show it.
    func thickness(of tint: Tint, across p: CGPoint, vertical: Bool) -> CGFloat {
        func shows(_ d: CGFloat) -> Bool {
            let (r, g, b) = vertical ? rgb(p.x, p.y + d) : rgb(p.x + d, p.y)
            return tint.matches(r, g, b)
        }
        guard shows(0) else { return 0 }
        var before: CGFloat = 0, after: CGFloat = 0
        while before < 20, shows(-(before + pixel)) { before += pixel }
        while after < 20, shows(after + pixel) { after += pixel }
        return before + after + pixel
    }

    /// The WCAG 2 contrast ratio of the pixels at `p` and `q`.
    func contrast(_ p: CGPoint, _ q: CGPoint) -> Double {
        func luminance(_ c: (Int, Int, Int)) -> Double {
            func l(_ v: Int) -> Double {
                let x = Double(v) / 255
                return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * l(c.0) + 0.7152 * l(c.1) + 0.0722 * l(c.2)
        }
        let a = luminance(rgb(p.x, p.y)), b = luminance(rgb(q.x, q.y))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

// MARK: - Device pixels: the edge scan and the classed reading

nonisolated extension CanvasPixelProbe {
    /// A bitmap drawn into device RGB, 8 bits a channel, row 0 at its top: the
    /// file's one reader of device pixels, the probe's own and the scans'.
    struct DevicePixels {
        let width: Int
        let height: Int
        let data: [UInt8]

        init?(_ image: CGImage) {
            let w = image.width, h = image.height
            guard w > 0, h > 0 else { return nil }
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            let drawn: Bool = buf.withUnsafeMutableBytes { ptr -> Bool in
                guard let ctx = CGContext(
                    data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8,
                    bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return false }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard drawn else { return nil }
            width = w
            height = h
            data = buf
        }

        func rgb(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
            let i = (y * width + x) * 4
            return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
        }

        /// The marks along row `y` (empty when it is outside the bitmap).
        func row(_ y: Int, _ mark: ((r: Int, g: Int, b: Int)) -> Mark) -> [Mark] {
            (0..<height).contains(y) ? (0..<width).map { mark(rgb($0, y)) } : []
        }

        /// The marks down column `x` (empty when it is outside the bitmap).
        func column(_ x: Int, _ mark: ((r: Int, g: Int, b: Int)) -> Mark) -> [Mark] {
            (0..<width).contains(x) ? (0..<height).map { mark(rgb(x, $0)) } : []
        }
    }

    /// The outermost steps between paper and not-paper along one row and one column of a bitmap.
    /// All four are device-pixel indices in the bitmap, origin at its top-left.
    struct Edges: Equatable { let left: Int; let right: Int; let top: Int; let bottom: Int }

    /// `row` and `column` are device-pixel indices through the box's middle. A pixel is "not paper"
    /// when any channel differs from `paper` by more than `step`. Returns nil when the row or the
    /// column holds no such pixel.
    static func edges(in bitmap: CGImage, row: Int, column: Int,
                      paper: (r: Int, g: Int, b: Int), step: Int) -> Edges? {
        guard let pixels = DevicePixels(bitmap) else { return nil }
        let notPaper: ((r: Int, g: Int, b: Int)) -> Mark = { mark($0, paper: paper, step: step) == .paper ? .paper : .fill }
        guard let across = outermost(pixels.row(row, notPaper), .fill),
              let down = outermost(pixels.column(column, notPaper), .fill) else { return nil }
        return Edges(left: across.first, right: across.last, top: down.first, bottom: down.last)
    }

    enum Mark: Equatable { case paper, line, fill }

    /// With d = paper - pixel on each channel. Paper: no |d| exceeds `step`.
    /// Line: 5 * (d.r - max(d.g, d.b)) > d.r. Fill: any other pixel that is not paper.
    /// The look's teal is line; its ink, black, and letters under the veil are fill.
    static func mark(_ pixel: (r: Int, g: Int, b: Int),
                     paper: (r: Int, g: Int, b: Int), step: Int) -> Mark {
        let d = (r: paper.r - pixel.r, g: paper.g - pixel.g, b: paper.b - pixel.b)
        if abs(d.r) <= step, abs(d.g) <= step, abs(d.b) <= step { return .paper }
        return 5 * (d.r - max(d.g, d.b)) > d.r ? .line : .fill
    }

    struct Reading: Equatable {
        /// The outermost fill pixels of the row and of the column. nil when either holds none.
        let fill: Edges?
        /// The first run of line pixels met from each end, three device pixels or longer:
        /// its outer end and its inner end. nil when a side has no such run.
        let lineOuter: Edges?
        let lineInner: Edges?
    }

    static func reading(in bitmap: CGImage, row: Int, column: Int,
                        paper: (r: Int, g: Int, b: Int), step: Int) -> Reading {
        guard let pixels = DevicePixels(bitmap) else { return Reading(fill: nil, lineOuter: nil, lineInner: nil) }
        let classes: ((r: Int, g: Int, b: Int)) -> Mark = { mark($0, paper: paper, step: step) }
        let across = pixels.row(row, classes), down = pixels.column(column, classes)
        var fill: Edges?
        if let a = outermost(across, .fill), let d = outermost(down, .fill) {
            fill = Edges(left: a.first, right: a.last, top: d.first, bottom: d.last)
        }
        guard let left = lineRun(across, Array(across.indices)),
              let right = lineRun(across, Array(across.indices.reversed())),
              let top = lineRun(down, Array(down.indices)),
              let bottom = lineRun(down, Array(down.indices.reversed())) else {
            return Reading(fill: fill, lineOuter: nil, lineInner: nil)
        }
        return Reading(fill: fill,
                       lineOuter: Edges(left: left.outer, right: right.outer, top: top.outer, bottom: bottom.outer),
                       lineInner: Edges(left: left.inner, right: right.inner, top: top.inner, bottom: bottom.inner))
    }

    /// The first and last index holding `mark`, or nil.
    static func outermost(_ marks: [Mark], _ mark: Mark) -> (first: Int, last: Int)? {
        guard let first = marks.firstIndex(of: mark), let last = marks.lastIndex(of: mark) else { return nil }
        return (first, last)
    }

    /// Walking `indices` in order, the first run of line pixels three or more long: the index
    /// where it was met (its outer end) and its last (its inner end). nil when there is none.
    static func lineRun(_ marks: [Mark], _ indices: [Int]) -> (outer: Int, inner: Int)? {
        var run: (outer: Int, inner: Int)?
        for i in indices {
            if marks[i] == .line {
                run = (run?.outer ?? i, i)
            } else if let r = run {
                if abs(r.inner - r.outer) + 1 >= 3 { return r }
                run = nil
            }
        }
        if let r = run, abs(r.inner - r.outer) + 1 >= 3 { return r }
        return nil
    }
}
