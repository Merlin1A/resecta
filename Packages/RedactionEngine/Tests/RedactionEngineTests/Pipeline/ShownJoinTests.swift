import CoreGraphics
import Foundation
import PDFKit
import RedactionCore
import Testing
@testable import RedactionEngine

/// The run never paints less than was shown: on a page run at another
/// quality than the one it was last drawn at, each box's paint is its own
/// fill joined with the fill shown, carried outward to whole pixels of the
/// run's raster. Read against the cases table (`shown-join.json`, ten rows,
/// every value a whole pixel line of its own raster, rows from the bottom),
/// a seeded property over five page shapes and every ordered pair of 150,
/// 200 and 300, and rendered pages.
@Suite("The run never paints less than was shown")
struct ShownJoinTests {

    // MARK: - The table

    struct Row: Decodable {
        let row: String
        let widthSixtyFourths: Int
        let heightSixtyFourths: Int
        let inner: [Int]
        let paint: [Int]
        let limitAbove: Int?
        let limitBelow: Int?
        let regionAsInner: Bool
        let shownDPI: Int?
        let runDPI: Int
        let runImage: [Int]
        let ownFill: [Int]
        let shownImage: [Int]?
        let shownFill: [Int]?
        let carried: [Int]?
        let joined: [Int]
        let carriedBeforeTheClip: [Int]?
    }

