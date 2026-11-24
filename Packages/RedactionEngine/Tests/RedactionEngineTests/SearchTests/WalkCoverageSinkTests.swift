import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// A walk reports into the coverage sink that was set when it started. A sink
// set later belongs to a later run: the walk in flight never reports into it.

@Suite("A walk keeps the coverage sink it started with", .tags(.search))
struct WalkCoverageSinkTests {

    /// Four typed pages: each one a copy of the page `PageCoverageReportTests` reads from its text.
    static func fourTypedPages() throws -> PDFDocument {
        let data = PageCoverageReportTests.pdf(picture: nil, text: PageCoverageReportTests.typed, hidden: false)
        let document = try #require(PDFDocument(data: data))
        let first = try #require(document.page(at: 0))
        for index in 1..<4 {
            let copy = try #require(first.copy() as? PDFPage)
            document.insert(copy, at: index)
        }
        #expect(document.pageCount == 4)
        return document
    }

    @Test("A sink set while a walk is under way gets none of its reports; the walk's own sink gets every page")
    func laterSinkGetsNothing() async throws {
        let document = try Self.fourTypedPages()
        let searcher = DocumentSearcher()
        let own = PageCoverageReportTests.Reports()
        let later = PageCoverageReportTests.Reports()
        // The walk's own sink sets a later run's sink on the first report it
        // takes. It runs on the searcher's actor, inside the walk.
        await searcher.setPageCoverageSink { [searcher] coverage in
            own.record(coverage)
            if coverage.pageIndex == 0 {
                searcher.assumeIsolated { $0.pageCoverageSink = { later.record($0) } }
            }
        }
        for await _ in searcher.search(SendablePDFDocument(document), mode: .text("statement", options: SearchOptions()),
                                       progress: { _, _ in }) {}
        #expect(Set(own.all.map(\.pageIndex)) == [0, 1, 2, 3])
        #expect(own.all.allSatisfy { $0.route == .textLayer })
        #expect(later.all.isEmpty, "\(later.all)")
    }

    @Test("On pages read by recognition, a sink set while the walk is under way gets none of its reports")
    func laterSinkGetsNothingOnRecognisedPages() async throws {
        let document = try #require(PDFDocument(data: TestFixtures.imageOnlyPDF()))
        let first = try #require(document.page(at: 0))
        let copy = try #require(first.copy() as? PDFPage)
        document.insert(copy, at: 1)
        let searcher = DocumentSearcher()
        let line = OCREngine.TextLine(text: "statement", normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.04),
                                      confidence: 0.9)
        await searcher._testSeedOCRLines([line], forPageIndex: 0)
        await searcher._testSeedOCRLines([line], forPageIndex: 1)
        let own = PageCoverageReportTests.Reports()
        let later = PageCoverageReportTests.Reports()
        await searcher.setPageCoverageSink { [searcher] coverage in
            own.record(coverage)
            if coverage.pageIndex == 0 {
                searcher.assumeIsolated { $0.pageCoverageSink = { later.record($0) } }
            }
        }
        for await _ in searcher.search(SendablePDFDocument(document), mode: .text("statement", options: SearchOptions(includeOCR: true)),
                                       progress: { _, _ in }) {}
        #expect(Set(own.all.filter { $0.route == .ocr }.map(\.pageIndex)) == [0, 1], "\(own.all)")
        #expect(later.all.isEmpty, "\(later.all)")
    }
}
