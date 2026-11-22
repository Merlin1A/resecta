import CoreGraphics
import Foundation
import os

// The pixel step's second half: the page's raster read from the page's data,
// and the plan's boxes painted, read back and reported. The arithmetic is the
// core's (`PixelPlan`); this file only applies it to a rendered bitmap.

/// A runtime fallback of this file, logged as the rasterizer logs its own:
/// the page index and the reason only, never document content.
private let planLogger = Logger(subsystem: "com.resecta.engine", category: "PageRasterizer")

/// A page's pixels at its quality: the raster's size, the span its content
/// takes on it, and the raster of its plan when the producer paints the plan.
struct PagePixels: Sendable, Equatable {
    /// The raster's size in pixels: ⌈S·d / 4608⌉ on each side.
    let width: Int
    let height: Int
    /// The pixels the page's content spans on each side: S·d / 4608.
    let content: CGSize
    /// The raster the plan's boxes are projected on. Nil on the region path
    /// (a page with no record) and for a page whose record disagrees.
    let plan: PixelPlan.Raster?
    /// The page has a record, but its sides are not the page's own (or the
    /// record made no plan): the pre-flight refuses the page by name
    /// (`pageSidesNotAsRecorded`) before it is rendered.
    let recordDisagrees: Bool
}

/// What the producer painted on a page: each box's rectangle by its place in
/// the plan, and the regions it painted that no box of the plan holds.
struct PlanPaint: Sendable, Equatable {
    var painted: [Int: PixelPlan.PixelRect] = [:]
    var outsidePlan: Set<UUID> = []
    /// The ink check's verdict for each box it was asked about, by the box's
    /// place in the plan. Empty at "as placed".
    var inkVerdicts: [Int: InkCheck.Verdict] = [:]
    /// Some box was made larger by the ink check.
    var inkWidened: Bool { !inkWidenedBoxes.isEmpty }
    var inkWidenedBoxes: Set<Int> = []
}

