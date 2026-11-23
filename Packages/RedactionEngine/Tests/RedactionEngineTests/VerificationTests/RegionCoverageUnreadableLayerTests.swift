import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// The coverage check's re-run on a page whose text layer Search cannot read
// (an unresolved encoding: the layer holds a few letters repeated, the page's
// words are ink only). The import reads such a page `.rich`, but Search routes
// it as `.sparse`: by OCR, or reported not analysed with OCR off. The re-run
// routes it the same way, so a box placed from Search's OCR read is measured
// against that read, not against a layer that holds none of the page's words.

@Suite("Search Re-check coverage: a page whose text layer Search cannot read", .tags(.search))
struct RegionCoverageUnreadableLayerTests {

    /// The fixture, checked to be the case: `.rich`, unreadable for Search, no picture.
    static func page() throws -> PDFDocument {
        let document = try #require(PDFDocument(data: TestFixtures.garbledLayerOutlinedWordPDF()))
        let page = try #require(document.page(at: 0))
        try #require(TextLayerDetector.detectTextLayer(page) == .rich)
        try #require(TextLayerDetector.unreadableForSearch(page))
        try #require(!PageImageCensus.carriesImageContent(page))
        try #require(!(page.string ?? "").contains("SEED"))
        return document
    }

    /// The match as Search placed it: the page routed `.sparse`, read by OCR.
    static func searchedRect(_ document: PDFDocument) async throws -> CGRect {
        let searcher = DocumentSearcher(textLayerStatusByPage: [0: .sparse])
        var rects: [CGRect] = []
        for await result in searcher.search(SendablePDFDocument(document), mode: .text("SEED", options: SearchOptions()), progress: { _, _ in }) where result.hasBox {
            rects.append(result.normalizedRect)
        }
        return try #require(rects.count == 1 ? rects.first : nil, "Search reads the word once by OCR; got \(rects)")
    }

    static func box(_ rect: CGRect) -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: rect, source: .searchMatch(term: "SEED"))
    }

    @Test("A box short of Search's OCR match on a page whose layer Search cannot read is a shortfall; a box over the whole match passes")
    func shortBoxIsAShortfall() async throws {
        let document = try Self.page()
        let match = try await Self.searchedRect(document)
        let short = CGRect(x: match.minX + match.width * 0.4, y: match.minY, width: match.width * 0.6, height: match.height)
        let request = TestFixtures.textRequest("SEED", options: SearchOptions())
        let shortOutcome = try await RegionCoverage.check(
            source: SendablePDFDocument(document), requests: [request], regions: [0: [Self.box(short)]])
        #expect(!shortOutcome.shortfalls.isEmpty, "the OCR-read match under a short box is a shortfall; got \(shortOutcome)")
        #expect(shortOutcome.unreadPages.isEmpty, "\(shortOutcome)")
        let whole = try await RegionCoverage.check(
            source: SendablePDFDocument(document), requests: [request],
            regions: [0: [Self.box(match.insetBy(dx: -0.01, dy: -0.01))]])
        #expect(whole.shortfalls.isEmpty, "\(whole)")
        #expect(whole.unreadPages.isEmpty, "\(whole)")
        #expect(whole.comparedMatches == 1, "\(whole)")
    }

    @Test("With recognition off, a page whose layer Search cannot read is unread under a box, as Search reports it not analysed")
    func recognitionOffIsUnread() async throws {
        let document = try Self.page()
        let outcome = try await RegionCoverage.check(
            source: SendablePDFDocument(document),
            requests: [TestFixtures.textRequest("SEED", options: SearchOptions(includeOCR: false))],
            regions: [0: [Self.box(CGRect(x: 0.1, y: 0.7, width: 0.3, height: 0.06))]])
        #expect(outcome.unreadPages == [0], "got \(outcome)")
    }
}
