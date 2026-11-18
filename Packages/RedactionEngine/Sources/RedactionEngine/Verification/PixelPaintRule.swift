import Foundation

/// The box check's own copy of the rule that says which pixels a box paints.
/// Every value is a whole number: sixty-fourths of a point in, pixels out.
/// Nothing here is shared with the code that paints; the two are written from
/// the same rule, and a test compares them.
enum PixelPaintRule {
    /// Sixty-fourths of a point in an inch.
    static let sixtyFourthsPerInch = 4608
    /// The side of a coded block, in pixels.
    static let blockSide = 8
    /// The qualities a page can be exported at, tried in this order.
    static let qualities = [150, 200, 300]

    /// ⌊a / b⌋ for b > 0, toward minus infinity for a negative a too.
    static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        return (a % b != 0 && a < 0) ? q - 1 : q
    }

    /// ⌈a / b⌉ for b > 0.
    static func ceilDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        return (a % b != 0 && a > 0) ? q + 1 : q
    }

    /// ⌊X × d / 4608⌋: a coordinate in sixty-fourths at quality d, in pixels, rounded down.
    static func floorPixels(_ x: Int, dpi d: Int) -> Int { floorDiv(x * d, sixtyFourthsPerInch) }

    /// ⌈X × d / 4608⌉, rounded up.
    static func ceilPixels(_ x: Int, dpi d: Int) -> Int { ceilDiv(x * d, sixtyFourthsPerInch) }

    /// The frame's side in pixels the rule gives a page side S at quality d.
    static func frameSide(_ s: Int, dpi d: Int) -> Int { ceilPixels(s, dpi: d) }

    /// The page's quality: the first of 150, 200, 300, none above the chosen
    /// one, whose frame matches the image's width and height both. Nil when
    /// none does.
    static func pageQuality(widthSixtyFourths sw: Int, heightSixtyFourths sh: Int,
                            frameWidth w: Int, frameHeight h: Int, chosen: Int) -> Int? {
        qualities.first { $0 <= chosen && frameSide(sw, dpi: $0) == w && frameSide(sh, dpi: $0) == h }
    }

    /// A rectangle of pixel lines in the image's frame: columns from the left
    /// edge, rows from the top edge; `right` and `bottom` are the lines past
    /// the last column and row.
    struct Lines: Hashable, Sendable {
        var left: Int
        var top: Int
        var right: Int
        var bottom: Int

        var isEmpty: Bool { left >= right || top >= bottom }

        /// The same rectangle held inside a W by H image.
        func clipped(width w: Int, height h: Int) -> Lines {
            Lines(left: max(left, 0), top: max(top, 0), right: min(right, w), bottom: min(bottom, h))
        }

        func contains(_ o: Lines) -> Bool {
            left <= o.left && top <= o.top && right >= o.right && bottom >= o.bottom
        }
    }

    /// A rectangle in sixty-fourths, its edges in pixels rounded outward:
    /// left and the bottom row down from the rectangle, right and the top row up.
    static func outward(_ r: PageRect64, dpi d: Int, imageHeight h: Int) -> Lines {
        Lines(left: floorPixels(r.minX, dpi: d), top: h - ceilPixels(r.maxY, dpi: d),
              right: ceilPixels(r.maxX, dpi: d), bottom: h - floorPixels(r.minY, dpi: d))
    }

    /// A line moved out to the next 8-pixel line below or at it (toward 0).
    static func downToBlock(_ v: Int) -> Int { floorDiv(v, blockSide) * blockSide }

    /// A line moved out to the next 8-pixel line above or at it.
    static func upToBlock(_ v: Int) -> Int { ceilDiv(v, blockSide) * blockSide }

    /// The unit: `inner`'s lines clipped to the image, then each moved out to
    /// the next 8-pixel line or the image's edge, whichever comes first. Nil
    /// when `inner` maps to no pixel of the image.
    static func unit(inner: PageRect64, dpi d: Int, width w: Int, height h: Int) -> Lines? {
        let c = outward(inner, dpi: d, imageHeight: h).clipped(width: w, height: h)
        guard !c.isEmpty else { return nil }
        return Lines(left: downToBlock(c.left), top: downToBlock(c.top),
                     right: min(upToBlock(c.right), w), bottom: min(upToBlock(c.bottom), h))
    }

    /// The pixel paint: each side the further out of the margin's edge (one
    /// pixel past `paint`, then held at a limit line) and the block edge
    /// (`inner`'s lines, not clipped, moved out to 8-pixel lines; never held);
    /// then clipped to the image.
    static func pixelPaint(inner: PageRect64, paint: PageRect64, limitAbove: Int?, limitBelow: Int?,
                           dpi d: Int, width w: Int, height h: Int) -> Lines {
        let p = outward(paint, dpi: d, imageHeight: h)
        var margin = Lines(left: p.left - 1, top: p.top - 1, right: p.right + 1, bottom: p.bottom + 1)
        if let a = limitAbove { margin.top = max(margin.top, h - floorPixels(a, dpi: d)) }
        if let b = limitBelow { margin.bottom = min(margin.bottom, h - ceilPixels(b, dpi: d)) }
        let i = outward(inner, dpi: d, imageHeight: h)
        let block = Lines(left: downToBlock(i.left), top: downToBlock(i.top),
                          right: upToBlock(i.right), bottom: upToBlock(i.bottom))
        return Lines(left: min(margin.left, block.left), top: min(margin.top, block.top),
                     right: max(margin.right, block.right), bottom: max(margin.bottom, block.bottom))
            .clipped(width: w, height: h)
    }

    /// The rectangle the producer reports, in the image's frame. This is the
    /// one place the check reads a row counted from the image's bottom edge.
    /// Nil when it spans no pixel or any of its lines lies outside the image.
    static func reported(_ p: RunRecord.PaintedPixels, width w: Int, height h: Int) -> Lines? {
        guard p.columns >= 1, p.rows >= 1 else { return nil }
        let r = Lines(left: p.firstColumn, top: h - (p.firstRowFromBottom + p.rows),
                      right: p.firstColumn + p.columns, bottom: h - p.firstRowFromBottom)
        guard r.left >= 0, r.top >= 0, r.right <= w, r.bottom <= h else { return nil }
        return r
    }
}
