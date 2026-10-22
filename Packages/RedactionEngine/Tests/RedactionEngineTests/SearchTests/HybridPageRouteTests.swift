import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// A page with a text layer that also carries page-scale image content is read
// on both legs: the text layer, then the recognised text of the image. The
// recognised lines are seeded (`_testSeedOCRLines`), so no Vision runs; the
// body's words exist only in the image. An OCR result that repeats a
// text-layer result is dropped; with text recognition off the page is
// reported once as not fully analysed; a born-digital letter with a small
// logo runs no OCR leg.
//
// Privacy rule (audit-lint M-1): locate/read/report vocabulary.

@Suite("Hybrid page route", .tags(.search))
struct HybridPageRouteTests {

    /// The stamp's recognised line sits where the text layer draws it (y 760
    /// of 792); the body lines sit mid-page.
    static let stampLine = OCREngine.TextLine(
        text: "EXHIBIT B - 000123", normalizedRect: CGRect(x: 0.11, y: 0.955, width: 0.25, height: 0.025), confidence: 0.9)
    static let nameLine = OCREngine.TextLine(
        text: "Patient: Maria Johnson", normalizedRect: CGRect(x: 0.12, y: 0.50, width: 0.40, height: 0.03), confidence: 0.9)
    static let ssnLine = OCREngine.TextLine(
        text: "SSN 123-45-6789", normalizedRect: CGRect(x: 0.12, y: 0.44, width: 0.30, height: 0.03), confidence: 0.9)

    private actor PageCollector {
        var pages: [Int] = []
        func add(_ page: Int) { pages.append(page) }
    }

    private static func run(
        _ data: Data, mode: SearchMode, lines: [OCREngine.TextLine] = [stampLine, nameLine, ssnLine]
    ) async throws -> (results: [SearchResult], notAnalysed: [Int]) {
        let doc = try #require(PDFDocument(data: data))
        let searcher = DocumentSearcher()
        await searcher._testSeedOCRLines(lines, forPageIndex: 0)
        let collector = PageCollector()
        await searcher.setScannedRegionNotAnalyzedSink { index in Task { await collector.add(index) } }
        let stream = searcher.search(SendablePDFDocument(doc), mode: mode, progress: { _, _ in })
        var results: [SearchResult] = []
        for await result in stream { results.append(result) }
        try await Task.sleep(for: .milliseconds(50))
        return (results, await collector.pages)
    }

    private static func isOCR(_ result: SearchResult) -> Bool {
        if case .ocr = result.source { return true }
        return false
    }

    @Test("The stamped scan keeps its text-layer status")
    func stampedScanIsRich() throws {
        for data in [TestFixtures.stampedScanPDF(), TestFixtures.vendorLayerOverScanPDF(), TestFixtures.letterWithLogoPDF()] {
            let page = try #require(PDFDocument(data: data)?.page(at: 0))
            #expect(TextLayerDetector.detectTextLayer(page) == .rich)
        }
    }

    @Test("Text mode on a stamped scan locates the body's term through the recognised text")
    func textModeFindsTheBody() async throws {
        let (hits, _) = try await Self.run(TestFixtures.stampedScanPDF(), mode: .text("Maria Johnson", options: SearchOptions(includeOCR: true)))
        #expect(hits.count == 1, "\(hits.map(\.matchedText))")
        #expect(hits.first.map(Self.isOCR) == true)
    }

    @Test("A vendor text layer over a scan: the image marks the page, so the body is read")
    func vendorLayerOverScanFindsTheBody() async throws {
        let (hits, _) = try await Self.run(TestFixtures.vendorLayerOverScanPDF(), mode: .text("Maria Johnson", options: SearchOptions(includeOCR: true)))
        #expect(hits.count == 1, "\(hits.map(\.matchedText))")
    }

    @Test("The stamp is found once, from the text layer; its recognised duplicate is dropped")
    func stampFoundOnce() async throws {
        let (hits, _) = try await Self.run(TestFixtures.stampedScanPDF(), mode: .text("EXHIBIT", options: SearchOptions(includeOCR: true)))
        #expect(hits.count == 1, "\(hits.map { "\($0.matchedText) \($0.source)" })")
        #expect(hits.first?.source == .textLayer)
    }

    @Test("Regex mode on a stamped scan locates the body's number")
    func regexModeFindsTheBody() async throws {
        let (hits, _) = try await Self.run(TestFixtures.stampedScanPDF(), mode: .regex(#"\d{3}-\d{2}-\d{4}"#, options: SearchOptions(includeOCR: true)))
        #expect(hits.count == 1, "\(hits.map(\.matchedText))")
        #expect(hits.first.map(Self.isOCR) == true)
    }

    @Test("Scan mode on a stamped scan locates the body's number once")
    func scanModeFindsTheBody() async throws {
        let (hits, _) = try await Self.run(TestFixtures.stampedScanPDF(), mode: .piiScan(categories: [.ssn], options: SearchOptions(includeOCR: true)))
        #expect(hits.count == 1, "\(hits.map(\.matchedText))")
        #expect(hits.first.map(Self.isOCR) == true)
    }

    @Test("Any-term mode on a stamped scan locates the body's terms")
    func multiTermFindsTheBody() async throws {
        let (hits, _) = try await Self.run(TestFixtures.stampedScanPDF(), mode: .multiTerm(["Maria", "Johnson"], options: SearchOptions(includeOCR: true)))
        #expect(hits.count == 2, "\(hits.map(\.matchedText))")
        #expect(hits.allSatisfy(Self.isOCR))
    }

    @Test("A born-digital letter with a small logo runs no OCR leg")
    func logoPageRunsNoOCR() async throws {
        let (hits, notAnalysed) = try await Self.run(TestFixtures.letterWithLogoPDF(), mode: .text("Maria Johnson", options: SearchOptions(includeOCR: true)))
        #expect(hits.isEmpty, "the seeded decoy line was read: \(hits.map(\.matchedText))")
        #expect(notAnalysed.isEmpty)
    }

    @Test("With text recognition off, a stamped scan is reported once as not fully analysed")
    func ocrOffReportsOnce() async throws {
        let (hits, notAnalysed) = try await Self.run(TestFixtures.stampedScanPDF(), mode: .text("Maria Johnson", options: SearchOptions(includeOCR: false)))
        #expect(hits.isEmpty)
        #expect(notAnalysed == [0], "\(notAnalysed)")
    }

    @Test("The live preview counts the text layer only on a stamped scan (stated behaviour)")
    func previewCountsTheTextLayer() async throws {
        let doc = try #require(PDFDocument(data: TestFixtures.stampedScanPDF()))
        let texts: [String?] = [doc.page(at: 0)?.string]
        let preview = await DocumentSearcher().previewMatches(
            mode: .text("Maria Johnson", options: SearchOptions(includeOCR: true)), scope: .wholeDocument,
            currentPageIndex: 0, totalPageCount: 1, pageTextProvider: { index in texts[index] })
        #expect(preview.totalCount == 0)
    }
}
