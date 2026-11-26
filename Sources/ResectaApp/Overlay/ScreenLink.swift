import CoreGraphics

/// The link between the pixels a run fills and the rectangle the canvas
/// fills on screen: the run's pixel lines as a share of the page as
/// displayed, and a rectangle moved outward to whole device pixel lines.
///
/// `nonisolated`: the app target defaults to the main actor, and these are
/// pure values and functions.
nonisolated enum ScreenLink {
    /// Four pixel lines of the page's rendered image at a quality: columns
    /// from the image's left, rows from its bottom. The image is of the page
    /// as displayed, after its turn, with the crop box's corner at the
    /// origin.
    struct PixelBox: Equatable, Sendable {
        let minX: Int
        let minY: Int
        let maxX: Int
        let maxY: Int
    }

    /// Whole device pixel lines, `x0 <= x1` and `y0 <= y1`.
    struct DeviceLines: Equatable, Sendable {
        let x0: Int
        let y0: Int
        let x1: Int
        let y1: Int
    }

    /// The pixel box as a share of the page as displayed (0 to 1, origin
    /// bottom-left). Pixel line k of a side lies at k × 72 ÷ (q × side) of
    /// that side: where the content of that line lies on the page, not
    /// where the file's picture puts it.
    static func share(pixel: PixelBox, quality: Int, displayedSize: CGSize) -> CGRect {
        let q = Double(quality)
        let w = Double(displayedSize.width), h = Double(displayedSize.height)
        guard q > 0, w > 0, h > 0 else { return .null }
        func across(_ k: Int) -> Double { Double(k) * 72 / (q * w) }
        func up(_ k: Int) -> Double { Double(k) * 72 / (q * h) }
        return CGRect(x: across(pixel.minX), y: up(pixel.minY),
                      width: Double(pixel.maxX - pixel.minX) * 72 / (q * w),
                      height: Double(pixel.maxY - pixel.minY) * 72 / (q * h))
    }

    /// `rect` cut to `clip`, its edges mapped through `toDevice` and moved
    /// outward to whole device pixel lines. Nil when nothing is left after
    /// the clip, or when `toDevice` is not axis-aligned.
    static func deviceLines(_ rect: CGRect, toDevice: CGAffineTransform, clip: CGRect) -> DeviceLines? {
        guard let cut = edges(of: rect, cutTo: clip), isAxisAligned(toDevice) else { return nil }
        let t = toDevice
        // Each edge on its own, in the order the transform is written, so the
        // guard sees the value a build computes.
        let xs = [t.a * cut.x0 + t.tx, t.a * cut.x1 + t.tx]
        let ys = [t.d * cut.y0 + t.ty, t.d * cut.y1 + t.ty]
        return DeviceLines(x0: Int(onLine(xs.min()!).rounded(.down)), y0: Int(onLine(ys.min()!).rounded(.down)),
                           x1: Int(onLine(xs.max()!).rounded(.up)), y1: Int(onLine(ys.max()!).rounded(.up)))
    }

    /// The rectangle to fill, with antialiasing off, so that the fill lies
    /// on whole device pixel lines, each the first one outward from `rect`
    /// cut to `clip`. `.null` when nothing is left after the clip. For a
    /// transform that is not axis-aligned, the cut rectangle unchanged.
    static func fillRect(_ rect: CGRect, toDevice: CGAffineTransform, clip: CGRect) -> CGRect {
        guard let cut = edges(of: rect, cutTo: clip) else { return .null }
        // A transform that turns or shears gets the cut rectangle unchanged;
        // the drawing pass asserts that its own transform is axis-aligned.
        guard isAxisAligned(toDevice), let lines = deviceLines(rect, toDevice: toDevice, clip: clip) else {
            return CGRect(x: cut.x0, y: cut.y0, width: cut.x1 - cut.x0, height: cut.y1 - cut.y0)
        }
        let t = toDevice
        let xs = [(CGFloat(lines.x0) - t.tx) / t.a, (CGFloat(lines.x1) - t.tx) / t.a]
        let ys = [(CGFloat(lines.y0) - t.ty) / t.d, (CGFloat(lines.y1) - t.ty) / t.d]
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// The four edges of `rect` cut to `clip`, each taken as the nearer of
    /// the two: nil when nothing is left.
    private static func edges(of rect: CGRect, cutTo clip: CGRect)
        -> (x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat)? {
        guard !rect.isNull, !clip.isNull else { return nil }
        let r = rect.standardized, c = clip.standardized
        let x0 = max(r.origin.x, c.origin.x), y0 = max(r.origin.y, c.origin.y)
        let x1 = min(r.origin.x + r.size.width, c.origin.x + c.size.width)
        let y1 = min(r.origin.y + r.size.height, c.origin.y + c.size.height)
        guard x1 > x0, y1 > y0 else { return nil }
        return (x0, y0, x1, y1)
    }

    /// True when the transform neither turns nor shears: `b` and `c` are at
    /// most a billionth of the larger of `a` and `d`.
    static func isAxisAligned(_ t: CGAffineTransform) -> Bool {
        let scale = max(abs(t.a), abs(t.d))
        return scale > 0 && abs(t.b) <= 1e-9 * scale && abs(t.c) <= 1e-9 * scale
    }

    /// A value a hair from a whole number is taken as that number, so a
    /// floor or a ceiling does not move a true pixel line by a whole pixel.
    private static func onLine(_ v: CGFloat) -> CGFloat {
        let r = v.rounded()
        return abs(v - r) <= 1e-9 * max(1, abs(v)) ? r : v
    }
}
