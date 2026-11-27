/// The pixel step's arithmetic: a page side in whole sixty-fourths of a
/// point, the raster a page has at a quality, and the one rectangle a box is
/// painted as. Every step after the one that reads a side is whole-number
/// arithmetic, so the code that paints, the preview and the check can each
/// work a box out and get the same pixels.
package enum PixelPlan {
    /// Sixty-fourths of a point in an inch: 64 × 72.
    package static let sixtyFourthsPerInch = 4_608

    /// How far above a whole sixty-fourth a side may be read and still count
    /// as that sixty-fourth, in sixty-fourths: 2⁻¹⁶. It covers a hair from
    /// double arithmetic on a page-sized number and nothing larger.
    package static let sideTolerance: Double = 0x1p-16

    /// A page side of `points`, as the engine reads it, in whole sixty-fourths
    /// of a point: ⌈64·s − 2⁻¹⁶⌉. This is the one place a side is read for
    /// pixel arithmetic; everything after it reads the result. Both steps are
    /// exact for any side under 2³⁰ points. Nil for a side that is not a
    /// positive finite number.
    package static func sixtyFourths(ofSide points: Double) -> Int? {
        guard points.isFinite, points > 0, points < 0x1p30 else { return nil }
        return Int((64 * points - sideTolerance).rounded(.up))
    }

    /// A page's raster at a quality: the page's two sides in whole
    /// sixty-fourths (in the frame as it is rasterised) and the dots per inch.
    package struct Raster: Hashable, Sendable {
        package let widthSixtyFourths: Int
        package let heightSixtyFourths: Int
        package let dpi: Int

        /// Nil unless both sides and the dots per inch are positive.
        package init?(widthSixtyFourths: Int, heightSixtyFourths: Int, dpi: Int) {
            guard widthSixtyFourths > 0, heightSixtyFourths > 0, dpi > 0 else { return nil }
            self.widthSixtyFourths = widthSixtyFourths
            self.heightSixtyFourths = heightSixtyFourths
            self.dpi = dpi
        }

        /// ⌈S·d / 4608⌉: the raster never crops the page.
        package var pixelWidth: Int { ceilDiv(widthSixtyFourths * dpi, sixtyFourthsPerInch) }
        package var pixelHeight: Int { ceilDiv(heightSixtyFourths * dpi, sixtyFourthsPerInch) }

        /// The last whole pixel line at or before a coordinate of `x`
        /// sixty-fourths, which lies at x·d / 4608 pixels from the bottom-left.
        func pixelFloor(_ x: Int) -> Int { floorDiv(x * dpi, sixtyFourthsPerInch) }
        /// The first whole pixel line at or after a coordinate of `x` sixty-fourths.
        func pixelCeil(_ x: Int) -> Int { ceilDiv(x * dpi, sixtyFourthsPerInch) }
    }

    /// A rectangle of whole pixels: columns `minX..<maxX` and rows
    /// `minY..<maxY`, with the origin at the image's bottom-left corner and
    /// rows counted from the bottom.
    package struct PixelRect: Hashable, Sendable {
        package var minX: Int
        package var minY: Int
        package var maxX: Int
        package var maxY: Int

        package init(minX: Int, minY: Int, maxX: Int, maxY: Int) {
            self.minX = minX
            self.minY = minY
            self.maxX = maxX
            self.maxY = maxY
        }

        package var isEmpty: Bool { maxX <= minX || maxY <= minY }
    }

    /// What `project` gives for a box.
    package struct Projection: Hashable, Sendable {
        /// The rectangle the box is painted as.
        package let painted: PixelRect
        /// The margin's edge alone: `paint` rounded outward to whole pixels,
        /// plus one pixel, held at the limit lines, clipped to the image. It
        /// never lies outside `painted`.
        package let marginEdge: PixelRect
    }

    /// The one rectangle a box is painted as, in the image of `raster`.
    ///
    /// Each side is the further out of two edges:
    /// - the margin's edge: that side of `paint` rounded outward to a whole
    ///   pixel, plus one pixel; on a side with a limit line it is then held at
    ///   the limit, so it never lies past the last whole pixel row on the
    ///   box's own side of the line (the extra pixel first, the hold last);
    /// - the block edge: the grid line, or the image's edge, that encloses
    ///   `inner` on that side. It is never pulled back by a limit.
    ///
    /// Grid lines stand every `grid` pixels from the image's left edge and
    /// from its top edge, so a block cut by the right or the bottom edge ends
    /// at the image's edge. `limitAbove` and `limitBelow` are heights in
    /// whole sixty-fourths in the same frame as the box: the line above the
    /// box's line of text and the line below it, absent where none
    /// neighbours the box. A hand-drawn box has `paint` equal to `inner` and
    /// no limits. The result is clipped to the image.
    ///
    /// Nil when `inner` has no area, or when nothing of the box lies on the
    /// image.
    package static func project(
        inner: PageRect64, paint: PageRect64,
        limitAbove: Int?, limitBelow: Int?,
        raster: Raster, grid: Int = 8
    ) -> Projection? {
        guard !inner.isEmpty, grid > 0 else { return nil }
        let width = raster.pixelWidth
        let height = raster.pixelHeight

        // The margin's edge: outward to whole pixels, then one pixel more.
        var marginLeft = raster.pixelFloor(paint.minX) - 1
        var marginRight = raster.pixelCeil(paint.maxX) + 1
        var marginBottom = raster.pixelFloor(paint.minY) - 1
        var marginTop = raster.pixelCeil(paint.maxY) + 1
        // Then held at the limits: no row past the line on the box's side.
        if let above = limitAbove { marginTop = min(marginTop, raster.pixelFloor(above)) }
        if let below = limitBelow { marginBottom = max(marginBottom, raster.pixelCeil(below)) }

        // The block edge: the grid line that encloses `inner` on each side.
        // Columns count from the left edge; rows from the top edge, which is
        // `height` pixels above the bottom.
        let innerLeft = raster.pixelFloor(inner.minX)
        let innerRight = raster.pixelCeil(inner.maxX)
        let innerBottom = raster.pixelFloor(inner.minY)
        let innerTop = raster.pixelCeil(inner.maxY)
        let blockLeft = floorDiv(innerLeft, grid) * grid
        let blockRight = ceilDiv(innerRight, grid) * grid
        let blockTop = height - floorDiv(height - innerTop, grid) * grid
        let blockBottom = height - ceilDiv(height - innerBottom, grid) * grid

        func clipX(_ x: Int) -> Int { min(max(x, 0), width) }
        func clipY(_ y: Int) -> Int { min(max(y, 0), height) }

        let painted = PixelRect(
            minX: clipX(min(marginLeft, blockLeft)),
            minY: clipY(min(marginBottom, blockBottom)),
            maxX: clipX(max(marginRight, blockRight)),
            maxY: clipY(max(marginTop, blockTop))
        )
        guard !painted.isEmpty else { return nil }

        marginLeft = clipX(marginLeft)
        marginRight = clipX(marginRight)
        marginBottom = clipY(marginBottom)
        marginTop = clipY(marginTop)
        let margin = PixelRect(
            minX: marginLeft, minY: marginBottom,
            maxX: max(marginRight, marginLeft), maxY: max(marginTop, marginBottom)
        )
        return Projection(painted: painted, marginEdge: margin)
    }

    /// `rect`, a pixel rectangle of this page's image at `shownDPI`, on
    /// `raster`'s image of the same page: each side carried outward to a whole
    /// pixel, within the image.
    ///
    /// Both images share the page's bottom-left corner, and a pixel
    /// rectangle counts columns from the left and rows from the bottom, so a
    /// line `y` pixels up one image lies `y · d / s` pixels up the other,
    /// exactly: the left and bottom sides are ⌊v · d / s⌋, the right and top
    /// ⌈v · d / s⌉, for the run's `d = raster.dpi` and the shown `s`. No image
    /// height and no block line enters it. The carried rectangle holds every
    /// page point the shown one holds, and the clip to the image drops none:
    /// the image never crops the page. A non-positive `shownDPI` carries
    /// nothing: the rectangle comes back as it is, cut to the image.
    package static func carried(_ rect: PixelRect, shownDPI: Int, onto raster: Raster) -> PixelRect {
        func clipX(_ x: Int) -> Int { min(max(x, 0), raster.pixelWidth) }
        func clipY(_ y: Int) -> Int { min(max(y, 0), raster.pixelHeight) }
        guard shownDPI > 0 else {
            return PixelRect(minX: clipX(rect.minX), minY: clipY(rect.minY),
                             maxX: clipX(rect.maxX), maxY: clipY(rect.maxY))
        }
        let d = raster.dpi
        return PixelRect(
            minX: clipX(floorDiv(rect.minX * d, shownDPI)),
            minY: clipY(floorDiv(rect.minY * d, shownDPI)),
            maxX: clipX(ceilDiv(rect.maxX * d, shownDPI)),
            maxY: clipY(ceilDiv(rect.maxY * d, shownDPI))
        )
    }
}

/// ⌊a / b⌋ for a positive `b`, for any sign of `a`.
private func floorDiv(_ a: Int, _ b: Int) -> Int {
    let q = a / b
    return (a % b != 0 && a < 0) ? q - 1 : q
}

/// ⌈a / b⌉ for a positive `b`, for any sign of `a`.
private func ceilDiv(_ a: Int, _ b: Int) -> Int {
    let q = a / b
    return (a % b != 0 && a > 0) ? q + 1 : q
}