    static func rows() throws -> [Row] {
        let url = try #require(Bundle.module.url(forResource: "shown-join", withExtension: "json",
                                                 subdirectory: "TestResources"))
        return try JSONDecoder().decode([Row].self, from: Data(contentsOf: url))
    }

    static func pixels(_ v: [Int]) -> PixelPlan.PixelRect {
        PixelPlan.PixelRect(minX: v[0], minY: v[1], maxX: v[2], maxY: v[3])
    }

    static func rect64(_ v: [Int]) -> PageRect64 {
        PageRect64(minX: v[0], minY: v[1], maxX: v[2], maxY: v[3])
    }

    static func raster(_ w: Int, _ h: Int, _ dpi: Int) throws -> PixelPlan.Raster {
        try #require(PixelPlan.Raster(widthSixtyFourths: w, heightSixtyFourths: h, dpi: dpi))
    }

    static func content(_ raster: PixelPlan.Raster) -> CGSize {
        CGSize(width: PageRasterizer.contentSpan(raster.widthSixtyFourths, dpi: raster.dpi),
               height: PageRasterizer.contentSpan(raster.heightSixtyFourths, dpi: raster.dpi))
    }

    /// A box of the plan with one region laid exactly over `inner` (as a
    /// share of the page), or none.
    static func box(inner: PageRect64, paint: PageRect64, above: Int?, below: Int?, w: Int, h: Int,
                    withRegion: Bool) -> (PaintedBox, [UUID: RedactionRegion]) {
        let id = UUID()
        let box = PaintedBox(regionIDs: [id], inner: inner, paint: paint, tight: inner, limitAbove: above,
                             limitBelow: below, exposure: .canShowLength, treatment: .notAsked, bandMade: false,
                             inkEnlargedCovered: false, inkEnlargedToCap: false,
                             asDrawn: paint == inner && above == nil && below == nil)
        guard withRegion else { return (box, [:]) }
        let share = CGRect(x: Double(inner.minX) / Double(w), y: Double(inner.minY) / Double(h),
                           width: Double(inner.maxX - inner.minX) / Double(w),
                           height: Double(inner.maxY - inner.minY) / Double(h))
        return (box, [id: RedactionRegion(id: id, normalizedRect: share, source: .manual)])
    }

    // MARK: - 1. The carry

    @Test("The carry: the table's carried column, the clip of row 9, and the carried rectangle holding the shown one")
    func carriedHoldsTheShownRectangle() throws {
        var checked = 0
        for row in try Self.rows() {
            let run = try Self.raster(row.widthSixtyFourths, row.heightSixtyFourths, row.runDPI)
            #expect([run.pixelWidth, run.pixelHeight] == row.runImage, "\(row.row): the run's image")
            guard let shownDPI = row.shownDPI, shownDPI != row.runDPI,
                  let shownFill = row.shownFill, let carried = row.carried else { continue }
            let shown = try Self.raster(row.widthSixtyFourths, row.heightSixtyFourths, shownDPI)
            #expect([shown.pixelWidth, shown.pixelHeight] == row.shownImage, "\(row.row): the shown image")
            #expect(PixelPlan.carried(Self.pixels(shownFill), shownDPI: shownDPI, onto: run) == Self.pixels(carried),
                    "\(row.row)")
            if let before = row.carriedBeforeTheClip {
                #expect(before[3] > run.pixelHeight, "\(row.row): the carry reaches past the image before the clip")
                #expect(carried[3] == run.pixelHeight, "\(row.row): and is cut to it")
            }
            checked += 1
        }
        #expect(checked == 8)

        // The property on the carry alone, over the seeded boxes.
        var trials = 0
        try Self.forEachSeeded { w, h, shown, run, inner in
            let (box, regions) = Self.box(inner: inner, paint: inner, above: nil, below: nil, w: w, h: h,
                                          withRegion: true)
            guard let fill = PageRasterizer.boxFill(box: box, regions: regions, raster: shown,
                                                    content: Self.content(shown)) else { return }
            let carried = PixelPlan.carried(fill, shownDPI: shown.dpi, onto: run)
            #expect(Self.holds(carried, run, fill, shown), "\(inner) \(shown.dpi) -> \(run.dpi)")
            // Each side under one pixel of the run's raster past the shown one.
            let s = shown.dpi, d = run.dpi
            #expect(fill.minX * d - carried.minX * s < s && fill.minY * d - carried.minY * s < s)
            #expect(carried.maxX * s - fill.maxX * d < s && carried.maxY * s - fill.maxY * d < s)
            trials += 1
        }
        #expect(trials == 5 * 6 * Self.perPage)
    }

    // MARK: - 2. The join, against the table

    @Test("The join: each row's own fill and joined fill, by the one floor function")
    func joinedFillMatchesTheTable() throws {
        let rows = try Self.rows()
        #expect(rows.count == 10)
        for row in rows {
            let run = try Self.raster(row.widthSixtyFourths, row.heightSixtyFourths, row.runDPI)
            let (box, regions) = Self.box(inner: Self.rect64(row.inner), paint: Self.rect64(row.paint),
                                          above: row.limitAbove, below: row.limitBelow,
                                          w: row.widthSixtyFourths, h: row.heightSixtyFourths,
                                          withRegion: row.regionAsInner)
            let content = Self.content(run)
            let own = PageRasterizer.boxFill(box: box, regions: regions, raster: run, content: content)
            #expect(own == Self.pixels(row.ownFill), "\(row.row): own")
            let joined = PageRasterizer.boxFill(box: box, regions: regions, raster: run, content: content,
                                                shownDPI: row.shownDPI)
            #expect(joined == Self.pixels(row.joined), "\(row.row): joined")
        }
    }

    // MARK: - The property of the join

    @Test("Over the seeded boxes the joined fill holds the shown one; a box whose own fill holds it is painted as today")
    func joinedHoldsWhatWasShown() throws {
        var short = 0, trials = 0
        try Self.forEachSeeded { w, h, shown, run, inner in
            let (box, regions) = Self.box(inner: inner, paint: inner, above: nil, below: nil, w: w, h: h,
                                          withRegion: true)
            guard let seen = PageRasterizer.boxFill(box: box, regions: regions, raster: shown,
                                                    content: Self.content(shown)),
                  let own = PageRasterizer.boxFill(box: box, regions: regions, raster: run,
                                                   content: Self.content(run)),
                  let joined = PageRasterizer.boxFill(box: box, regions: regions, raster: run,
                                                      content: Self.content(run), shownDPI: shown.dpi)
            else { return }
            #expect(Self.holds(joined, run, seen, shown), "\(inner) \(shown.dpi) -> \(run.dpi)")
            if Self.holds(own, run, seen, shown) {
                #expect(joined == own, "\(inner) \(shown.dpi) -> \(run.dpi): held already, yet changed")
            } else {
                short += 1
            }
            trials += 1
        }
        #expect(trials == 5 * 6 * Self.perPage)
        #expect(short > 0, "without the join some box falls short")
    }

    // MARK: - 3. One quality

    @Test("At the run's own quality, or with none shown, the fill is today's")
    func sameQualityIsToday() throws {
        try Self.forEachSeeded { w, h, _, run, inner in
            let (box, regions) = Self.box(inner: inner, paint: inner, above: nil, below: nil, w: w, h: h,
                                          withRegion: true)
            let content = Self.content(run)
            let today = PageRasterizer.boxFill(box: box, regions: regions, raster: run, content: content)
            #expect(PageRasterizer.boxFill(box: box, regions: regions, raster: run, content: content,
                                           shownDPI: run.dpi) == today)
            #expect(PageRasterizer.boxFill(box: box, regions: regions, raster: run, content: content,
                                           shownDPI: nil) == today)
        }
    }

    // MARK: - 4, 5, 8. Rendered pages

    /// A blank page of the given sides.
    static func blankPage(width: String, height: String) throws -> PDFPage {
        let data = buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(width) \(height)] /Contents 4 0 R >>"),
            PDFObject(id: 4, content: "<< /Length 0 >>\nstream\n\nendstream"),
        ], rootId: 1)
        let doc = try #require(PDFDocument(data: data))
        return try #require(doc.page(at: 0))
    }

    static func pageData(_ page: PDFPage, regions: [RedactionRegion], chosen: Int,
                         confirmed: RunRecord.Page?) -> PDFPageData {
        PDFPageData(page: page, pageIndex: 0, regions: regions.map { region in
                        var clamped = region
                        clamped.normalizedRect = region.normalizedRect.clampedToNormalized()
                        return clamped
                    },
                    fillColor: .black, targetDPI: chosen, pipelineMode: .secureRasterization,
                    rotation: page.rotation, cropBoxBounds: page.bounds(for: .cropBox), cgPage: page.pageRef,
                    hasText: false, confirmedPage: confirmed)
    }

    static func confirmed(_ page: PDFPage, _ regions: [RedactionRegion], shownDPI: Int?) -> RunRecord.Page {
        RunRecord.Page(pageIndex: 0, regions: regions.map(RunRecord.DrawnRegion.init(region:)),
                       cropBox: page.bounds(for: .cropBox).size, rotation: page.rotation, switchOn: false,
                       shownDPI: shownDPI)
    }

    /// The black pixels in a window `pad` pixels around `rect`, as a pixel
    /// rectangle (origin bottom-left). Nil when there are none.
    static func blackAround(_ rect: CGRect, in image: CGImage, pad: Int = 6) -> PixelPlan.PixelRect? {
        let w = image.width, h = image.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        buffer.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        let x0 = max(0, Int(rect.minX) - pad), x1 = min(w, Int(rect.maxX) + pad)
        let y0 = max(0, Int(rect.minY) - pad), y1 = min(h, Int(rect.maxY) + pad)
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for y in y0..<y1 {
            let row = h - 1 - y // memory rows run from the top
            for x in x0..<x1 where buffer[(row * w + x) * 4] < 64 {
                minX = min(minX, x); maxX = max(maxX, x + 1); minY = min(minY, y); maxY = max(maxY, y + 1)
            }
        }
        return minX <= maxX ? PixelPlan.PixelRect(minX: minX, minY: minY, maxX: maxX, maxY: maxY) : nil
    }

    /// B5's three boxes: the table's J-24 row, as a share of the page, and two more.
    static let b5Shares: [CGRect] = [
        CGRect(x: 25714.0 / 31930, y: 342.0 / 45355, width: 2862.0 / 31930, height: 1100.0 / 45355),
        CGRect(x: 0.12341, y: 0.40733, width: 0.31117, height: 0.02391),
        CGRect(x: 0.55017, y: 0.71241, width: 0.21733, height: 0.03117),
    ]

    @Test("A page shown at 300 and painted at 150: each reported box holds the join, and the readback passes")
    func paintedPageHoldsWhatWasShown() async throws {
        let page = try Self.blankPage(width: "498.898", height: "708.661")
        let regions = Self.b5Shares.map { RedactionRegion(id: UUID(), normalizedRect: $0, source: .manual) }
        let record = Self.confirmed(page, regions, shownDPI: 300)
        let plan = try #require(record.plan)
        #expect(plan.boxes.count == 3)
        let data = Self.pageData(page, regions: regions, chosen: 300, confirmed: record)
        let result = try await PageRasterizer().rasterize(data, dpiCap: 150)
        let pixels = try #require(PageRasterizer.pagePixels(data, dpi: 150))
        let raster = try #require(pixels.plan)
        var byID: [UUID: RedactionRegion] = [:]
        for region in data.regions { byID[region.id] = region }
        var joinedSomewhere = false
        for (index, box) in plan.boxes.enumerated() {
            let reported = try #require(result.paintedBoxes[index], "box \(index) reported")
            let ran = PixelPlan.PixelRect(minX: reported.firstColumn, minY: reported.firstRowFromBottom,
                                          maxX: reported.firstColumn + reported.columns,
                                          maxY: reported.firstRowFromBottom + reported.rows)
            let joined = try #require(PageRasterizer.boxFill(box: box, regions: byID, raster: raster,
                                                             content: pixels.content, shownDPI: 300))
            let own = try #require(PageRasterizer.boxFill(box: box, regions: byID, raster: raster,
                                                          content: pixels.content))
            #expect(ran == joined, "box \(index): reported \(ran), joined \(joined)")
            #expect(Self.blackAround(joined.bitmapRect, in: result.pageOutput.image) == joined,
                    "box \(index): the black pixels are the joined rectangle")
            if joined != own { joinedSomewhere = true }
        }
        #expect(joinedSomewhere, "on B5 shown at 300 and run at 150 a box's own fill falls short")
    }

    @Test("A region no box holds, shown at 300 and run at 200: its fill joins its own fill shown there, read back")
    func strayHoldsWhatWasShown() async throws {
        let page = try Self.blankPage(width: "612", height: "792")
        let w = try #require(PixelPlan.sixtyFourths(ofSide: 612)), h = try #require(PixelPlan.sixtyFourths(ofSide: 792))
        let run = try Self.raster(w, h, 200), shown = try Self.raster(w, h, 300)
        // The first candidate whose own fill at 200 falls short of what 300 showed.
        let candidates = (0..<40).map { i in
            CGRect(x: 0.1 + 0.0137 * Double(i), y: 0.2 + 0.0113 * Double(i), width: 0.2311, height: 0.0219)
        }
        let share = try #require(candidates.first { share in
            let own = normalizedToFillPixels(share, content: Self.content(run))
            let seen = normalizedToFillPixels(share, content: Self.content(shown))
            let carried = PixelPlan.carried(PixelPlan.PixelRect(bitmapRect: seen), shownDPI: 300, onto: run)
            return PixelPlan.PixelRect(bitmapRect: own).joined(with: carried) != PixelPlan.PixelRect(bitmapRect: own)
        })
        let region = RedactionRegion(id: UUID(), normalizedRect: share, source: .manual)
        // A record whose plan holds no box: the region is filled on its own.
        let empty = PaintPlan(widthSixtyFourths: w, heightSixtyFourths: h, boxes: [])
        let record = RunRecord.Page(pageIndex: 0, regions: [RunRecord.DrawnRegion(region: region)], plan: empty,
                                    shownDPI: 300)
        let data = Self.pageData(page, regions: [region], chosen: 200, confirmed: record)
        let result = try await PageRasterizer().rasterize(data)
        #expect(result.regionsPaintedOutsideThePlan == [region.id])
        let own = PixelPlan.PixelRect(bitmapRect: normalizedToFillPixels(share, content: Self.content(run)))
        let carried = try #require(PageRasterizer.shownRegionFill(region, raster: run, shownDPI: 300))
        let expected = own.joined(with: PixelPlan.PixelRect(bitmapRect: carried))
        #expect(expected != own)
        #expect(Self.blackAround(expected.bitmapRect, in: result.pageOutput.image) == expected)
    }

    @Test("Every page run at the quality it was shown at is byte for byte the page with no shown quality",
          arguments: [150, 200, 300])
    func documentAtItsShownQualityIsByteIdentical(_ dpi: Int) async throws {
        for (width, height) in [("612", "792"), ("595.276", "841.89"), ("498.898", "708.661")] {
            let page = try Self.blankPage(width: width, height: height)
            let regions = Self.b5Shares.map { RedactionRegion(id: UUID(), normalizedRect: $0, source: .manual) }
            let shown = try await PageRasterizer().rasterize(
                Self.pageData(page, regions: regions, chosen: dpi,
                              confirmed: Self.confirmed(page, regions, shownDPI: dpi)))
            let none = try await PageRasterizer().rasterize(
                Self.pageData(page, regions: regions, chosen: dpi,
                              confirmed: Self.confirmed(page, regions, shownDPI: nil)))
            #expect(shown.paintedBoxes == none.paintedBoxes, "\(width) x \(height) at \(dpi)")
            let a = try #require(shown.pageOutput.image.dataProvider?.data as Data?)
            let b = try #require(none.pageOutput.image.dataProvider?.data as Data?)
            #expect(a == b, "\(width) x \(height) at \(dpi): the page's pixels")
        }
    }

    // MARK: - The seeded boxes

    static let perPage = 4_000

    static let shapes: [(name: String, width: Double, height: Double)] = [
        ("Letter", 612, 792), ("A4", 595.276, 841.89), ("A4 shown landscape", 841.89, 595.276),
        ("Letter shown landscape", 792, 612), ("B5", 498.898, 708.661),
    ]

    /// For each page shape and each ordered pair of distinct qualities,
    /// `perPage` hand boxes seeded by the shape's name.
    static func forEachSeeded(_ body: (Int, Int, PixelPlan.Raster, PixelPlan.Raster, PageRect64) throws -> Void) throws {
        for shape in shapes {
            let w = try #require(PixelPlan.sixtyFourths(ofSide: shape.width))
            let h = try #require(PixelPlan.sixtyFourths(ofSide: shape.height))
            for s in [150, 200, 300] {
                for d in [150, 200, 300] where d != s {
                    var rng = SplitMix(seed: UInt64(truncatingIfNeeded: shape.name.utf8.reduce(20261124) { $0 &* 31 &+ Int($1) }))
                    let shown = try raster(w, h, s), run = try raster(w, h, d)
                    for _ in 0..<perPage {
                        let bw = rng.next(in: 64 * 6...64 * 220), bh = rng.next(in: 64 * 6...64 * 40)
                        let x0 = rng.next(in: 0...(w - bw)), y0 = rng.next(in: 0...(h - bh))
                        try body(w, h, shown, run, PageRect64(minX: x0, minY: y0, maxX: x0 + bw, maxY: y0 + bh))
                    }
                }
            }
        }
    }

    /// `a`, a rectangle of `ar`'s image, holds `b`, one of `br`'s, on the
    /// page: each compared in exact sixty-fourths, cut to the page.
    static func holds(_ a: PixelPlan.PixelRect, _ ar: PixelPlan.Raster,
                      _ b: PixelPlan.PixelRect, _ br: PixelPlan.Raster) -> Bool {
        // A pixel line v of a raster at d lies at v · 4608 / d sixty-fourths;
        // both sides are scaled by d_a · d_b to stay whole.
        let da = ar.dpi, db = br.dpi, w = ar.widthSixtyFourths, h = ar.heightSixtyFourths
        func page(_ v: Int, _ own: Int, _ other: Int, _ side: Int) -> Int { min(max(v * 4608 * other, 0), side * own * other) }
        return page(a.minX, da, db, w) <= page(b.minX, db, da, w)
            && page(a.minY, da, db, h) <= page(b.minY, db, da, h)
            && page(a.maxX, da, db, w) >= page(b.maxX, db, da, w)
            && page(a.maxY, da, db, h) >= page(b.maxY, db, da, h)
    }
}

/// A small seeded generator, so the seeded boxes are the same on every run.
private struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func next(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(nextUInt64() % UInt64(range.upperBound - range.lowerBound + 1))
    }
}
