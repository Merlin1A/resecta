import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

/// A page whose text PDFKit runs on from one drawn line into the next
/// ("…StreetSpringfield…", where no break was drawn between the lines): each
/// drawn line keeps its own words, so Scan builds the address on them.
@Suite("Scan reads an address whose lines the page text runs together")
struct ScanRunOnAddressTests {
    /// The duplicate-address page drawn ZIP line first: its second copy's
    /// street line runs on into its city line in the page's text.
    static func page() throws -> PDFDocument { try ScanDuplicateAddressTests.page(cityFirst: true) }

    @Test("A word run on over two drawn lines gives each line its own piece")
    func runOnWordSplitByLine() throws {
        let doc = try Self.page()
        let page = try #require(doc.page(at: 0))
        #expect((page.string ?? "").contains("StreetSpringfield"), "the page text runs the lines on: \((page.string ?? "").debugDescription)")
        let source = try #require(EmbeddedTextSource.make(from: page))
        #expect(source.lines.map(\.text) == ["1234 Main Street", "Springfield IL 62704", "1234 Main Street", "Springfield IL 62704"],
                "\(source.lines.map(\.text))")
        #expect(source.lines.allSatisfy { ContentGlyphScanTests.points($0.normalizedRect).height < 20 },
                "every line one line tall: \(source.lines.map { ContentGlyphScanTests.points($0.normalizedRect) })")
    }

    @Test("The second copy's street line is covered by an address of its own")
    func secondCopysStreetLineIsCovered() async throws {
        let hits = await ContentGlyphScanTests.scan(try Self.page())
        let street = CGRect(x: 72, y: 498, width: 92, height: 10)
        let on = hits.filter { $0.matchedText.contains("Main Street") && ContentGlyphScanTests.points($0.normalizedRect).intersects(street) }
        #expect(on.contains { ScanDuplicateAddressTests.coversBothLines($0, top: 509) },
                "a result over both of the lower copy's lines: \(hits.map { "\($0.matchedText.debugDescription) \(ContentGlyphScanTests.points($0.normalizedRect))" })")
        #expect(on.allSatisfy { ContentGlyphScanTests.points($0.normalizedRect).maxY < 600 }, "and on the lower copy only")
    }

    /// A box `h` tall at height `y`.
    static func box(_ y: CGFloat, _ h: CGFloat = 12) -> CGRect { CGRect(x: 72, y: y, width: 40, height: h) }

    @Test("Two drawn lines' pieces that hold the whole word, each character once, are kept apart")
    func piecesOfTwoLinesAreAccepted() {
        let word = NSRange(location: 10, length: 17)
        #expect(EmbeddedTextSource.piecesAccepted([(NSRange(location: 10, length: 6), Self.box(500)), (NSRange(location: 16, length: 11), Self.box(486))], word: word))
    }

    @Test("Pieces that leave out a character of the word, or hold one twice, keep the word whole")
    func piecesShortOfTheWordAreRefused() {
        let word = NSRange(location: 10, length: 17)
        #expect(!EmbeddedTextSource.piecesAccepted([(NSRange(location: 10, length: 6), Self.box(500)), (NSRange(location: 17, length: 10), Self.box(486))], word: word),
                "one character in no piece")
        #expect(!EmbeddedTextSource.piecesAccepted([(NSRange(location: 10, length: 7), Self.box(500)), (NSRange(location: 16, length: 10), Self.box(486))], word: word),
                "one character in two pieces")
    }

    @Test("Pieces that overlap in height are one drawn line's, and keep the word whole")
    func piecesOverlappingInHeightAreRefused() {
        // "5th" with "th" raised 5 pt: the two boxes overlap in height.
        let word = NSRange(location: 5, length: 3)
        #expect(!EmbeddedTextSource.piecesAccepted([(NSRange(location: 5, length: 1), Self.box(500)), (NSRange(location: 6, length: 2), Self.box(505, 9))], word: word))
    }

    @Test("Pieces of two lines set tighter than solid, whose boxes overlap by a point, are kept apart")
    func piecesOfTightLinesAreAccepted() {
        // 12 pt type on 11 pt lines: the boxes overlap by 1 pt of 12.
        let word = NSRange(location: 10, length: 17)
        #expect(EmbeddedTextSource.piecesAccepted([(NSRange(location: 10, length: 6), Self.box(497)), (NSRange(location: 16, length: 11), Self.box(486))], word: word))
    }

    @Test("Pieces whose middles are within the line bucketing's tolerance are one line's, however little they overlap")
    func piecesWithinTheLineToleranceAreRefused() {
        // Two 3 pt pieces 2 pt apart: they overlap by 1 pt, under half of
        // either, but would go to one line's bucket (2 pt at the least).
        let word = NSRange(location: 5, length: 3)
        #expect(!EmbeddedTextSource.piecesAccepted([(NSRange(location: 5, length: 1), Self.box(500, 3)), (NSRange(location: 6, length: 2), Self.box(498, 3))], word: word))
    }

    @Test("At 12 pt on 11 pt lines, a word run on over the two lines still gives each its own piece, and the address is built")
    func tightLinesRunOnIsSplit() async throws {
        let doc = try ContentGlyphWalkTests.document([
            ScanDuplicateAddressTests.line(72, 489, ScanDuplicateAddressTests.city),
            ScanDuplicateAddressTests.line(72, 500, ScanDuplicateAddressTests.street),
        ].joined(separator: "\n"))
        let page = try #require(doc.page(at: 0))
        #expect((page.string ?? "").contains("StreetSpringfield"), "the page text runs the lines on: \((page.string ?? "").debugDescription)")
        let source = try #require(EmbeddedTextSource.make(from: page))
        #expect(source.lines.map(\.text) == ["1234 Main Street", "Springfield IL 62704"],
                "\(source.lines.map { "\($0.text.debugDescription) \(ContentGlyphScanTests.points($0.normalizedRect))" })")
        let hits = await ContentGlyphScanTests.scan(doc)
        // The street line drawn at 500, so the copy's top is 509.
        #expect(hits.contains { ScanDuplicateAddressTests.coversBothLines($0, top: 509) },
                "\(hits.map { "\($0.matchedText.debugDescription) \(ContentGlyphScanTests.points($0.normalizedRect))" })")
    }

    @Test("A word PDFKit gives two pieces at one height (a letter set 16 pt lower, onto the line below) is kept whole on that line")
    func piecesAtOneHeightKeepTheWordWhole() throws {
        // The "B" of "Unit 4B" lowered 16 pt lands on the city line, and the
        // page text puts it after the ZIP: "62704B", its two pieces at one
        // height.
        let doc = try ContentGlyphWalkTests.document([
            "BT /F1 12 Tf 72 509 Td (Unit 4) Tj -16 Ts (B) Tj 0 Ts ( Main Street) Tj ET",
            ScanDuplicateAddressTests.line(72, 495, "Springfield IL 62704"),
        ].joined(separator: "\n"))
        let page = try #require(doc.page(at: 0))
        let text = (page.string ?? "") as NSString
        let word = text.range(of: "62704B")
        #expect(word.location != NSNotFound, "precondition: \((text as String).debugDescription)")
        let pieces = try #require(page.selection(for: word)).selectionsByLine()
        #expect(pieces.count == 2, "precondition: PDFKit gives the word \(pieces.count) line pieces")
        let source = try #require(EmbeddedTextSource.make(from: page))
        #expect(source.lineSpans.contains { $0.ranges.contains(word) },
                "the word's whole range is on one line: \(source.lineSpans.map(\.ranges))")
    }

    @Test("A street line with a raised ordinal is one line, and its address is built on it")
    func raisedOrdinalStaysOnItsLine() async throws {
        // "1234 5th Avenue": the ordinal's "th" drawn 5 pt higher (Ts).
        let doc = try ContentGlyphWalkTests.document([
            "BT /F1 12 Tf 72 509 Td (1234 5) Tj 5 Ts (th) Tj 0 Ts ( Avenue) Tj ET",
            ScanDuplicateAddressTests.line(72, 495, "Springfield IL 62704"),
        ].joined(separator: "\n"))
        let page = try #require(doc.page(at: 0))
        let source = try #require(EmbeddedTextSource.make(from: page))
        #expect(source.lines.map(\.text) == ["1234 5th Avenue", "Springfield IL 62704"], "\(source.lines.map(\.text)) page text \((page.string ?? "").debugDescription)")
        let hits = await ContentGlyphScanTests.scan(doc)
        // The street line drawn at 509, so the copy's top is 518.
        #expect(hits.contains { ScanDuplicateAddressTests.coversBothLines($0, top: 518) },
                "\(hits.map { "\($0.matchedText.debugDescription) \(ContentGlyphScanTests.points($0.normalizedRect))" })")
    }
}
