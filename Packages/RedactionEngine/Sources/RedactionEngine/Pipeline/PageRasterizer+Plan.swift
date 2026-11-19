import CoreGraphics
import Foundation

// The pixel step's second half: the page's raster read from the page's data,
// and the plan's boxes painted, read back and reported. The arithmetic is the
// core's (`PixelPlan`); this file only applies it to a rendered bitmap.

/// A page's pixels at its quality: the raster's size, the span its content
/// takes on it, and the raster of its plan when the producer paints the plan.
struct PagePixels: Sendable, Equatable {
    /// The raster's size in pixels: ⌈S·d / 4608⌉ on each side.
    let width: Int
    let height: Int
    /// The pixels the page's content spans on each side: S·d / 4608.
    let content: CGSize
    /// The raster the plan's boxes are projected on. Nil on the region path:
    /// a page with no record, or one whose record disagrees with the page.
    let plan: PixelPlan.Raster?
    /// The page has a record, but its sides are not the page's own (or the
    /// record made no plan): the page takes the region path and every region
    /// on it is recorded as painted outside the plan.
    let recordDisagrees: Bool
}

/// What the producer painted on a page: each box's rectangle by its place in
/// the plan, and the regions it painted that no box of the plan holds.
struct PlanPaint: Sendable, Equatable {
    var painted: [Int: PixelPlan.PixelRect] = [:]
    var outsidePlan: Set<UUID> = []
}

extension PixelPlan.PixelRect {
    /// The same pixels as a bitmap rectangle, origin bottom-left.
    var bitmapRect: CGRect { CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY) }

    /// A bitmap rectangle of whole pixels (as the fills hand out), as pixels.
    init(bitmapRect r: CGRect) {
        self.init(minX: Int(r.minX), minY: Int(r.minY), maxX: Int(r.maxX), maxY: Int(r.maxY))
    }
}

extension PageRasterizer {
    #if DEBUG
    /// Test seam: runs on the bitmap after the plan's fills and before their
    /// readback, so a test can unpaint a pixel the readback then reads as unpainted.
    @TaskLocal static var afterPlanFills: (@Sendable (CGContext) -> Void)?
    #endif

    /// The one place the render stage settles a page's pixels. The
    /// page's two sides S come from its data, as the run's record made them
    /// at entry; the side function reads the crop box only to confirm them,
    /// and, for a page with no record, to make them. Nil for a side or a DPI
    /// the raster rule refuses.
    static func pagePixels(_ page: PDFPageData, dpi: Int) -> PagePixels? {
        pagePixels(cropBox: page.cropBoxBounds, rotation: page.rotation, hasRecord: page.confirmedPage != nil,
                   recorded: page.sidesSixtyFourths, dpi: dpi)
    }

    /// `pagePixels(_:dpi:)` on the page's geometry and its record's sides.
    static func pagePixels(cropBox: CGRect, rotation: Int, hasRecord: Bool,
                           recorded: (width: Int, height: Int)?, dpi: Int) -> PagePixels? {
        let size = effectiveBounds(cropBox, rotation: rotation).size
        guard let ownWidth = PixelPlan.sixtyFourths(ofSide: Double(size.width)),
              let ownHeight = PixelPlan.sixtyFourths(ofSide: Double(size.height)) else { return nil }
        var sides = (width: ownWidth, height: ownHeight)
        var fromRecord = false
        var disagrees = false
        if hasRecord {
            if let recorded, recorded == sides {
                sides = recorded
                fromRecord = true
            } else {
                disagrees = true
            }
        }
        guard let raster = PixelPlan.Raster(
            widthSixtyFourths: sides.width, heightSixtyFourths: sides.height, dpi: dpi) else { return nil }
        return PagePixels(
            width: raster.pixelWidth, height: raster.pixelHeight,
            content: CGSize(width: contentSpan(sides.width, dpi: dpi), height: contentSpan(sides.height, dpi: dpi)),
            plan: fromRecord ? raster : nil,
            recordDisagrees: disagrees)
    }

    /// The raster's size by the raster rule (`PixelPlan`) from the crop box:
    /// each side in whole sixty-fourths, then ⌈S·d / 4608⌉ pixels. For a
    /// render with no page data (the search's own render, tests). Nil for a
    /// refused side or DPI.
    static func rasterPixelSize(bounds: CGRect, rotation: Int, dpi: CGFloat) -> (width: Int, height: Int)? {
        let size = effectiveBounds(bounds, rotation: rotation).size
        guard dpi.rounded() == dpi,
              let w = PixelPlan.sixtyFourths(ofSide: Double(size.width)),
              let h = PixelPlan.sixtyFourths(ofSide: Double(size.height)),
              let raster = PixelPlan.Raster(widthSixtyFourths: w, heightSixtyFourths: h, dpi: Int(dpi))
        else { return nil }
        return (raster.pixelWidth, raster.pixelHeight)
    }

    /// The pixels the page's content spans on each side of that raster, by
    /// the same rule: S·d / 4608 for a side of S sixty-fourths. It is at most
    /// d / 4608 px past side × dpi / 72 (the span the content is drawn at),
    /// and under one pixel short of the raster. Nil where `rasterPixelSize` is.
    static func rasterContentSize(bounds: CGRect, rotation: Int, dpi: CGFloat) -> CGSize? {
        let size = effectiveBounds(bounds, rotation: rotation).size
        guard dpi.rounded() == dpi,
              let w = PixelPlan.sixtyFourths(ofSide: Double(size.width)),
              let h = PixelPlan.sixtyFourths(ofSide: Double(size.height)),
              PixelPlan.Raster(widthSixtyFourths: w, heightSixtyFourths: h, dpi: Int(dpi)) != nil
        else { return nil }
        return CGSize(width: contentSpan(w, dpi: Int(dpi)), height: contentSpan(h, dpi: Int(dpi)))
    }

