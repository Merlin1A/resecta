import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// Text recognition on iOS 27 can read a space beside a separator inside a
// digit run ("1-800- 555-0199" for "1-800-555-0199"). On iOS 27 the OCR
// literal path folds that space before matching, so a typed number still
// matches its line; the match is boxed by the whole line, as every OCR
// literal match is. iOS 26 reads keep their text.

@Suite("OCR literal search: a space beside a separator", .tags(.search))
struct OCRSeparatorSpaceFoldTests {

    @Test("The fold removes one space beside a separator between digits", arguments: [
        ("1-800- 555-0199", "1-800-555-0199"),
        ("208 -555-0147", "208-555-0147"),
        ("05/ 01/1984", "05/01/1984"),
        ("208.555 .0147", "208.555.0147"),
    ])
    func folds(read: String, folded: String) {
        #expect(TextNormalizer.foldOCRSeparatorSpaces(read) == folded)
    }

    @Test("Spaces that are not beside a separator inside a digit run stay", arguments: [
        "1-800-555-0199",
        "2026 - 05 - 31",
        "Fees - $12.00",
        "call us at 1-800  555-0199",
        "page 3 - see below",
        "208 555 0147",
    ])
    func keeps(text: String) {
        #expect(TextNormalizer.foldOCRSeparatorSpaces(text) == text)
    }

    @Test("A typed number matches the iOS 27 read of its line, boxed by the line; iOS 26 is unchanged")
    func typedNumberFindsTheSpacedRead() async throws {
        let doc = try #require(PDFDocument(data: TestFixtures.imageOnlyPDF()))
        let page = try #require(doc.page(at: 0))
        let lineRect = CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.03)
        let searcher = DocumentSearcher()
        await searcher._testSeedOCRLines(
            [OCREngine.TextLine(text: "please call us at 1-800- 555-0199 so we can keep",
                                normalizedRect: lineRect, confidence: 0.5)],
            forPageIndex: 0)
        var results: [SearchResult] = []
        for await result in searcher.search(SendablePDFDocument(doc), mode: .text("1-800-555-0199", options: SearchOptions()),
                                            progress: { _, _ in }) {
            results.append(result)
        }
        if #available(iOS 27, *) {
            #expect(results.count == 1)
            #expect(results.first?.normalizedRect == DocumentSearcher.paddedNormalizedRect(lineRect, in: page),
                    "the match is boxed by its OCR line")
            #expect(results.first?.matchedText == "1-800-555-0199")
        } else {
            #expect(results.isEmpty, "iOS 26 reads keep their text")
        }
    }
    @Test("A query typed with a space beside a separator matches a line read the same way, on iOS 27 as on iOS 26")
    func spacedQueryFindsTheSpacedRead() async throws {
        let doc = try #require(PDFDocument(data: TestFixtures.imageOnlyPDF()))
        let searcher = DocumentSearcher()
        await searcher._testSeedOCRLines(
            [OCREngine.TextLine(text: "Phone 555 -0147 after five", normalizedRect: CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.03),
                                confidence: 0.5)],
            forPageIndex: 0)
        var results: [SearchResult] = []
        for await result in searcher.search(SendablePDFDocument(doc), mode: .text("555 -0147", options: SearchOptions()),
                                            progress: { _, _ in }) {
            results.append(result)
        }
        #expect(results.count == 1, "the query is folded as the line is: \(results.map(\.matchedText))")
    }
}
