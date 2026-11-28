import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import RedactionCore
@testable import RedactionEngine

// A box painted with its default band, from 38 to 180 pt along a 12 pt line,
// whose line margin stops at 62 pt. The producer reads the page's picture
// before any fill: ink in the band that its line margin does not hold
// withdraws the band, and the box is painted with its line margin.

@Suite("The default band's net on the page's picture")
struct DefaultBandNetTests {
    typealias S = PlanSwitchTests

    static let regionRect = CGRect(x: 40, y: 38, width: 20, height: 12)
    static let bandRect = CGRect(x: 38, y: 37, width: 142, height: 14)
    static let marginRect = CGRect(x: 38, y: 37, width: 24, height: 14)

    static func box(_ id: UUID, paint: CGRect, width: DefaultWidth) -> PaintedBox {
        PaintedBox(regionIDs: [id], inner: S.rect64(regionRect), paint: S.rect64(paint), tight: S.rect64(regionRect),
                   limitAbove: nil, limitBelow: nil, exposure: GeometryPolicy.release.asPlaced.exposure,
                   treatment: .notAsked, bandMade: width == .taken, inkEnlargedCovered: false,
                   inkEnlargedToCap: false, asDrawn: false, defaultWidth: width)
    }

    struct Painted {
        let result: RasterizeResult
        let reported: PixelPlan.PixelRect
        let band: PixelPlan.PixelRect
        let margin: PixelPlan.PixelRect
    }

    static func run(marks: [CGRect]) async throws -> Painted {
        let doc = try #require(PDFDocument(data: S.pdf(bars: marks)))
        defer { withExtendedLifetime(doc) {} }
        let page = try #require(doc.page(at: 0))
        let id = UUID()
        let region = RedactionRegion(id: id, normalizedRect: S.share(regionRect), source: .manual)
        let banded = box(id, paint: bandRect, width: .taken)
        let lineMargin = box(id, paint: marginRect, width: .notTaken(.inkInSlot))
        let plan = PaintPlan(widthSixtyFourths: Int(S.width) * 64, heightSixtyFourths: Int(S.height) * 64,
                             boxes: [banded])
        var data = PDFPageData(
            page: page, pageIndex: 0, regions: [region], fillColor: .black, targetDPI: S.dpi,
            pipelineMode: .secureRasterization, rotation: page.rotation,
            cropBoxBounds: page.bounds(for: .cropBox), cgPage: page.pageRef, hasText: true,
            confirmedPage: RunRecord.Page(pageIndex: 0, regions: [RunRecord.DrawnRegion(region: region)], plan: plan,
                                          defaultFallbacks: [0: lineMargin]))
        data.planSource = .switchPolicy
        let result = try await PageRasterizer().rasterize(data, dpiCap: S.dpi)
        let raster = try #require(PixelPlan.Raster(widthSixtyFourths: plan.widthSixtyFourths,
                                                   heightSixtyFourths: plan.heightSixtyFourths, dpi: S.dpi))
        func projected(_ b: PaintedBox) throws -> PixelPlan.PixelRect {
            try #require(PixelPlan.project(inner: b.inner, paint: b.paint, limitAbove: b.limitAbove,
                                           limitBelow: b.limitBelow, raster: raster)).painted
        }
        let p = try #require(result.paintedBoxes[0])
        return Painted(result: result,
                       reported: PixelPlan.PixelRect(minX: p.firstColumn, minY: p.firstRowFromBottom,
                                                     maxX: p.firstColumn + p.columns, maxY: p.firstRowFromBottom + p.rows),
                       band: try projected(banded), margin: try projected(lineMargin))
    }

    @Test("A blank slot keeps the default band")
    func blankSlotKeepsTheBand() async throws {
        let painted = try await Self.run(marks: [CGRect(x: 44, y: 41, width: 12, height: 6)])
        #expect(painted.result.defaultBandsWithdrawn.isEmpty)
        #expect(painted.reported == painted.band)
    }

    @Test("A mark in the slot the page's painting did not place withdraws the band: the box is painted with its line margin")
    func markInTheSlotWithdrawsTheBand() async throws {
        let painted = try await Self.run(marks: [CGRect(x: 44, y: 41, width: 12, height: 6),
                                                CGRect(x: 120, y: 42, width: 2, height: 4)])
        #expect(painted.result.defaultBandsWithdrawn == [0])
        #expect(painted.reported == painted.margin)
        var produced = RunRecord.Produced()
        produced.record(painted.result, pageIndex: 2)
        #expect(produced.defaultBandsWithdrawn == [RunRecord.BoxPosition(pageIndex: 2, box: 0)])
    }

    @Test("The box check judges a withdrawn box by the line margin the record made with its plan, and any other by its band")
    func boxCheckReadsTheWithdrawal() throws {
        let id = UUID()
        let banded = Self.box(id, paint: Self.bandRect, width: .taken)
        let lineMargin = Self.box(id, paint: Self.marginRect, width: .notTaken(.inkInSlot))
        let plan = PaintPlan(widthSixtyFourths: Int(S.width) * 64, heightSixtyFourths: Int(S.height) * 64,
                             boxes: [banded])
        let page = RunRecord.Page(pageIndex: 0, regions: [], plan: plan, defaultFallbacks: [0: lineMargin])
        var produced = RunRecord.Produced()
        let kept = RunRecord(confirmed: RunRecord.Confirmed(fillColor: .black, exportDPI: S.dpi, pages: [page]),
                             produced: produced)
        #expect(try #require(BoxCheckInput(record: kept)).pages[0].boxes == [banded])
        produced.defaultBandsWithdrawn = [RunRecord.BoxPosition(pageIndex: 0, box: 0)]
        let withdrawn = RunRecord(confirmed: RunRecord.Confirmed(fillColor: .black, exportDPI: S.dpi, pages: [page]),
                                  produced: produced)
        #expect(try #require(BoxCheckInput(record: withdrawn)).pages[0].boxes == [lineMargin])
    }
}
