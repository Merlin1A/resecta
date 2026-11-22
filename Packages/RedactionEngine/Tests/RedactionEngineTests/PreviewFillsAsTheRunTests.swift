import CoreGraphics
import Foundation
import PDFKit
import RedactionCore
import Testing
@testable import RedactionEngine

/// The preview equals the run: the pixels the editor's kept plan says a box
/// is filled with, at the quality a run started now uses, are the pixels the
/// run fills. Read from the run itself: each page is rasterized by
/// `PageRasterizer` with a black fill, and each region's filled rectangle is
/// read back from the output image.
///
/// What the kept plan cannot know, named limits: a memory warning during the
/// run (the cap drops to 150 for the pages started after it), and the one
/// page redone at 150 after its fill comparison failed once. Memory itself
/// is not read when the quality is chosen (`runTierBudget`): a page that
/// does not fit is refused, not drawn at a lower quality.
@Suite("The preview fills as the run fills")
struct PreviewFillsAsTheRunTests {

    /// A blank page of the given sides and turn.
    static func blankPage(width: String, height: String, rotate: Int) throws -> PDFPage {
        let data = buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(width) \(height)] /Rotate \(rotate) /Contents 4 0 R >>"),
            PDFObject(id: 4, content: "<< /Length 0 >>\nstream\n\nendstream"),
        ], rootId: 1)
        let doc = try #require(PDFDocument(data: data))
        return try #require(doc.page(at: 0))
    }

    /// Letter upright, A4 turned a quarter, and an odd page turned three.
    static let pages: [(width: String, height: String, rotate: Int)] = [
        ("612", "792", 0), ("595.2756", "841.8898", 90), ("500.37", "700.61", 270),
    ]

    /// Boxes with edges off the pixel grid at every quality, apart by more
    /// than four pixels; the last reaches past the page's right edge.
    static func regions() -> [RedactionRegion] {
        [CGRect(x: 0.10137, y: 0.20771, width: 0.23113, height: 0.02193),
         CGRect(x: 0.55091, y: 0.60013, width: 0.18741, height: 0.03527),
         CGRect(x: 0.31419, y: 0.41237, width: 0.00917, height: 0.01183),
         CGRect(x: 0.83003, y: 0.05119, width: 0.30000, height: 0.04011)]
            .map { RedactionRegion(id: UUID(), normalizedRect: $0, source: .manual) }
    }

    static func pageData(_ page: PDFPage, regions: [RedactionRegion], chosen: Int,
                         record: Bool = false) -> PDFPageData {
        PDFPageData(page: page, pageIndex: 0, regions: regions.map { region in
                        var clamped = region
                        clamped.normalizedRect = region.normalizedRect.clampedToNormalized()
                        return clamped
                    },
                    fillColor: .black, targetDPI: chosen, pipelineMode: .secureRasterization,
                    rotation: page.rotation, cropBoxBounds: page.bounds(for: .cropBox), cgPage: page.pageRef,
                    hasText: false,
                    confirmedPage: record
                        ? RunRecord.Page(pageIndex: 0, regions: regions.map(RunRecord.DrawnRegion.init(region:)),
                                         cropBox: page.bounds(for: .cropBox).size, rotation: page.rotation,
                                         switchOn: false)
                        : nil)
    }

    /// The run's filled rectangle for each region: the black pixels in a
    /// window four pixels around where the plan says it is, as a rectangle
    /// in the fill bitmap's frame (origin bottom-left). Nil when the window
    /// holds no black pixel.
    static func runFills(_ image: CGImage, around expected: [UUID: CGRect]) -> [UUID: CGRect] {
        let w = image.width, h = image.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        buffer.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var out: [UUID: CGRect] = [:]
        for (id, rect) in expected {
            let x0 = max(0, Int(rect.minX) - 4), x1 = min(w, Int(rect.maxX) + 4)
            let y0 = max(0, Int(rect.minY) - 4), y1 = min(h, Int(rect.maxY) + 4)
            var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
            for y in y0..<y1 {
                let row = h - 1 - y // memory rows run from the top
                for x in x0..<x1 where buffer[(row * w + x) * 4] < 64 {
                    minX = min(minX, x); maxX = max(maxX, x + 1); minY = min(minY, y); maxY = max(maxY, y + 1)
                }
            }
            if minX <= maxX { out[id] = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY) }
        }
        return out
    }

    /// A kept plan's fills, cut to the image (the run's fill clips at the
    /// bitmap's edge).
    static func onImage(_ fills: [UUID: CGRect], _ image: CGImage) -> [UUID: CGRect] {
        let bitmap = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        return fills.mapValues { $0.intersection(bitmap) }
    }

    @Test("At 300, 200 and 150 the kept plan's fills are the run's, pixel for pixel", arguments: [300, 200, 150])
    func keptPlanFillsAsTheRun(_ dpi: Int) async throws {
        var compared = 0
        for spec in Self.pages {
            let page = try Self.blankPage(width: spec.width, height: spec.height, rotate: spec.rotate)
            let regions = Self.regions()
            let quality = try #require(runQuality(chosenDPI: dpi, dpiCap: defaultDPICap,
                                                  cropBox: page.bounds(for: .cropBox).size, rotation: page.rotation))
            #expect(quality == dpi)
            let kept = DrawnPlan(pageIndex: 0, regions: regions, cropBox: page.bounds(for: .cropBox).size,
                                 rotation: page.rotation, switchOn: false, exportDPI: quality, fillColor: .black)
            #expect(kept.filledPixels.count == regions.count)
            let result = try await PageRasterizer().rasterize(Self.pageData(page, regions: regions, chosen: dpi))
            let image = result.pageOutput.image
            let expected = Self.onImage(kept.filledPixels, image)
            let run = Self.runFills(image, around: expected)
            for region in regions {
                #expect(run[region.id] == expected[region.id],
                        "page \(spec.width)x\(spec.height) turned \(spec.rotate) at \(dpi): run \(String(describing: run[region.id])), kept \(String(describing: expected[region.id]))")
                compared += 1
            }
        }
        print("[preview-fills] \(dpi) dpi: \(compared) boxes compared on \(Self.pages.count) pages")
        #expect(compared == 12)
    }

    @Test("With a record, at 300, 200 and 150 each box's fill is the run's, pixel for pixel", arguments: [300, 200, 150])
    func keptPlanFillsAsTheRunWithARecord(_ dpi: Int) async throws {
        var compared = 0
        for spec in Self.pages {
            let page = try Self.blankPage(width: spec.width, height: spec.height, rotate: spec.rotate)
            let regions = Self.regions()
            let cropBox = page.bounds(for: .cropBox).size
            let kept = DrawnPlan(pageIndex: 0, regions: regions, cropBox: cropBox, rotation: page.rotation,
                                 switchOn: false, exportDPI: dpi, fillColor: .black)
            #expect(kept.boxes.count == regions.count)
            #expect(kept.widthSixtyFourths != nil && kept.heightSixtyFourths != nil)
            let result = try await PageRasterizer().rasterize(Self.pageData(page, regions: regions, chosen: dpi,
                                                                            record: true))
            let image = result.pageOutput.image
            var expected: [UUID: CGRect] = [:]
            for box in kept.boxes {
                #expect(box.fill.count == 1, "every box projects")
                let id = try #require(box.regionIDs.first)
                expected[id] = try #require(box.fill.first)
            }
            // The run's own record of what it painted, by box.
            let painted = result.paintedBoxes
            #expect(painted.count == kept.boxes.count)
            for (index, box) in kept.boxes.enumerated() {
                let px = try #require(painted[index])
                let ran = CGRect(x: px.firstColumn, y: px.firstRowFromBottom, width: px.columns, height: px.rows)
                #expect(ran == box.fill.first, "page \(spec.width) turned \(spec.rotate) at \(dpi), box \(index)")
            }
            let run = Self.runFills(image, around: Self.onImage(expected, image))
            for region in regions {
                #expect(run[region.id] == Self.onImage(expected, image)[region.id],
                        "page \(spec.width)x\(spec.height) turned \(spec.rotate) at \(dpi): run \(String(describing: run[region.id])), kept \(String(describing: expected[region.id]))")
                compared += 1
            }
        }
        print("[preview-fills] record, \(dpi) dpi: \(compared) boxes compared on \(Self.pages.count) pages")
        #expect(compared == 12)
    }

    @Test("A box that does not project is kept as its regions' own fills, as the run fills it then")
    func aBoxThatDoesNotProject() throws {
        let page = try Self.blankPage(width: "612", height: "792", rotate: 0)
        let region = Self.regions()[0]
        let cropBox = page.bounds(for: .cropBox).size
        let made = DrawnPlan(pageIndex: 0, regions: [region], cropBox: cropBox, rotation: 0, switchOn: false,
                             exportDPI: 300, fillColor: .black)
        let plan = try #require(made.plan)
        // The same box with an empty inner, which no raster projects.
        var box = try #require(plan.boxes.first)
        box.inner = PageRect64(minX: box.inner.minX, minY: box.inner.minY, maxX: box.inner.minX, maxY: box.inner.maxY)
        let empty = PaintPlan(widthSixtyFourths: plan.widthSixtyFourths, heightSixtyFourths: plan.heightSixtyFourths,
                              boxes: [box])
        let fills = DrawnPlan.boxFills(plan: empty, regions: [region], cropBox: cropBox, rotation: 0, dpi: 300)
        #expect(fills == [[try #require(made.filledPixels[region.id])]])
    }

    @Test("Chosen 300 under the cap of 150: the kept plan fills as the run at 150, not as at 300")
    func cappedQuality() async throws {
        let page = try Self.blankPage(width: "595.2756", height: "841.8898", rotate: 90)
        let cropBox = page.bounds(for: .cropBox).size
        // An edge off the 8-pixel grid at both qualities.
        let region = RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.20731, y: 0.33917, width: 0.41153, height: 0.02711),
                                     source: .manual)
        let quality = try #require(runQuality(chosenDPI: 300, dpiCap: 150, cropBox: cropBox, rotation: page.rotation))
        #expect(quality == 150)
        let kept = DrawnPlan(pageIndex: 0, regions: [region], cropBox: cropBox, rotation: page.rotation,
                             switchOn: false, exportDPI: quality, fillColor: .black)
        let uncapped = DrawnPlan(pageIndex: 0, regions: [region], cropBox: cropBox, rotation: page.rotation,
                                 switchOn: false, exportDPI: 300, fillColor: .black)
        let result = try await PageRasterizer().rasterize(Self.pageData(page, regions: [region], chosen: 300), dpiCap: 150)
        let image = result.pageOutput.image
        let expected = Self.onImage(kept.filledPixels, image)
        #expect(Self.runFills(image, around: expected)[region.id] == expected[region.id])
        let rect = try #require(expected[region.id])
        #expect(Int(rect.minX) % 8 != 0 || Int(rect.maxX) % 8 != 0, "an edge off the 8-pixel grid")
        #expect(uncapped.filledPixels[region.id] != kept.filledPixels[region.id])
        #expect(kept != uncapped)
    }

    @Test("The run's quality: the highest tier at or below the chosen quality under the cap")
    func runQualityTable() {
        let letter = CGSize(width: 612, height: 792)
        let rows: [(chosen: Int, cap: Int, quality: Int)] = [
            (300, 300, 300), (300, 150, 150), (200, 300, 200), (200, 150, 150), (150, 300, 150), (150, 150, 150),
        ]
        for row in rows {
            #expect(runQuality(chosenDPI: row.chosen, dpiCap: row.cap, cropBox: letter, rotation: 0) == row.quality,
                    "\(row.chosen) under \(row.cap)")
        }
        // The largest page the pre-flight admits keeps its quality: memory is not read.
        #expect(runQuality(chosenDPI: 300, dpiCap: 300, cropBox: CGSize(width: 5000, height: 5000), rotation: 90) == 300)
    }

    @Test("Source pin: one rule, no copy: the run and the kept plan read the same functions")
    func oneRule() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/RedactionEngine")
        func read(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let rasterizer = try read("Pipeline/PageRasterizer.swift")
        #expect(rasterizer.contains("guard let dpi = runQuality(\n"))
        #expect(!rasterizer.contains("min(page.targetDPI, dpiCap)\n        guard let dpi = selectDPI("))
        let fills = try read("Pipeline/PixelOperations.swift")
        #expect(fills.contains("let pixelRect = normalizedToFillPixels(region.normalizedRect, content: basis)"))
        let plan = try read("Models/DrawnPlan.swift")
        #expect(plan.contains("PageRasterizer.rasterContentSize("))
        #expect(plan.contains("normalizedToFillPixels(region.normalizedRect.clampedToNormalized(), content: content)"))
        #expect(!plan.contains("pixelAligned"), "the kept plan rounds by the run's function, not its own")
    }
}
