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
        case red, blue, green, teal, veil

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
            }
        }
    }

    let windowSize: CGSize
    private let width: Int
    private let height: Int
    private let scale: CGFloat
    private let data: [UInt8]

    init?(_ shot: XCUIScreenshot, windowSize: CGSize) {
        guard let cg = shot.image.cgImage, windowSize.width > 0 else { return nil }
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = buf.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(
                data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        self.windowSize = windowSize
        width = w
        height = h
        scale = CGFloat(w) / windowSize.width
        data = buf
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
    /// the longest white horizontal run 15 points below it the sides, the
    /// height from the Letter aspect. Nil when the page fills the width
    /// (zoomed past fit).
    func fitPage() -> CGRect? {
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
        guard let hr = longestRun(w, { isWhite(rgb(CGFloat($0), top + 15)) }), hr.1 - hr.0 > 200 else { return nil }
        let left = CGFloat(hr.0), pageWidth = CGFloat(hr.1 - hr.0)
        if left <= 0 && pageWidth >= windowSize.width - 1 { return nil }
        return CGRect(x: left, y: top, width: pageWidth, height: pageWidth * 792 / 612)
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
