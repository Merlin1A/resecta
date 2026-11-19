import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import RedactionEngine

// The writer's list of rectangles and the position check's list are the same
// list: on every page a run writes as Searchable, the rectangles the writer
// reports (`PageOutput.redactionRectsInPoints`) are the check's rectangles of
// the first two kinds (ordinary and the plan's rectangle), rectangle for
// rectangle in order, to within 0.01 pt. The check makes its list from the
// run's record and the output page's own box; the writer from the source
// page. The test prints the largest difference it saw.

@Suite("The writer's list is the position check's list")
struct PositionCheckListTests {

    struct Export {
        let name: String
        let page: PDFPage
        let regions: [RedactionRegion]
    }

    /// A typed page with a box from a search.
    static func typedWithSearchBox() throws -> Export {
        let doc = try #require(PDFDocument(data: TestFixtures.textLayerPDF()))
        let page = try #require(doc.page(at: 0))
        return Export(name: "typed page, search box", page: page, regions: [try searchBox("Smith", on: page)])
    }

    /// A page of hidden text over a picture, whose box has a hidden letters'
    /// rectangle.
    static func hiddenLettersRectangle() throws -> Export {
        let f = try HiddenGlyphStripTests.fixture()
        return Export(name: "hidden letters' rectangle", page: f.page,
                      regions: [HiddenGlyphStripTests.region(f.paint, strip: f.strip)])
    }

    /// The same page, its box carrying the run's ink strips.
    static func inkStrips() throws -> Export {
        let f = try HiddenGlyphStripTests.fixture()
        var region = HiddenGlyphStripTests.region(f.paint, strip: nil)
        region.inkStripRects = [f.strip]
        return Export(name: "ink strips", page: f.page, regions: [region])
    }

    /// A typed page turned 90, with a box from a search.
    static func turned() throws -> Export {
        let stream = "BT /F1 24 Tf 72 700 Td (Keep Secret Words) Tj ET"
        let data = buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Rotate 90 "
                + "/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>"),
            PDFObject(id: 4, content: "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"),
            PDFObject(id: 5, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"),
        ], rootId: 1)
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        return Export(name: "page turned 90", page: page, regions: [try searchBox("Secret", on: page)])
    }

    /// A typed page with no box.
    static func noBox() throws -> Export {
        let doc = try #require(PDFDocument(data: TestFixtures.textLayerPDF()))
        return Export(name: "no box", page: try #require(doc.page(at: 0)), regions: [])
    }

    static func searchBox(_ term: String, on page: PDFPage) throws -> RedactionRegion {
        let range = ((page.string ?? "") as NSString).range(of: term)
        try #require(range.location != NSNotFound, "\(term) is on the page")
        let selection = try #require(page.selection(for: range))
        let rect = try #require(DocumentSearcher().normalizedRect(for: selection, page: page))
        return RedactionRegion(id: UUID(), normalizedRect: rect, source: .searchMatch(term: term))
    }

    struct Written {
        let writer: [CGRect]
        let output: PDFDocument
        let record: RunRecord
        let searchable: Bool
    }

    /// The page through the writer and into an export, with its record's
    /// page made as a run makes it.
    static func write(_ e: Export) async throws -> Written {
        let result = try await PageRasterizer().rasterize(
            HiddenGlyphStripTests.pageData(e.page, e.regions, mode: .searchableRedaction))
        let output = result.pageOutput
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("position_list_\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = PDFStreamReconstructor(tempURL: url)
        try await writer.begin(firstPageSize: output.size)
        try await writer.appendPage(output)
        await writer.finalize()
        let exported = try #require(PDFDocument(data: try Data(contentsOf: url)), "\(e.name): the export opens")
        let crop = e.page.bounds(for: .cropBox)
        let page = RunRecord.Page(
            pageIndex: 0,
            regions: e.regions.map { RunRecord.DrawnRegion(id: $0.id, normalizedRect: $0.normalizedRect) },
            cropBox: crop.size, rotation: e.page.rotation, switchOn: false)
        let record = RunRecord(
            confirmed: RunRecord.Confirmed(fillColor: .black, exportDPI: 300, pages: [page]),
            produced: RunRecord.Produced())
        return Written(writer: output.redactionRectsInPoints, output: exported, record: record,
                       searchable: output.textLayerEntries != nil)
    }

    static func difference(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.maxX - b.maxX), abs(a.maxY - b.maxY))
    }

    @Test("Five exports: the writer's list is the check's list of the first two kinds", .timeLimit(.minutes(2)))
    func writerListIsTheChecksList() async throws {
        let exports = [try Self.typedWithSearchBox(), try Self.hiddenLettersRectangle(), try Self.inkStrips(),
                       try Self.turned(), try Self.noBox()]
        #expect(exports.count == 5)
        var largest: CGFloat = 0
        var compared = 0
        for e in exports {
            let w = try await Self.write(e)
            try #require(w.searchable, "\(e.name): the run wrote the page as Searchable")
            let outputPage = try #require(w.output.page(at: 0))
            let boxes = w.record.confirmed.pages[0].plan?.boxes ?? []
            let list = VerificationEngine().layer6Shapes(
                regions: e.regions, outputBounds: outputPage.bounds(for: .cropBox), boxes: boxes)
            let check = list.filter { $0.kind != .underWidenedBox }.map(\.shape.bounds)
            #expect(w.writer.count == check.count,
                    "\(e.name): the writer reports \(w.writer.count) rectangles, the check lists \(check.count)\nwriter \(w.writer)\ncheck \(check)")
            for (a, b) in zip(w.writer, check) {
                let d = Self.difference(a, b)
                largest = max(largest, d)
                #expect(d <= 0.01, "\(e.name): writer \(a), check \(b), difference \(d)")
            }
            if compared == 0 {
                // The first export, read by the position check with its
                // record: no character sits in the box. A character beside
                // its edge may be noted, as it is today; the row does not
                // fail.
                let row = await VerificationEngine().runLayer(
                    .spatialVerification, outputDocument: SendablePDFDocument(w.output),
                    sourcePageCount: 1, regions: [0: e.regions], sensitiveTerms: [],
                    pipelineMode: .searchableRedaction, filterDigests: [], perPageModes: [.searchableRedaction],
                    record: w.record)
                #expect(!row.status.isFail, "\(e.name): the position check reads \(row.status)")
            }
            compared += 1
        }
        print("The writer's list and the check's list: largest difference \(largest) pt over \(compared) exports")
        #expect(compared == 5)
    }
}
