import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// Text recognition on iOS 27 can read a space beside a separator inside a
// digit run ("1-800- 555-0199" for "1-800-555-0199"). On iOS 27 the OCR
// literal path folds that space before matching, so a typed number still
// matches its line; the match is boxed on the words it covers, at the
// line's own offsets, or by the whole line when its words have no box.
// iOS 26 reads keep their text.

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

    @Test("The mapped fold's map leads each unit of the folded text back to its place in the read text", arguments: [
        "1-800- 555-0199", "Ref 1- 2- 3- 4 call 555- 0147 now", "208 -555-0147 and 05/ 01/1984", "1-800-555-0199", "",
    ])
    func mappedFoldLeadsBack(text: String) {
        let (folded, map) = TextNormalizer.foldOCRSeparatorSpacesMapped(text)
        let read = text as NSString, target = folded as NSString
        guard let map else {
            #expect(folded == text, "nothing folded, no map")
            return
        }
        #expect(map.count == target.length + 1 && map.last == read.length)
        #expect((0..<target.length).allSatisfy { read.character(at: map[$0]) == target.character(at: $0) })
        #expect(zip(map, map.dropFirst()).allSatisfy { $0 < $1 }, "the map keeps the read order")
        let whole = NSRange(location: 0, length: target.length)
        #expect(TextNormalizer.unfoldedRange(whole, offsetMap: map) == NSRange(location: 0, length: read.length))
        #expect(TextNormalizer.foldedRange(TextNormalizer.unfoldedRange(whole, offsetMap: map), offsetMap: map) == whole)
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

    @Test("iOS 27: a match through a folded space is boxed on its own words, with folded spaces before it on the line; iOS 26 reads keep their text")
    func foldedMatchIsBoxedOnItsWords() async throws {
        // Words: Ref 0 · 1- 1 · 2- 2 · 3- 3 · 4 4 · call 5 · 555- 6 · 0147 7 · now 8.
        // Three folded spaces before the match put the folded text three
        // units left of the line's own offsets: a box placed from the folded
        // offsets would take "call" and leave "0147" out.
        let read = OCRConfusableSearchTests.line("Ref 1- 2- 3- 4 call 555- 0147 now")
        let (doc, hits) = try await OCRConfusableSearchTests.results([read], OCRConfusableSearchTests.text("555-0147"))
        let page = try #require(doc.page(at: 0))
        guard #available(iOS 27, *) else {
            #expect(hits.isEmpty, "iOS 26 reads keep their text: \(hits.map(\.matchedText))")
            return
        }
        #expect(hits.count == 1, "\(hits.map(\.matchedText))")
        #expect(hits.first?.matchedText == "555-0147")
        let box = try #require(hits.first?.normalizedRect)
        #expect(OCRConfusableSearchTests.same(box, OCRConfusableSearchTests.wordsBox(read, 6...7, page: page)),
                "the words 555- and 0147: \(box)")
        #expect(!box.intersects(read.wordBoxes[5].normalizedRect), "the word before the match is not boxed: \(box)")
        #expect(!box.intersects(read.wordBoxes[8].normalizedRect), "the word after the match is not boxed: \(box)")
    }
}
