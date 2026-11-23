import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import RedactionEngine

// A page whose record's sides are not its own. The app reads the record and
// the page data at run entry, one after the other, from the same document;
// here the page is changed between the two reads, so they disagree as they
// would if either read differed. The pre-flight refuses the page by name
// before it is rendered; it never paints the page by its regions alone.

@Suite("A page whose sides are not its record's is refused by name")
struct PageSidesNotAsRecordedTests {
    typealias P = PlanPaintTests

    enum Change: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case turnedAQuarter, cropCut
        var testDescription: String {
            switch self {
            case .turnedAQuarter: "turned a quarter after the record"
            case .cropCut: "its crop box cut after the record"
            }
        }
    }

    /// The page's data after `change`, with the record made before it; nil
    /// change leaves the page as the record found it.
    static func pageData(after change: Change?) throws -> PDFPageData {
        let doc = try #require(PDFDocument(data: P.pdf(ink: [])))
        let page = try #require(doc.page(at: 0))
        let box = CGRect(x: 40.3, y: 50.7, width: 50.1, height: 20.2)
        let id = UUID()
        let drawn = [RunRecord.DrawnRegion(id: id, normalizedRect: P.share(box))]
        let confirmed = RunRecord.Page(pageIndex: 0, regions: drawn, cropBox: page.bounds(for: .cropBox).size,
                                       rotation: page.rotation)
        switch change {
        case .turnedAQuarter: page.rotation = 90
        case .cropCut: page.setBounds(CGRect(x: 0, y: 0, width: P.width - 36, height: P.height), for: .cropBox)
        case nil: break
        }
        let region = RedactionRegion(id: id, normalizedRect: P.share(box).clampedToNormalized(), source: .manual)
        return PDFPageData(
            page: page, pageIndex: 0, regions: [region], fillColor: .black, targetDPI: P.dpi,
            pipelineMode: .secureRasterization, rotation: page.rotation,
            cropBoxBounds: page.bounds(for: .cropBox), cgPage: page.pageRef, hasText: false, confirmedPage: confirmed)
    }

    @Test("The page is refused by name before it is rendered", arguments: Change.allCases)
    func refusedWhenChanged(_ change: Change) async throws {
        let data = try Self.pageData(after: change)
        var refusedPage: Int?
        do {
            _ = try await PageRasterizer().rasterize(data, dpiCap: P.dpi)
        } catch PipelineError.redactionError(.pageSidesNotAsRecorded(let p)) {
            refusedPage = p
        }
        #expect(refusedPage == 0, "\(change): the page is refused by name")
    }

    @Test("The same page unchanged is painted by its plan and not refused")
    func unchangedIsPainted() async throws {
        let result = try await PageRasterizer().rasterize(try Self.pageData(after: nil), dpiCap: P.dpi)
        #expect(result.paintedBoxes.count == 1 && result.regionsPaintedOutsideThePlan.isEmpty)
    }
}
