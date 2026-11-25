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
    /// The boxes painted with their line margin in place of their default
    /// band: the page's picture showed ink in the band's slot.
    var defaultsWithdrawn: Set<Int> = []
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

    /// On each side the further out of this rectangle and `other`.
    func joined(with other: PixelPlan.PixelRect) -> PixelPlan.PixelRect {
        PixelPlan.PixelRect(minX: min(minX, other.minX), minY: min(minY, other.minY),
                            maxX: max(maxX, other.maxX), maxY: max(maxY, other.maxY))
    }

    /// A bitmap rectangle of whole pixels (as the fills hand out), as pixels.
    init(bitmapRect r: CGRect) {
        self.init(minX: Int(r.minX), minY: Int(r.minY), maxX: Int(r.maxX), maxY: Int(r.maxY))
    }
}

extension PageRasterizer {
    /// A box's fill before ink growth at "as placed", the one rule the run
    /// paints a box by there and the editor's kept plan reads: its projection
    /// on the raster, joined with each of its regions as the region path
    /// fills it, within the bitmap. At the switch's policy a box the ink
    /// check judges is painted with this as its floor, so the run never
    /// paints less than this. Nil when the box does not project; the run
    /// then fills its regions as strays, each by the region path.
    ///
    /// `shownDPI` is the quality the page was last shown at. With one that
    /// differs from the raster's, the fill is joined with the fill shown
    /// there, carried onto this raster (`shownFill`): on each side the
    /// further out of the two. With none, or the raster's own, it is the
    /// fill at this quality alone. Only the run passes it; the kept plan
    /// reads the fill at its own quality.
    package static func boxFill(box: PaintedBox, regions: [UUID: RedactionRegion], raster: PixelPlan.Raster,
                                content: CGSize, shownDPI: Int? = nil) -> PixelPlan.PixelRect? {
        boxFillAndProjection(box: box, regions: regions, raster: raster, content: content, shownDPI: shownDPI)?.fill
    }

    /// `boxFill` with the projection it was made from (the run's growth reads
    /// the projection's margin edge, which the join leaves as it is).
    static func boxFillAndProjection(box: PaintedBox, regions: [UUID: RedactionRegion], raster: PixelPlan.Raster,
                                     content: CGSize, shownDPI: Int? = nil)
        -> (fill: PixelPlan.PixelRect, projection: PixelPlan.Projection)? {
        guard let own = ownFillAndProjection(box: box, regions: regions, raster: raster, content: content)
        else { return nil }
        guard let shown = shownFill(box: box, regions: regions, raster: raster, shownDPI: shownDPI)
        else { return own }
        return (own.fill.joined(with: shown), own.projection)
    }

    /// The raster of the same page at `shownDPI`, with its content span, when
    /// that quality differs from `raster`'s. Nil otherwise.
    static func shownRaster(of raster: PixelPlan.Raster, shownDPI: Int?)
        -> (raster: PixelPlan.Raster, content: CGSize)? {
        guard let shownDPI, shownDPI != raster.dpi,
              let shown = PixelPlan.Raster(widthSixtyFourths: raster.widthSixtyFourths,
                                           heightSixtyFourths: raster.heightSixtyFourths, dpi: shownDPI)
        else { return nil }
        return (shown, CGSize(width: contentSpan(raster.widthSixtyFourths, dpi: shownDPI),
                              height: contentSpan(raster.heightSixtyFourths, dpi: shownDPI)))
    }

    /// What the page showed for `box` at `shownDPI`, carried onto `raster`:
    /// the box's fill there by this same rule at its own quality, or, for a
    /// box that does not project there, its regions' own fills there, as the
    /// kept plan shows such a box. Nil when the quality is the raster's own,
    /// when there is none, or when nothing was shown.
    static func shownFill(box: PaintedBox, regions: [UUID: RedactionRegion], raster: PixelPlan.Raster,
                          shownDPI: Int?) -> PixelPlan.PixelRect? {
        guard let (shown, content) = shownRaster(of: raster, shownDPI: shownDPI) else { return nil }
        var fill = ownFillAndProjection(box: box, regions: regions, raster: shown, content: content)?.fill
        if fill == nil {
            var rect = CGRect.null
            for id in box.regionIDs {
                guard let region = regions[id] else { continue }
                let filled = normalizedToFillPixels(region.normalizedRect, content: content)
                if !filled.isEmpty { rect = rect.union(filled) }
            }
            if !rect.isNull { fill = PixelPlan.PixelRect(bitmapRect: rect) }
        }
        guard let fill, !fill.isEmpty else { return nil }
        let carried = PixelPlan.carried(fill, shownDPI: shown.dpi, onto: raster)
        return carried.isEmpty ? nil : carried
    }

