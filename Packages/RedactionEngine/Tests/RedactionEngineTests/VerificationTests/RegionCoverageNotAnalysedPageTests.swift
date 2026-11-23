import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// The coverage check's re-run on a page it reads with nothing: a scanned page
// (a header-only text layer over a picture) re-run with text recognition off
// is neither read by its text layer nor by OCR, and the searcher says so only
// through its not-analysed signal. The check counts such a page under a box
// as unread (a Needs review naming the page), never as a page with no match.
// A text page carrying a picture the image census counts says the same when
// recognition is off: its layer is read, its picture by nothing.

@Suite("Search Re-check coverage: a page read by nothing", .tags(.search))
struct RegionCoverageNotAnalysedPageTests {

    /// The fixture's picture sits at (50, 520, 300 x 150) on a 612 x 792
    /// page; a box over its right 60 % touches the word in part only.
    static let shortBox = CGRect(x: (50 + 120) / 612.0, y: 520 / 792.0, width: 180 / 612.0, height: 150 / 792.0)

    static func box() -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: shortBox, source: .searchMatch(term: "SEED"))
    }

    @Test("A scanned page re-run with recognition off is unread, never passed; with recognition on it is read and its short box is a shortfall")
    func scannedPageWithRecognitionOff() async throws {
        let scanned = try #require(PDFDocument(data: TestFixtures.sparseHeaderScannedPagePDF(header: "Hdr", body: "SEED")))
        let page = try #require(scanned.page(at: 0))
        try #require(TextLayerDetector.detectTextLayer(page) == .sparse)
        let off = try await RegionCoverage.check(
            source: SendablePDFDocument(scanned),
            requests: [TestFixtures.textRequest("SEED", options: SearchOptions(includeOCR: false))],
            regions: [0: [Self.box()]])
        #expect(off.unreadPages == [0], "the page under a box, read by nothing, is unread; got \(off)")
        #expect(off.shortfalls.isEmpty, "\(off)")
        #expect(off.comparedMatches == 0, "\(off)")
        let on = try await RegionCoverage.check(
            source: SendablePDFDocument(scanned),
            requests: [TestFixtures.textRequest("SEED", options: SearchOptions())],
            regions: [0: [Self.box()]])
        #expect(on.unreadPages.isEmpty, "\(on)")
        #expect(!on.shortfalls.isEmpty, "the OCR-read match under a short box is a shortfall; got \(on)")
    }

    @Test("Recognition off: a scanned page the request's boxes are not on is not the check's question, and a text page beside it is read")
    func onlyThePagesWithTheRequestsBoxes() async throws {
        let text = try #require(PDFDocument(data: TestFixtures.textLayerPDF(text: "SEED 123 and more words here")))
        let scanned = try #require(PDFDocument(data: TestFixtures.sparseHeaderScannedPagePDF(header: "Hdr", body: "SEED")))
        let source = PDFDocument()
        source.insert(try #require(text.page(at: 0)), at: 0)
        source.insert(try #require(scanned.page(at: 0)), at: 1)
        try #require(source.pageCount == 2)
        let off = SearchOptions(includeOCR: false)
        let onlyText = try await RegionCoverage.check(
            source: SendablePDFDocument(source),
            requests: [TestFixtures.textRequest("SEED", options: off, pages: [0])],
            regions: [0: [Self.box()], 1: [Self.box()]])
        #expect(onlyText.unreadPages.isEmpty, "the scanned page holds none of this request's boxes; got \(onlyText)")
        let both = try await RegionCoverage.check(
            source: SendablePDFDocument(source),
            requests: [TestFixtures.textRequest("SEED", options: off, pages: [0, 1])],
            regions: [0: [Self.box()], 1: [Self.box()]])
        #expect(both.unreadPages == [1], "got \(both)")
    }

    @Test("Recognition off: a text page with a counted picture, under a box over its text-layer match, is unread")
    func textPageWithACountedPictureRecognitionOff() async throws {
        let stamped = try #require(PDFDocument(data: TestFixtures.stampedScanPDF()))
        let page = try #require(stamped.page(at: 0))
        try #require(TextLayerDetector.detectTextLayer(page) == .rich)
        try #require(PageImageCensus.carriesImageContent(page))
        let off = SearchOptions(includeOCR: false)
        let stream = DocumentSearcher().search(SendablePDFDocument(stamped), mode: .text("EXHIBIT", options: off), progress: { _, _ in })
        var matches: [SearchResult] = []
        for await result in stream { matches.append(result) }
        let match = try #require(matches.first, "the stamp is in the text layer")
        let box = RedactionRegion(
            id: UUID(), normalizedRect: match.normalizedRect.insetBy(dx: -0.01, dy: -0.01), source: .searchMatch(term: "EXHIBIT"))
        let outcome = try await RegionCoverage.check(
            source: SendablePDFDocument(stamped),
            requests: [TestFixtures.textRequest("EXHIBIT", options: off)],
            regions: [0: [box]])
        #expect(outcome.unreadPages == [0], "the layer is read but the picture by nothing: unread; got \(outcome)")
        #expect(outcome.shortfalls.isEmpty, "the box covers the text-layer match; got \(outcome)")
    }
}
