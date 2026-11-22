import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import RedactionEngine

// The plan switch built (nothing moves): the run's plan source is "as
// placed", one function reads it beside the user's switch, and the producer
// runs the ink check where growth runs only when a test hands it a plan made
// under the switch's policy. At "as placed" nothing of the check runs.
//
// One 216 × 144 pt Searchable page at 300 dpi: a line of text kept as the
// text layer, and three black bars on a row below it. Four hand-made boxes:
// 0, a Search box over the left of a bar that runs 12 pt past its right edge;
// 1, a Search box holding a bar whole; 2, one box holding two Search regions
// over one bar; 3, a hand-drawn box over paper.

@Suite("The plan switch built on hand-made plans")
struct PlanSwitchTests {
    static let width: CGFloat = 216
    static let height: CGFloat = 144
    static let dpi = 300
    /// The line height the check is handed, 12 pt in sixty-fourths.
    static let lineHeight = 12 * 64

    static let bars = [CGRect(x: 40, y: 40, width: 30, height: 8),
                       CGRect(x: 100, y: 40, width: 10, height: 8),
                       CGRect(x: 130, y: 40, width: 20, height: 8)]
    /// Each box's rectangle in points, and its regions' rectangles.
    static let boxes: [(rect: CGRect, regions: [CGRect], search: Bool)] = [
        (CGRect(x: 36, y: 38, width: 22, height: 12), [CGRect(x: 36, y: 38, width: 22, height: 12)], true),
        (CGRect(x: 96, y: 38, width: 18, height: 12), [CGRect(x: 96, y: 38, width: 18, height: 12)], true),
        (CGRect(x: 126, y: 38, width: 28, height: 12),
         [CGRect(x: 126, y: 38, width: 14, height: 12), CGRect(x: 140, y: 38, width: 14, height: 12)], true),
        (CGRect(x: 160, y: 38, width: 40, height: 12), [CGRect(x: 160, y: 38, width: 40, height: 12)], false),
    ]

    static func pdf() -> Data {
        let stream = "BT /F1 12 Tf 10 100 Td (Ordinary twelve point line) Tj ET 0 g "
            + bars.map { "\($0.minX) \($0.minY) \($0.width) \($0.height) re f" }.joined(separator: " ")
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(width) \(height)] /Contents 4 0 R "
                + "/Resources << /Font << /F1 5 0 R >> >> >>",
            "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
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