    /// The pixels the page's content spans on a side of `s` sixty-fourths
    /// at `dpi`: S·d / 4608, the one place the content basis is worked out.
    static func contentSpan(_ s: Int, dpi: Int) -> Double {
        Double(s) * Double(dpi) / Double(PixelPlan.sixtyFourthsPerInch)
    }

    // MARK: - The region path: a page with no plan

    /// The ink growth read, the fills, then each growth rectangle filled and
    /// read back. Runs after the ink test and before `readBack`.
    func paint(context ctx: CGContext, page: PDFPageData, content: CGSize) throws {
        // 4c. Ink growth, read on the rendered page before any fill: a
        // text-derived fill grows over the ink that crosses its edge.
        let growth = try inkGrowthRects(context: ctx, regions: page.regions, content: content)

        // 5. Apply fills on the content basis.
        // 256-row band cancellation checks happen inside.
        try applyRedactionFills(
            context: ctx, regions: page.regions, fillColor: page.fillColor, content: content
        )
        for rect in growth {
            ctx.setBlendMode(.copy); ctx.setShouldAntialias(false)
            ctx.setFillColor(page.fillColor.cgColor); ctx.fill(rect)
            guard try verifyFill(context: ctx, rect: rect, expectedColor: page.fillColor.expectedPixel) else {
                throw PipelineError.redactionError(.fillVerificationFailed(pageIndex: page.pageIndex))
            }
        }
    }

    /// Every region's fill read back over its clamped pixel rectangle.
    func readBack(context ctx: CGContext, page: PDFPageData, width: Int, height: Int, content: CGSize) throws {
        // 6. Verify fills, on the basis they were painted on. 256-row band
        // cancellation checks happen inside; a thrown CancellationError propagates here.
        for region in page.regions {
            let pixelRect = normalizedToFillPixels(region.normalizedRect, content: content)
            // Clamp to bitmap bounds
            let clamped = pixelRect.intersection(
                CGRect(x: 0, y: 0, width: width, height: height)
            )
            guard !clamped.isEmpty else { continue }
            let verifyPassed = try verifyFill(
                context: ctx, rect: clamped,
                expectedColor: page.fillColor.expectedPixel
            )
            guard verifyPassed else {
                // Fill verification failed — the redaction fill did
                // not produce the expected pixel values across the entire region.
                throw PipelineError.redactionError(
                    .fillVerificationFailed(pageIndex: page.pageIndex)
                )
            }
        }
    }

    // MARK: - The plan path

    /// The plan's boxes painted, with any region no box
    /// holds painted on its own as the region path paints it. In this
    /// order: every growth read on the rendered page before any fill, then
    /// the fills, then the readback of exactly what was filled.
    ///
    /// A box is painted as ONE rectangle: each side the further out of the
    /// box's projection and its growth. Growth starts from the margin's edge
    /// alone (`paint` outward to whole pixels plus one, clipped), so it fires
    /// where it fired before the pixel step, and only for a box holding a
    /// region placed by Search or by detection.
    ///
    /// A region with no box (the plan's admission and the run's disagreeing)
    /// is never left unpainted: it is filled as the region path fills it and
    /// returned in `outsidePlan`, which the record carries to the position
    /// check as "could not be checked".
    func paintPlan(context ctx: CGContext, page: PDFPageData, raster: PixelPlan.Raster,
                   content: CGSize) throws -> PlanPaint {
        let boxed = Set(page.boxes.flatMap(\.regionIDs))
        let strays = page.regions.filter { !boxed.contains($0.id) }
        var growsOnInk: [UUID: Bool] = [:]
        for region in page.regions { growsOnInk[region.id] = inkGrowthApplies(to: region) }

        // 4c. Each box's projection, then its growth, read before any fill.
        var rects: [(box: Int, rect: CGRect)] = []
        for (index, box) in page.boxes.enumerated() {
            guard let projection = PixelPlan.project(
                inner: box.inner, paint: box.paint,
                limitAbove: box.limitAbove, limitBelow: box.limitBelow, raster: raster) else { continue }
            var rect = projection.painted.bitmapRect
            if box.regionIDs.contains(where: { growsOnInk[$0] == true }),
               let grown = try inkGrowthRect(context: ctx, fillRect: projection.marginEdge.bitmapRect) {
                rect = rect.union(grown)
            }
            rects.append((index, rect))
        }
        let strayGrowth = try inkGrowthRects(context: ctx, regions: strays, content: content)

        // 5. The fills.
        for (_, rect) in rects {
            try fillInBands(context: ctx, rect: rect, fillColor: page.fillColor)
        }
        try applyRedactionFills(context: ctx, regions: strays, fillColor: page.fillColor, content: content)
        for rect in strayGrowth {
            try fillInBands(context: ctx, rect: rect, fillColor: page.fillColor)
        }

        #if DEBUG
        Self.afterPlanFills?(ctx)
        #endif

        // 6. The readback, of the rectangles filled.
        let bitmap = CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height)
        let filled = rects.map(\.rect)
            + strays.map { normalizedToFillPixels($0.normalizedRect, content: content).intersection(bitmap) }
            + strayGrowth
        for rect in filled where !rect.isEmpty {
            guard try verifyFill(context: ctx, rect: rect, expectedColor: page.fillColor.expectedPixel) else {
                throw PipelineError.redactionError(.fillVerificationFailed(pageIndex: page.pageIndex))
            }
        }

        var result = PlanPaint()
        for (box, rect) in rects { result.painted[box] = PixelPlan.PixelRect(bitmapRect: rect) }
        result.outsidePlan = Set(strays.map(\.id))
        return result
    }
}
