import XCTest

/// Reads the canvas from a screenshot, since regions are drawn and not in
/// the accessibility tree: where the page sits at the fit zoom, and the
/// tint at a point (a manual region is red, a selected one blue, a
/// search-applied one green). All points are window points.
///
/// nonisolated: an XCUITest drives a separate process and touches no
/// @MainActor state.
nonisolated struct CanvasPixelProbe {

    enum Tint {
        case red, blue, green

        func matches(_ r: Int, _ g: Int, _ b: Int) -> Bool {
            switch self {
            case .red: return r > 190 && r - g > 30 && r - b > 30
            case .blue: return b > 190 && b - r > 35 && b - g > 15
            case .green: return g > 150 && g - r > 22 && g - b > 12
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
}