    /// A region's own fill at `shownDPI`, carried onto `raster`, as the run
    /// joins it for a region it fills on its own. Nil where `shownFill` is.
    static func shownRegionFill(_ region: RedactionRegion, raster: PixelPlan.Raster,
                                shownDPI: Int?) -> CGRect? {
        guard let (shown, content) = shownRaster(of: raster, shownDPI: shownDPI) else { return nil }
        let filled = normalizedToFillPixels(region.normalizedRect, content: content)
        guard !filled.isEmpty else { return nil }
        let carried = PixelPlan.carried(PixelPlan.PixelRect(bitmapRect: filled), shownDPI: shown.dpi, onto: raster)
        return carried.isEmpty ? nil : carried.bitmapRect
    }

    /// The box's fill at the raster's own quality: its projection joined
    /// with each of its regions as the region path fills it, within the
    /// bitmap.
    private static func ownFillAndProjection(box: PaintedBox, regions: [UUID: RedactionRegion],
                                             raster: PixelPlan.Raster, content: CGSize)
        -> (fill: PixelPlan.PixelRect, projection: PixelPlan.Projection)? {
        guard let projection = PixelPlan.project(
            inner: box.inner, paint: box.paint,
            limitAbove: box.limitAbove, limitBelow: box.limitBelow, raster: raster) else { return nil }
        let bitmap = CGRect(x: 0, y: 0, width: raster.pixelWidth, height: raster.pixelHeight)
        var rect = projection.painted.bitmapRect
        for id in box.regionIDs {
            guard let region = regions[id] else { continue }
            let filled = normalizedToFillPixels(region.normalizedRect, content: content).intersection(bitmap)
            if !filled.isEmpty { rect = rect.union(filled) }
        }
        return (PixelPlan.PixelRect(bitmapRect: rect), projection)
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

    /// Whether a box the ink check judges keeps today's growth in its floor.
    /// It stays true until a differential count passes: for each word, the
    /// ink pixels the check's paint leaves unfilled that growth fills, read
    /// from a render of that word alone, at 150 and 300 dpi, must be zero.
    /// Only then may a judged box drop growth.
    static let judgedBoxKeepsGrowth = true

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
        // its "as placed" paint too, its regions' own fills and growth
        // included, so no box paints less than it would at "as placed".
        var rects: [(box: Int, rect: CGRect)] = []
        var painted = Set<UUID>()
        var verdicts: [Int: InkCheck.Verdict] = [:]
        var widened: Set<Int> = []
        let atSwitch = page.planSource == .switchPolicy
        var grid: InkCheck.Grid?
        // 4b'. The default band's net, before anything else reads a box: a box
        // painted with its default band where the page's picture shows ink in
        // the part of the band its line margin does not hold is painted with
        // its line margin instead. The net only withdraws a band.
        var boxes = page.boxes
        var withdrawn: Set<Int> = []
        for (index, fallback) in page.defaultFallbacks.sorted(by: { $0.key < $1.key })
        where index < boxes.count && boxes[index].defaultWidth == .taken {
            let box = boxes[index]
            if let band = PixelPlan.project(inner: box.inner, paint: box.paint, limitAbove: box.limitAbove,
                                            limitBelow: box.limitBelow, raster: raster)?.painted,
               let margin = PixelPlan.project(inner: fallback.inner, paint: fallback.paint,
                                              limitAbove: fallback.limitAbove, limitBelow: fallback.limitBelow,
                                              raster: raster)?.painted {
                if grid == nil { grid = Self.greyGrid(context: ctx) }
                guard let grid, !InkCheck.inkInSlot(band: band, lineMargin: margin, grid: grid, raster: raster)
                else { boxes[index] = fallback; withdrawn.insert(index); continue }
            } else {
                boxes[index] = fallback
                withdrawn.insert(index)
            }
        }
        // What was shown for a box that does not project here: filled as one
        // more stray rectangle, and read back.
        var shownOutsidePlan: [CGRect] = []
        func withRegionFills(_ rect: CGRect, of box: PaintedBox) -> CGRect {
            var rect = rect
            for id in box.regionIDs {
                guard let region = regionsByID[id] else { continue }
                let filled = normalizedToFillPixels(region.normalizedRect, content: content).intersection(bitmap)
                if !filled.isEmpty { rect = rect.union(filled) }
            }
            return rect
        }
        // A box's paint at "as placed": its projection, its regions' own
        // fills, and its growth over the ink that crosses its edge. Growth is
        // read from the box's margin edge and also from each growing
        // region's own "as placed" box (its paint its own rectangle, no
        // limit), where growth started before the plan read the page,
        // wherever that edge is not inside the box's: a limit holds the box's
        // edge in, up to two pixels inside where "as placed" starts, and
        // growth from there misses a detached mark (an accent above, a dot
        // below) whose lowest row lies between the two.
        // The quality the page was shown at: each box's paint holds the fill
        // shown there (`boxFill`).
        let shownDPI = page.confirmedPage?.shownDPI
        func asPlacedRect(_ box: PaintedBox, grows: Bool) throws -> CGRect? {
            guard let (fill, projection) = Self.boxFillAndProjection(
                box: box, regions: regionsByID, raster: raster, content: content,
                shownDPI: shownDPI) else { return nil }
            var rect = fill.bitmapRect
            guard grows else { return rect }
            let edge = projection.marginEdge.bitmapRect
            if let grown = try inkGrowthRect(context: ctx, fillRect: edge) { rect = rect.union(grown) }
            let own: [(id: UUID, share: PointRect)] = box.regionIDs.compactMap { id in
                guard growsOnInk[id] == true, let r = regionsByID[id]?.normalizedRect else { return nil }
                return (id, PointRect(minX: Double(r.minX), minY: Double(r.minY), maxX: Double(r.maxX), maxY: Double(r.maxY)))
            }
            let today = PaintPlan.asPlaced(regions: own, widthSixtyFourths: raster.widthSixtyFourths,
                                           heightSixtyFourths: raster.heightSixtyFourths)
            for placed in today.boxes {
                guard let p = PixelPlan.project(inner: placed.inner, paint: placed.paint, limitAbove: nil,
                                                limitBelow: nil, raster: raster),
                      !edge.contains(p.marginEdge.bitmapRect),
                      let grown = try inkGrowthRect(context: ctx, fillRect: p.marginEdge.bitmapRect) else { continue }
                rect = rect.union(grown)
            }
            return rect
        }
        for (index, box) in boxes.enumerated() {
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
                            var rect = withRegionFills(projection.painted.bitmapRect, of: box)
                            // Its floor: "as placed", with what was shown. A box that does not
                            // project as placed still holds what was shown for it.
                            if let floor = try asPlacedRect(box, grows: grows && Self.judgedBoxKeepsGrowth) {
                                rect = rect.union(floor)
                            } else if let shown = Self.shownFill(box: box, regions: regionsByID, raster: raster,
                                                                 shownDPI: shownDPI) {
                                rect = rect.union(shown.bitmapRect)
                            }
                            rects.append((index, rect))
                            painted.formUnion(box.regionIDs)
                            continue
                        }
                    }
                }
                // Not judged: painted as at "as placed", below.
                verdicts[index] = .indeterminate
            }
            guard let rect = try asPlacedRect(box, grows: grows) else {
                if let shown = Self.shownFill(box: box, regions: regionsByID, raster: raster, shownDPI: shownDPI) {
                    shownOutsidePlan.append(shown.bitmapRect)
                }
                continue
            }
            painted.formUnion(box.regionIDs)
            rects.append((index, rect))
        }
        let strays = page.regions.filter { !painted.contains($0.id) }
        let strayGrowth = try inkGrowthRects(context: ctx, regions: strays, content: content)
        // A stray region's fill joined with its own fill at the shown
        // quality, carried.
        let strayShown = strays.compactMap { Self.shownRegionFill($0, raster: raster, shownDPI: shownDPI) }
            + shownOutsidePlan

        // 5. The fills.
        for (_, rect) in rects {
            try fillInBands(context: ctx, rect: rect, fillColor: page.fillColor)
        }
        try applyRedactionFills(context: ctx, regions: strays, fillColor: page.fillColor, content: content)
        for rect in strayGrowth + strayShown {
            try fillInBands(context: ctx, rect: rect, fillColor: page.fillColor)
        }

        #if DEBUG
        Self.afterPlanFills?(ctx)
        #endif

        // 6. The readback, of the rectangles filled.
        let filled = rects.map(\.rect)
            + strays.map { normalizedToFillPixels($0.normalizedRect, content: content).intersection(bitmap) }
            + strayGrowth + strayShown
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
        result.defaultsWithdrawn = withdrawn
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
