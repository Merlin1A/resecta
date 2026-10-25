import Testing
import Foundation
import PDFKit
import CoreGraphics
import CoreText
@testable import RedactionEngine

// A phrase on a scanned page that runs from the end of one recognised line
// into the next. The OCR matcher searches each recognised line on its own, so
// before the cross-line pass such a phrase was never found, and the Search
// Re-check (which re-runs the same searcher on the output) read the page as
// clear. Vision-backed, simulator-only like the other OCR suites.

@Suite("OCR phrase across two lines", .serialized)
struct OCRCrossLinePhraseTests {

    /// An image of two left-aligned lines, the first ending "Jane", the
    /// second starting "Doe".
    static func twoLineImage(width: Int = 1600, height: Int = 1200, fontSize: CGFloat = 96) throws -> CGImage {
        let ctx = try #require(createBitmapContext(width: width, height: height))
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.textMatrix = .identity
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        for (text, y) in [("Please contact Jane", 0.62), ("Doe about the claim", 0.42)] {
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font]))
            ctx.textPosition = CGPoint(x: CGFloat(width) * 0.06, y: CGFloat(height) * y)
            CTLineDraw(line, ctx)
        }
        return try #require(ctx.makeImage())
    }

    static func scannedPage() async throws -> (PDFDocument, URL) {
        let (doc, url) = try await TestFixtures.imagePagesPDF([try twoLineImage()], size: CGSize(width: 1600, height: 1200),
                                                              prefix: "crossline_")
        #expect((doc.page(at: 0)?.string ?? "").isEmpty, "the fixture carries no text layer")
        return (doc, url)
    }

    static func search(_ doc: PDFDocument, _ mode: SearchMode) async -> [SearchResult] {
        var out: [SearchResult] = []
        for await result in DocumentSearcher().search(SendablePDFDocument(doc), mode: mode, progress: { _, _ in }) {
            out.append(result)
        }
        return out
    }

    static func ocrOptions() -> SearchOptions {
        var options = SearchOptions()
        options.includeOCR = true
        return options
    }

    @Test("a phrase that crosses two recognised lines is found and boxed on both lines")
    func crossLinePhraseFound() async throws {
        let (doc, url) = try await Self.scannedPage()
        defer { try? FileManager.default.removeItem(at: url) }
        let hits = await Self.search(doc, .text("Jane Doe", options: Self.ocrOptions()))
        try #require(hits.count == 2, "one result per line the phrase touches; got \(hits.map(\.matchedText))")
        #expect(hits[0].occurrenceID != nil && hits[0].occurrenceID == hits[1].occurrenceID, "the two lines are one occurrence")
        #expect(hits.allSatisfy { $0.matchedText == "Jane Doe" })
        #expect(abs(hits[0].normalizedRect.midY - hits[1].normalizedRect.midY) > 0.05, "a box on each line")
        // Each line's box is the matched word, not the line: "Jane"'s box
        // leaves "contact" out, "Doe"'s leaves "about" out. The page is the
        // image at its own size, so the image's word boxes are the page's.
        let tokens = try OCREngine.recognizeTokens(in: try Self.twoLineImage())
        let contact = try #require(tokens.first { $0.text == "contact" }?.normalizedRect)
        let about = try #require(tokens.first { $0.text == "about" }?.normalizedRect)
        #expect(!hits.contains { $0.normalizedRect.intersects(contact) }, "a box covers \"contact\": \(hits.map(\.normalizedRect))")
        #expect(!hits.contains { $0.normalizedRect.intersects(about) }, "a box covers \"about\": \(hits.map(\.normalizedRect))")
        // The same through the multi-term route.
        let multi = await Self.search(doc, .multiTerm(["Jane Doe", "claim"], options: Self.ocrOptions()))
        #expect(multi.filter { $0.term == "Jane Doe" }.count == 2)
    }

    @Test("a phrase inside one recognised line is found as before: one result, no occurrence")
    func singleLinePhraseUnchanged() async throws {
        let (doc, url) = try await Self.scannedPage()
        defer { try? FileManager.default.removeItem(at: url) }
        let hits = await Self.search(doc, .text("contact Jane", options: Self.ocrOptions()))
        #expect(hits.count == 1 && hits[0].occurrenceID == nil, "got \(hits.map(\.matchedText))")
    }

    @Test("the Search Re-check reads a crossing phrase left on the output as remaining")
    func recheckSeesALeftCrossingPhrase() async throws {
        let (doc, url) = try await Self.scannedPage()
        defer { try? FileManager.default.removeItem(at: url) }
        let result = await TestFixtures.recheck(
            SendablePDFDocument(doc), requests: [TestFixtures.textRequest("Jane Doe")], mode: .secureRasterization)
        #expect(result.status == .attention(""), "a printed crossing phrase must not read as clear; got \(result.status)")
        #expect(result.queryLines?.first?.remainingCount ?? 0 >= 1)
    }
}