/// The ink check's inputs for one box of a page's plan.
package struct InkCheckInputs: Hashable, Sendable {
    /// The height of the box's line of text, in sixty-fourths of a point.
    package var lineHeight: Int
    /// The boxes of the page's words the box does not cover.
    package var others: [PageRect64]

    package init(lineHeight: Int, others: [PageRect64]) {
        self.lineHeight = lineHeight
        self.others = others
    }
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
    /// A box is painted as ONE rectangle: each side the furthest out of the
    /// box's projection, each region it holds as the region path fills that
    /// region, and its growth. So a box never paints less than the region
    /// path did: for a region past the page's left or bottom edge, the run's
    /// clamp slides it onto the page whole, and the region path painted that. Growth starts from the margin's edge
    /// alone (`paint` outward to whole pixels plus one, clipped), so it fires
    /// where it fired before the pixel step, and only for a box holding a
    /// region placed by Search or by detection.
    ///
    /// A region with no box (the plan's admission and the run's disagreeing),
    /// or held only by a box that does not project, is never left unpainted:
    /// it is filled as the region path fills it and returned in
    /// `outsidePlan`, which the record carries to the box check
    /// (`ExactFillCheck`), where each is its own unit it cannot judge.
    func paintPlan(context ctx: CGContext, page: PDFPageData, raster: PixelPlan.Raster,
                   content: CGSize) throws -> PlanPaint {
        let bitmap = CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height)
        var regionsByID: [UUID: RedactionRegion] = [:]
        var growsOnInk: [UUID: Bool] = [:]
        for region in page.regions {
            regionsByID[region.id] = region
            growsOnInk[region.id] = inkGrowthApplies(to: region)
        }

        // 4c. Each box's projection, with its regions as the region path
        // fills them, then its growth, read before any fill.
        // At the switch's policy a Search or Scan box the plan marks checkable
        // takes the ink check in place of growth. A box the check cannot
        // judge (no inputs, or `indeterminate`) is painted as at "as placed",
        // growth and all: the check only ever adds paint. A judged box keeps
        // its regions' own fills too, so no box paints less than the region
        // path did.
        var rects: [(box: Int, rect: CGRect)] = []
        var painted = Set<UUID>()
        var verdicts: [Int: InkCheck.Verdict] = [:]
        var widened: Set<Int> = []
        let atSwitch = page.planSource == .switchPolicy
        var grid: InkCheck.Grid?
        func withRegionFills(_ rect: CGRect, of box: PaintedBox) -> CGRect {
            var rect = rect
            for id in box.regionIDs {
                guard let region = regionsByID[id] else { continue }
                let filled = normalizedToFillPixels(region.normalizedRect, content: content).intersection(bitmap)
                if !filled.isEmpty { rect = rect.union(filled) }
            }
            return rect
        }
        for (index, box) in page.boxes.enumerated() {
            let grows = box.regionIDs.contains(where: { growsOnInk[$0] == true })
            // Only a box the plan marks checkable: placed from typed text,
            // still anchored, not painted as drawn. A box placed from the
            // page's picture is never judged.
            if atSwitch, grows, !box.asDrawn, box.inkCheckable {
                var verdict = InkCheck.Verdict.indeterminate
                if let inputs = page.inkCheckInputs[index] {
                    if grid == nil { grid = Self.greyGrid(context: ctx) }
                    if let grid {
                        let result = InkCheck.evaluate(box: box, lineHeight: inputs.lineHeight,
                                                       others: inputs.others, grid: grid, raster: raster)
                        verdict = result.verdict
                        let checked = box.applying(result)
                        if verdict != .indeterminate,
                           let projection = PixelPlan.project(
                               inner: checked.inner, paint: checked.paint, limitAbove: checked.limitAbove,
                               limitBelow: checked.limitBelow, raster: raster) {
                            verdicts[index] = verdict
                            if checked.inkEnlargedCovered || checked.inkEnlargedToCap { widened.insert(index) }
                            rects.append((index, withRegionFills(projection.painted.bitmapRect, of: box)))
                            painted.formUnion(box.regionIDs)
                            continue
                        }
                    }
                }
                // Not judged: painted as at "as placed", below.
                verdicts[index] = .indeterminate
            }
            guard let projection = PixelPlan.project(
                inner: box.inner, paint: box.paint,
                limitAbove: box.limitAbove, limitBelow: box.limitBelow, raster: raster) else { continue }
            var rect = projection.painted.bitmapRect
            rect = withRegionFills(rect, of: box)
            painted.formUnion(box.regionIDs)
            if grows,
               let grown = try inkGrowthRect(context: ctx, fillRect: projection.marginEdge.bitmapRect) {
                rect = rect.union(grown)
            }
            rects.append((index, rect))
        }
        let strays = page.regions.filter { !painted.contains($0.id) }
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
        result.inkVerdicts = verdicts
        result.inkWidenedBoxes = widened
        return result
    }

    /// The page's text layer dropped after the render and the fills, when
    /// a box the ink check widened leaves the text-layer copies of its words
    /// outside the box as placed: the page takes the secure path with
    /// `reason`, through the text layer's one drop. Nothing to drop on a page
    /// that has no text layer, or one already dropped.
    static func dropTextLayer(_ textLayer: inout TextLayerState, reason: TextLayerDetector.FallbackReason,
                              page: PDFPageData) {
        guard textLayer.entries != nil else { return }
        textLayer.drop(reason: reason)
        planLogger.log(
            "page \(page.pageIndex) fell back to secure rasterization at runtime (\(String(describing: reason), privacy: .public))"
        )
    }

    /// The bitmap as grey values before any fill, rows from the bottom, as
    /// the ink check reads a page. Nil when the bitmap has no data.
    static func greyGrid(context ctx: CGContext) -> InkCheck.Grid? {
        guard let data = ctx.data else { return nil }
        let buffer = data.assumingMemoryBound(to: UInt8.self)
        let width = ctx.width, height = ctx.height, bytesPerRow = ctx.bytesPerRow
        var values = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            // The bitmap's memory runs from its top row; the grid's from its bottom.
            let row = buffer + (height - 1 - y) * bytesPerRow
            for x in 0..<width {
                // 32-bit little-endian, alpha first: blue, green, red, alpha in memory.
                let p = row + x * 4
                values[y * width + x] = UInt8((Int(p[2]) * 77 + Int(p[1]) * 150 + Int(p[0]) * 29) >> 8)
            }
        }
        return InkCheck.Grid(width: width, height: height, values: values)
    }
}
