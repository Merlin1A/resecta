import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import RedactionEngine

// The pixel step's second half: the producer paints the boxes the
// run's record placed in the page's data, reads back exactly what it filled,
// and reports each box's painted rectangle in the record's second part. A
// region no box holds is painted on its own and named in the record.
//
// Pages are 216 × 144 pt (3 × 2 in) drawn by a hand-made content stream and
// rasterized whole at 300 dpi. A box is checked against `PixelPlan.project`
// of the record's own box, the one arithmetic the check will share, joined
// with each region it holds as the region path fills it: a box never paints
// less than the region path did (a region past the left or bottom edge is
// slid onto the page whole by the run's clamp, and the region path painted
// that).

@Suite("The producer paints the page data's boxes")
struct PlanPaintTests {
    static let width: CGFloat = 216
    static let height: CGFloat = 144
    static let dpi = 300

    // MARK: - Fixtures

    /// One page whose content is the given black rectangles (points).
    static func pdf(ink: [CGRect]) -> Data {
        let stream = ink.isEmpty ? "" : "0 g " + ink.map { "\($0.minX) \($0.minY) \($0.width) \($0.height) re f" }.joined(separator: " ")
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(width) \(height)] /Contents 4 0 R >>",
            "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream",
        ]
        var out = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (i, object) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(i + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { out += String(format: "%010d 00000 n \n", offset) }
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(out.utf8)
    }

    /// A rectangle in points as a share of the page, unclamped.
    static func share(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX / width, y: r.minY / height, width: r.width / width, height: r.height / height)
    }

    /// Pixel `p` in points: the left or bottom edge of pixel line `p`.
    static func points(_ p: Int) -> CGFloat { CGFloat(p) * 72 / CGFloat(dpi) }

    /// The rendered page read back, rows from the bottom.
    struct Bitmap {
        let width: Int, height: Int, bytesPerRow: Int, bytes: [UInt8]
        init(_ image: CGImage) throws {
            width = image.width; height = image.height
            let ctx = try #require(createBitmapContext(width: width, height: height))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            bytesPerRow = ctx.bytesPerRow
            let data = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
            bytes = Array(UnsafeBufferPointer(start: data, count: bytesPerRow * height))
        }
        /// Every channel of pixel (x, y) equals `level` (0 black, 255 white).
        func pixel(_ x: Int, _ y: Int, is level: UInt8) -> Bool {
            let off = (height - 1 - y) * bytesPerRow + x * 4
            return bytes[off] == level && bytes[off + 1] == level && bytes[off + 2] == level
        }
        /// The pixels of `rect` that are not `level`.
        func misses(_ rect: PixelPlan.PixelRect, level: UInt8) -> Int {
            var n = 0
            for y in max(0, rect.minY)..<min(height, rect.maxY) {
                for x in max(0, rect.minX)..<min(width, rect.maxX) where !pixel(x, y, is: level) { n += 1 }
            }
            return n
        }
    }

    /// A page rasterized whole, with what it was given.
    struct Run {
        let result: RasterizeResult
        let bitmap: Bitmap
        let plan: PaintPlan
        let raster: PixelPlan.Raster
        let ids: [UUID]
        let regions: [RedactionRegion]
        let content: CGSize

        /// The record's box `i` as projected on the page's raster.
        func projection(_ i: Int) throws -> PixelPlan.Projection {
            let box = plan.boxes[i]
            return try #require(PixelPlan.project(inner: box.inner, paint: box.paint, limitAbove: box.limitAbove,
                                                  limitBelow: box.limitBelow, raster: raster))
        }
        /// The pixels the region path fills for `region`, on the bitmap.
        func regionPath(_ region: RedactionRegion) -> PixelPlan.PixelRect? {
            let filled = normalizedToFillPixels(region.normalizedRect, content: content)
                .intersection(CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
            return filled.isEmpty ? nil : PixelPlan.PixelRect(bitmapRect: filled)
        }
        /// Box `i`'s rectangle with no growth: its projection joined with
        /// each region it holds as the region path fills it.
        func expected(_ i: Int) throws -> PixelPlan.PixelRect {
            var rect = try projection(i).painted.bitmapRect
            for region in regions where plan.boxes[i].regionIDs.contains(region.id) {
                if let filled = regionPath(region) { rect = rect.union(filled.bitmapRect) }
            }
            return PixelPlan.PixelRect(bitmapRect: rect)
        }
        func reported(_ i: Int) throws -> PixelPlan.PixelRect {
            let p = try #require(result.paintedBoxes[i])
            return PixelPlan.PixelRect(minX: p.firstColumn, minY: p.firstRowFromBottom,
                                       maxX: p.firstColumn + p.columns, maxY: p.firstRowFromBottom + p.rows)
        }
    }

    /// Rasterizes a page with a region for each of `boxes` (points, as drawn)
    /// and a record of them. `text`: the regions were placed from text, so
    /// growth applies. `recordOmits`: regions the record holds no box for.
    /// `recordOffset`: the record's rectangle moved by this many points to the
    /// right of the page's region (the page's data and its regions apart).
    static func run(boxes: [CGRect], text: Bool = false, ink: [CGRect] = [], fill: FillColor = .black,
                    recordOmits: Set<Int> = [], recordOffset: CGFloat = 0) async throws -> Run {
        let doc = try #require(PDFDocument(data: pdf(ink: ink)))
        let page = try #require(doc.page(at: 0))
        let ids = boxes.map { _ in UUID() }
        let drawn = boxes.indices.filter { !recordOmits.contains($0) }.map {
            RunRecord.DrawnRegion(region: RedactionRegion(id: ids[$0], normalizedRect: share(boxes[$0].offsetBy(dx: recordOffset, dy: 0)),
                                                          source: text ? .searchMatch(term: "x") : .manual))
        }
        // The run's regions as the app hands them over: clamped to the page
        // and through admission.
        let regions = boxes.indices.compactMap { i -> RedactionRegion? in
            let s = share(boxes[i])
            guard RedactionRegion.isAdmitted(normalizedRect: s) else { return nil }
            return RedactionRegion(id: ids[i], normalizedRect: s.clampedToNormalized(),
                                   source: text ? .searchMatch(term: "x") : .manual)
        }
        let crop = page.bounds(for: .cropBox)
        let confirmed = RunRecord.Page(pageIndex: 0, regions: drawn, cropBox: crop.size, rotation: page.rotation,
                                       switchOn: false)
        let data = PDFPageData(
            page: page, pageIndex: 0, regions: regions, fillColor: fill, targetDPI: dpi,
            pipelineMode: .secureRasterization, rotation: page.rotation,
            cropBoxBounds: crop, cgPage: page.pageRef, hasText: false, confirmedPage: confirmed)
        let result = try await PageRasterizer().rasterize(data, dpiCap: dpi)
        let plan = try #require(confirmed.plan)
        let raster = try #require(PixelPlan.Raster(widthSixtyFourths: plan.widthSixtyFourths,
                                                   heightSixtyFourths: plan.heightSixtyFourths, dpi: dpi))
        let perInch = Double(PixelPlan.sixtyFourthsPerInch)
        return Run(result: result, bitmap: try Bitmap(result.pageOutput.image), plan: plan, raster: raster,
                   ids: ids, regions: regions,
                   content: CGSize(width: Double(plan.widthSixtyFourths * dpi) / perInch,
                                   height: Double(plan.heightSixtyFourths * dpi) / perInch))
    }

    // MARK: - Fills and readback on pixel boxes

    enum Placement: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case inside, pastLeft, pastRight, pastBottom, pastTop, overlapping, oneBlock, noBox
        var testDescription: String { rawValue }
        var boxes: [CGRect] {
            switch self {
            case .inside: [CGRect(x: 50.3, y: 50.7, width: 70.1, height: 20.2)]
            case .pastLeft: [CGRect(x: -20, y: 50.7, width: 60.2, height: 20.2)]
            case .pastRight: [CGRect(x: 180.4, y: 50.7, width: 60, height: 20.2)]
            case .pastBottom: [CGRect(x: 60.3, y: -15, width: 60.2, height: 35.1)]
            case .pastTop: [CGRect(x: 60.3, y: 120.6, width: 60.2, height: 40)]
            case .overlapping: [CGRect(x: 40.2, y: 40.3, width: 60.1, height: 30.2),
                                CGRect(x: 80.6, y: 55.4, width: 70.3, height: 35.2)]
            case .oneBlock: [CGRect(x: 100.3, y: 60.3, width: 1.1, height: 1.1)]
            case .noBox: []
            }
        }
        static let pastAnEdge: [Placement] = [.pastLeft, .pastRight, .pastBottom, .pastTop]
    }

    @Test("Each box is filled as the record's box projects joined with its regions as the region path fills them, on a raster of the page's sides S", arguments: Placement.allCases)
    func fillsOnPixelBoxes(_ placement: Placement) async throws {
        let run = try await Self.run(boxes: placement.boxes)
        #expect(run.bitmap.width == run.raster.pixelWidth && run.bitmap.height == run.raster.pixelHeight,
                "the raster is ⌈S·d / 4608⌉ of the record's sides")
        #expect(run.result.paintedBoxes.count == run.plan.boxes.count)
        #expect(run.result.regionsPaintedOutsideThePlan.isEmpty)
        for i in run.plan.boxes.indices {
            let expected = try run.expected(i)
            #expect(try run.reported(i) == expected, "box \(i)")
            #expect(run.bitmap.misses(expected, level: 0) == 0, "box \(i): every pixel of its rectangle is the fill")
        }
    }

    @Test("A neighbouring letter between the margin's edge and the block line: the box does not grow, and the letter is painted only to the block line")
    func neighbourLetterDoesNotGrowTheBox() async throws {
        let box = CGRect(x: 60.2, y: 60.3, width: 40.1, height: 12.2)
        let probe = try await Self.run(boxes: [box], text: true, fill: .white)
        let projection = try probe.projection(0)
        let margin = projection.marginEdge, painted = projection.painted
        try #require(margin.maxX + 1 < painted.maxX, "the block line stands past the margin's edge")
        // The letter: from one pixel past the margin's edge to 6 px past the block line.
        let letter = CGRect(x: Self.points(margin.maxX + 1), y: 62,
                            width: Self.points(painted.maxX + 6) - Self.points(margin.maxX + 1), height: 8)
        let selected = CGRect(x: 62, y: 62, width: 28, height: 8)
        let run = try await Self.run(boxes: [box], text: true, ink: [selected, letter], fill: .white)
        let expected = try run.expected(0)
        #expect(try run.reported(0) == expected, "no growth: the rectangle is the projection with its region")
        #expect(run.bitmap.misses(expected, level: 255) == 0, "that rectangle is the fill")
        let past = PixelPlan.PixelRect(minX: expected.maxX, minY: Int(64 * 300 / 72), maxX: painted.maxX + 5,
                                       maxY: Int(68 * 300 / 72))
        try #require(expected.maxX + 5 <= painted.maxX + 6, "the letter runs 5 px past that rectangle")
        #expect(run.bitmap.misses(past, level: 0) == 0, "the letter past the block line keeps its ink")
    }

    @Test("An accent of the selected text across the margin's edge: the box grows over it")
    func accentGrowsTheBox() async throws {
        let box = CGRect(x: 60.2, y: 60.3, width: 40.1, height: 12.2)
        let selected = CGRect(x: 62, y: 62, width: 28, height: 8)
        let accent = CGRect(x: 70, y: 66, width: 2, height: 8.5)   // to 74.5 pt, past the box's top
        let run = try await Self.run(boxes: [box], text: true, ink: [selected, accent], fill: .white)
        let painted = try run.projection(0).painted
        let reported = try run.reported(0)
        #expect(reported.maxY > painted.maxY, "the box grew upward")
        let accentPixels = PixelPlan.PixelRect(minX: Int(70 * 300 / 72), minY: Int(66 * 300 / 72),
                                               maxX: 300, maxY: Int((74.5 * 300 / 72.0).rounded(.up)))
        #expect(run.bitmap.misses(accentPixels, level: 255) == 0, "no pixel of the accent keeps its ink")
        #expect(run.bitmap.misses(reported, level: 255) == 0, "the grown rectangle is the fill")
    }

    // MARK: - The reported rectangle is the painted one

    @Test("The reported rectangles are exactly the filled pixels", arguments: Placement.allCases)
    func reportedIsPainted(_ placement: Placement) async throws {
        let run = try await Self.run(boxes: placement.boxes)
        let rects = try run.plan.boxes.indices.map { try run.reported($0) }
        var wrong = 0
        for y in 0..<run.bitmap.height {
            for x in 0..<run.bitmap.width {
                let inside = rects.contains { x >= $0.minX && x < $0.maxX && y >= $0.minY && y < $0.maxY }
                if run.bitmap.pixel(x, y, is: 0) != inside { wrong += 1 }
            }
        }
        #expect(wrong == 0, "\(wrong) pixel(s) where the fill and the report disagree")
    }

    @Test("A box that grows upward with a block line for its right side: the bounding rectangle is reported, and its corner is filled")
    func grownCornerIsFilled() async throws {
        let box = CGRect(x: 60.2, y: 60.3, width: 40.1, height: 12.2)
        let selected = CGRect(x: 62, y: 62, width: 28, height: 8)
        let accent = CGRect(x: 96, y: 66, width: 2, height: 8.5)
        let run = try await Self.run(boxes: [box], text: true, ink: [selected, accent])
        let projection = try run.projection(0)
        try #require(projection.marginEdge.maxX < projection.painted.maxX, "the right side is a block line")
        let reported = try run.reported(0)
        #expect(reported.maxX == projection.painted.maxX && reported.maxY > projection.painted.maxY)
        let corner = PixelPlan.PixelRect(minX: projection.marginEdge.maxX, minY: projection.painted.maxY,
                                         maxX: projection.painted.maxX, maxY: reported.maxY)
        #expect(!corner.isEmpty)
        #expect(run.bitmap.misses(corner, level: 0) == 0, "every pixel of the corner is the fill")
        #expect(run.bitmap.misses(reported, level: 0) == 0)
    }

    // MARK: - The readback reads what was filled

    @Test("A pixel of a box's block ring unpainted after the fill: the page fails fill verification")
    func readbackReadsTheBlockRing() async throws {
        let box = Placement.inside.boxes[0]
        let probe = try await Self.run(boxes: [box])
        let projection = try probe.projection(0)
        let ring: (x: Int, y: Int)
        if projection.painted.minX < projection.marginEdge.minX {
            ring = (projection.painted.minX, (projection.painted.minY + projection.painted.maxY) / 2)
        } else {
            try #require(projection.painted.maxX > projection.marginEdge.maxX, "a side whose block line stands past the margin")
            ring = (projection.painted.maxX - 1, (projection.painted.minY + projection.painted.maxY) / 2)
        }
        await #expect(throws: PipelineError.self) {
            try await PageRasterizer.$afterPlanFills.withValue({ ctx in
                ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                ctx.fill(CGRect(x: ring.x, y: ring.y, width: 1, height: 1))
            }) {
                _ = try await Self.run(boxes: [box])
            }
        }
    }

    // MARK: - The record's boxes

    @Test("The geometry design's case: the record's box past an edge is the one the producer projected", arguments: Placement.pastAnEdge)
    func recordBoxPastAnEdge(_ placement: Placement) async throws {
        let run = try await Self.run(boxes: placement.boxes)
        #expect(try run.reported(0) == run.expected(0))
        if placement == .pastLeft || placement == .pastBottom {
            // The clamp slid the region onto the page whole: the region path's
            // rectangle reaches past the projection, and is painted.
            #expect(try run.expected(0) != run.projection(0).painted, "the slid region adds to the projection")
        }
    }

    /// Every region of the page, as the region path fills it, is wholly
    /// within the fill: no pixel the region path painted is left unpainted.
    static func expectCoversTheRegionPath(_ run: Run, label: String) {
        for region in run.regions {
            guard let pixels = run.regionPath(region) else { continue }
            #expect(run.bitmap.misses(pixels, level: 0) == 0, "\(label): a pixel the region path paints is left")
        }
    }

    @Test("The plan paints every pixel the region path paints, pixel for pixel", arguments: Placement.allCases)
    func coversTheRegionPath(_ placement: Placement) async throws {
        Self.expectCoversTheRegionPath(try await Self.run(boxes: placement.boxes), label: placement.rawValue)
    }

    @Test("The corpus runner's pages: the plan paints every pixel the region path paints")
    func corpusMirrorCoversTheRegionPath() async throws {
        let doc = try #require(PDFDocument(data: Self.pdf(ink: [])))
        let seeds = Placement.allCases.flatMap(\.boxes).enumerated().map { i, box in
            VerificationCorpusRunnerTests.RegionSeed(gtId: "g\(i)", value: "v", category: "c", page: 0, rect: Self.share(box))
        }
        let regions = seeds.compactMap { VerificationCorpusRunnerTests.region(from: $0, polygon: false) }
        try #require(regions.count == seeds.count)
        for region in regions {
            let pages = VerificationCorpusRunnerTests.buildPages(
                doc: doc, effectiveMode: .secureRasterization, regionsByPage: [0: [region]],
                textLayerStatus: [:], hasHiddenOCG: false)
            let page = try #require(pages.first)
            let plan = try #require(page.confirmedPage?.plan)
            let raster = try #require(PixelPlan.Raster(widthSixtyFourths: plan.widthSixtyFourths,
                                                       heightSixtyFourths: plan.heightSixtyFourths, dpi: Self.dpi))
            let result = try await PageRasterizer().rasterize(page, dpiCap: Self.dpi)
            let perInch = Double(PixelPlan.sixtyFourthsPerInch)
            let run = Run(result: result, bitmap: try Bitmap(result.pageOutput.image), plan: plan, raster: raster,
                          ids: [region.id], regions: [region],
                          content: CGSize(width: Double(plan.widthSixtyFourths * Self.dpi) / perInch,
                                          height: Double(plan.heightSixtyFourths * Self.dpi) / perInch))
            Self.expectCoversTheRegionPath(run, label: "mirror \(region.normalizedRect)")
        }
    }

    @Test("The producer paints the page data's box, not the page's region")
    func boxesComeFromThePageData() async throws {
        let region = CGRect(x: 40.3, y: 50.7, width: 50.1, height: 20.2)
        let run = try await Self.run(boxes: [region], recordOffset: 80)
        let painted = try run.projection(0).painted
        #expect(run.bitmap.misses(painted, level: 0) == 0, "the record's box is filled")
        #expect(try run.reported(0) == run.expected(0), "the box joined with its region as the region path fills it")
        let regionPixels = try #require(run.regionPath(run.regions[0]))
        #expect(run.bitmap.misses(regionPixels, level: 0) == 0, "the region is painted too: cover never less than the region path")
    }

    @Test("A region the record holds no box for is painted on its own and named in the record")
    func regionOutsideThePlan() async throws {
        let boxes = [CGRect(x: 40.3, y: 50.7, width: 50.1, height: 20.2), CGRect(x: 120.2, y: 80.4, width: 60.3, height: 30.1)]
        let run = try await Self.run(boxes: boxes, recordOmits: [1])
        #expect(run.result.paintedBoxes.count == 1)
        #expect(run.result.regionsPaintedOutsideThePlan == [run.ids[1]])
        // Its pixels, as the region path maps it.
        let rect = normalizedToFillPixels(run.regions[1].normalizedRect, content: run.content)
        let pixels = PixelPlan.PixelRect(bitmapRect: rect)
        #expect(run.bitmap.misses(pixels, level: 0) == 0, "the stray region is painted")
        var produced = RunRecord.Produced()
        produced.record(run.result, pageIndex: 3)
        #expect(produced.regionsPaintedOutsideThePlan == [3: [run.ids[1]]], "the record carries it")
        #expect(produced.paintedRectangles.keys.map(\.box) == [0] && produced.paintedRectangles.keys.map(\.pageIndex) == [3])
    }

    // MARK: - One place settles the raster

    @Test("Source pin: the render stage takes its raster's size from the page's data, settled in one place")
    func renderReadsTheSizeFromThePageData() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/RedactionEngine/Pipeline")
        let source = try String(contentsOf: dir.appendingPathComponent("PageRasterizer.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "public func rasterize("))
        let end = try #require(source.range(of: "// MARK: - The stages of `rasterize`"))
        let rasterize = source[start.upperBound..<end.lowerBound]
        #expect(!rasterize.contains("rasterPixelSize") && !rasterize.contains("rasterContentSize"),
                "rasterize reads the pixels preflight settled")
        let renderStart = try #require(source.range(of: "private func render("))
        let render = source[renderStart.upperBound...].prefix(900)
        #expect(render.contains("pixelSize: (raster.pixels.width, raster.pixels.height)"),
                "the render is handed the raster's size")
        let preflight = try #require(source.range(of: "private func preflight("))
        #expect(source[preflight.upperBound...].prefix(4000).contains("Self.pagePixels(page, dpi: dpi)"))
    }
}
