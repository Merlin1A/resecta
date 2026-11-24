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