    static func rect64(_ r: CGRect) -> PageRect64 {
        PageRect64(minX: Int(r.minX * 64), minY: Int(r.minY * 64), maxX: Int(r.maxX * 64), maxY: Int(r.maxY * 64))
    }
    static func share(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX / width, y: r.minY / height, width: r.width / width, height: r.height / height)
    }
    /// The pixels of a rectangle in points on the page's raster, rounded outward.
    static func pixels(_ r: CGRect) -> PixelPlan.PixelRect {
        let k = CGFloat(dpi) / 72
        return PixelPlan.PixelRect(minX: Int((r.minX * k).rounded(.down)), minY: Int((r.minY * k).rounded(.down)),
                                   maxX: Int((r.maxX * k).rounded(.up)), maxY: Int((r.maxY * k).rounded(.up)))
    }

    struct Run {
        let result: RasterizeResult
        let bitmap: PlanPaintTests.Bitmap
        let plan: PaintPlan
        let raster: PixelPlan.Raster
        func projection(_ i: Int) throws -> PixelPlan.PixelRect {
            let box = plan.boxes[i]
            return try #require(PixelPlan.project(inner: box.inner, paint: box.paint, limitAbove: box.limitAbove,
                                                  limitBelow: box.limitBelow, raster: raster)).painted
        }
        func reported(_ i: Int) throws -> PixelPlan.PixelRect {
            let p = try #require(result.paintedBoxes[i])
            return PixelPlan.PixelRect(minX: p.firstColumn, minY: p.firstRowFromBottom,
                                       maxX: p.firstColumn + p.columns, maxY: p.firstRowFromBottom + p.rows)
        }
    }

    /// The page rasterized under `source` with a hand-made plan of the four
    /// boxes, each box as placed, and the check's inputs for `inputsFor`.
    /// Each Search box is marked checkable, as the plan marks one placed from
    /// typed text, except those in `uncheckable` (as for a box placed from
    /// the page's picture).
    static func run(source: PlanSource, inputsFor: Set<Int>, uncheckable: Set<Int> = []) async throws -> Run {
        let doc = try #require(PDFDocument(data: pdf()))
        defer { withExtendedLifetime(doc) {} }
        let page = try #require(doc.page(at: 0))
        var regions: [RedactionRegion] = []
        var drawn: [RunRecord.DrawnRegion] = []
        var planBoxes: [PaintedBox] = []
        for (index, box) in boxes.enumerated() {
            var ids: Set<UUID> = []
            for r in box.regions {
                let id = UUID()
                ids.insert(id)
                regions.append(RedactionRegion(id: id, normalizedRect: share(r),
                                               source: box.search ? .searchMatch(term: "x") : .manual))
                drawn.append(RunRecord.DrawnRegion(id: id, normalizedRect: share(r)))
            }
            let r = rect64(box.rect)
            planBoxes.append(PaintedBox(regionIDs: ids, inner: r, paint: r, tight: r, limitAbove: nil, limitBelow: nil,
                                        exposure: GeometryPolicy.release.asPlaced.exposure, treatment: .notAsked,
                                        bandMade: false, inkEnlargedCovered: false, inkEnlargedToCap: false,
                                        asDrawn: false, inkCheckable: box.search && !uncheckable.contains(index)))
        }
        let plan = PaintPlan(widthSixtyFourths: Int(width) * 64, heightSixtyFourths: Int(height) * 64,
                             boxes: planBoxes)
        var data = PDFPageData(
            page: page, pageIndex: 0, regions: regions, fillColor: .black, targetDPI: dpi,
            pipelineMode: .searchableRedaction, rotation: page.rotation,
            cropBoxBounds: page.bounds(for: .cropBox), cgPage: page.pageRef,
            hasText: page.string?.isEmpty == false,
            confirmedPage: RunRecord.Page(pageIndex: 0, regions: drawn, plan: plan))
        data.planSource = source
        for i in inputsFor { data.inkCheckInputs[i] = InkCheckInputs(lineHeight: lineHeight, others: []) }
        let result = try await PageRasterizer().rasterize(data, dpiCap: dpi)
        let raster = try #require(PixelPlan.Raster(widthSixtyFourths: plan.widthSixtyFourths,
                                                   heightSixtyFourths: plan.heightSixtyFourths, dpi: dpi))
        return Run(result: result, bitmap: try PlanPaintTests.Bitmap(result.pageOutput.image), plan: plan,
                   raster: raster)
    }

    // MARK: - The source and the choice

    @Test("The run's plan source is \"as placed\", and under it the user's switch is not read")
    func sourceAndChoice() {
        #expect(RunRecord.planSource == .asPlaced)
        for (source, on, wantSource, wantOn) in [(PlanSource.asPlaced, true, PlanSource.asPlaced, false),
                                                 (.asPlaced, false, .asPlaced, false),
                                                 (.switchPolicy, true, .switchPolicy, true),
                                                 (.switchPolicy, false, .switchPolicy, false)] {
            let choice = RunRecord.planChoice(source: source, switchOn: on)
            #expect(choice.source == wantSource && choice.switchOn == wantOn, "\(source) \(on)")
        }
        let doc = PDFDocument(data: Self.pdf())
        let page = doc?.page(at: 0)
        #expect(PDFPageData(page: page ?? PDFPage(), pageIndex: 0, regions: [], fillColor: .black, targetDPI: 300,
                            pipelineMode: .secureRasterization, rotation: 0).planSource == .asPlaced)
    }

    @Test("The record's page makes the same as-placed plan with the switch on or off")
    func pageInitIgnoresTheSwitch() throws {
        let drawn = Self.boxes.flatMap(\.regions).map {
            RunRecord.DrawnRegion(id: UUID(), normalizedRect: Self.share($0))
        }
        let size = CGSize(width: Self.width, height: Self.height)
        let on = try #require(RunRecord.Page(pageIndex: 0, regions: drawn, cropBox: size, rotation: 0,
                                             switchOn: true).plan)
        let off = try #require(RunRecord.Page(pageIndex: 0, regions: drawn, cropBox: size, rotation: 0,
                                              switchOn: false).plan)
        let asPlaced = PaintPlan.asPlaced(
            regions: drawn.map { d in
                let r = d.normalizedRect
                return (d.id, PointRect(minX: Double(r.minX), minY: Double(r.minY),
                                        maxX: Double(r.maxX), maxY: Double(r.maxY)))
            },
            widthSixtyFourths: Int(Self.width) * 64, heightSixtyFourths: Int(Self.height) * 64)
        #expect(on == off)
        #expect(on.boxes == asPlaced.boxes)
        #expect(on.boxes.allSatisfy { !$0.bandMade && !$0.inkEnlargedCovered && !$0.inkEnlargedToCap })
    }

    // MARK: - The check where growth runs

    @Test("At the switch's policy each box paints the plan's rectangle, and the box the check widens covers its ink")
    func switchPaintsThePlan() async throws {
        let run = try await Self.run(source: .switchPolicy, inputsFor: [0, 1, 2])
        #expect(run.result.inkVerdicts[0] == .escaped)
        #expect(run.result.inkVerdicts[1] == .clear)
        #expect(run.result.inkVerdicts[2] == .clear)
        #expect(run.result.inkVerdicts[3] == nil, "a hand-drawn box is never checked")
        // The tight, the merged and the hand-drawn box: exactly the plan's rectangle.
        for i in 1...3 { #expect(try run.reported(i) == run.projection(i), "box \(i)") }
        // The widened box: larger than placed, to the right only, over all of its bar.
        let widened = try run.reported(0), placed = try run.projection(0)
        #expect(widened.maxX > placed.maxX)
        #expect(widened.minX == placed.minX && widened.minY == placed.minY && widened.maxY == placed.maxY)
        #expect(run.bitmap.misses(Self.pixels(Self.bars[0]), level: 0) == 0)
        // Its page is written as a picture, for the new reason.
        #expect(run.result.fallbackReason == .inkEscapesBox)
        #expect(run.result.pageOutput.textLayerEntries == nil)
        // The drop clears every field the writer reads, its laid-out lines
        // too; the same page as placed keeps them, so the drop is what clears them.
        let asPlaced = try await Self.run(source: .asPlaced, inputsFor: [0, 1, 2])
        #expect(asPlaced.result.pageOutput.hiddenTextLines != nil, "the page as placed has hidden text laid out")
        #expect(run.result.pageOutput.hiddenTextLines == nil, "the widened page writes no hidden text lines")
    }

    @Test("A box the check has nothing to read for paints as at \"as placed\", growth and all, marked not judged")
    func noInputsPaintsAsPlaced() async throws {
        let bare = try await Self.run(source: .switchPolicy, inputsFor: [])
        let placed = try await Self.run(source: .asPlaced, inputsFor: [])
        for i in 0...3 { #expect(try bare.reported(i) == placed.reported(i), "box \(i)") }
        #expect(bare.result.inkVerdicts == [0: .indeterminate, 1: .indeterminate, 2: .indeterminate])
        #expect(bare.result.fallbackReason == placed.result.fallbackReason)
        #expect(bare.result.fallbackReason != .inkEscapesBox)
    }

    @Test("A box the plan does not mark checkable, as one placed from the page's picture, is never judged and paints as at \"as placed\"")
    func uncheckableBoxNeverJudged() async throws {
        let picture = try await Self.run(source: .switchPolicy, inputsFor: [0, 1, 2], uncheckable: [0, 1, 2])
        let placed = try await Self.run(source: .asPlaced, inputsFor: [])
        #expect(picture.result.inkVerdicts.isEmpty, "\(picture.result.inkVerdicts)")
        for i in 0...3 { #expect(try picture.reported(i) == placed.reported(i), "box \(i)") }
        #expect(picture.result.fallbackReason != .inkEscapesBox)
        // The same page with its Search boxes checkable: box 0 is judged and widened.
        let typed = try await Self.run(source: .switchPolicy, inputsFor: [0, 1, 2])
        #expect(typed.result.inkVerdicts[0] == .escaped)
    }

    @Test("At \"as placed\" the check never runs, even with its inputs handed in")
    func asPlacedNeverChecks() async throws {
        let handed = try await Self.run(source: .asPlaced, inputsFor: [0, 1, 2])
        let bare = try await Self.run(source: .asPlaced, inputsFor: [])
        #expect(handed.result.inkVerdicts.isEmpty)
        for i in 0...3 { #expect(try handed.reported(i) == bare.reported(i), "box \(i)") }
        #expect(handed.result.fallbackReason == nil)
        #expect((handed.result.pageOutput.textLayerEntries?.count ?? 0) > 0)
    }
}
