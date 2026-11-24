import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

/// An assembled address that wins an overlap group the overlap step widened
/// (the address pattern's match starts on an earlier line) keeps its own box,
/// and the rest of its range, the earlier line, gets a box of its own: a
/// second result, never one box over the band between the lines. On both of
/// Scan's legs: the text layer, and the page's picture read by Vision.
@Suite("Scan boxes the part of a widened address its own box does not reach")
struct ScanOverlapTailTests {
    typealias D = ScanDuplicateAddressTests
    /// The house number has a digit the picture leg's reading keeps: there a
    /// token of only 0, 1, 5 and 8 on a line of mostly letters is read as
    /// letters ("55" as "SS", OCRTextNormalizer), and the pattern does not
    /// start on it.
    static let street = "57 Oak Avenue"

    /// "57 Oak Avenue" at y 600, 100 points above a one-line address at
    /// y 500: too far above to join it (0.126 of the page, past the
    /// assembler's 0.08), close enough in the page's text for the address
    /// pattern to start on it.
    static func page(address: String = D.oneLine) throws -> PDFDocument {
        try ContentGlyphWalkTests.document([D.line(72, 600, street), D.line(72, 500, address)].joined(separator: "\n"))
    }
    static let streetLine = CGRect(x: 90, y: 602, width: 40, height: 4)
    static let band = CGRect(x: 90, y: 540, width: 40, height: 20)

    static func show(_ hits: [SearchResult]) -> String {
        hits.map { "\($0.matchedText.debugDescription) \(ContentGlyphScanTests.points($0.normalizedRect))" }.joined(separator: " | ")
    }
    static func boxes(_ hits: [SearchResult], _ area: CGRect) -> [SearchResult] {
        hits.filter { ContentGlyphScanTests.points($0.normalizedRect).intersects(area) }
    }

    @Test("The earlier line a widened address spans is boxed as its own result, and the band between is not")
    func widenedAddressTailIsBoxed() async throws {
        let hits = await ContentGlyphScanTests.scan(try Self.page())
        #expect(hits.contains { $0.matchedText == D.oneLine && D.covers($0, D.oneLineAt(500)) }, "the address on its line: \(Self.show(hits))")
        #expect(hits.contains { $0.matchedText == Self.street && D.covers($0, Self.streetLine) }, "the earlier line boxed on its own: \(Self.show(hits))")
        #expect(Self.boxes(hits, Self.band).isEmpty, "no box over the band between the lines: \(Self.show(hits))")
    }

    @Test("On the picture leg too, the earlier line a widened address spans is boxed as its own result")
    func widenedAddressTailIsBoxedOnThePictureLeg() async throws {
        // The page's picture, read by Vision: both lines are read word for
        // word (required first, so a misreading is not taken for the fault).
        let doc = try Self.page()
        let page = try #require(doc.page(at: 0))
        let searcher = DocumentSearcher()
        let hits = await searcher._testScanPagePIIViaOCR(page: SendablePDFPage(page), pageIndex: 0, categories: [.address])
        let read = await searcher.ocrLines(for: page, pageIndex: 0).map(\.text)
        try #require(read.contains(Self.street) && read.contains(D.oneLine), "Vision reads both lines word for word: \(read)")
        #expect(hits.contains { D.covers($0, D.oneLineAt(500)) }, "the address on its line: \(Self.show(hits))")
        #expect(hits.contains { $0.matchedText == Self.street && D.covers($0, Self.streetLine) }, "the earlier line boxed on its own: \(Self.show(hits))")
        #expect(Self.boxes(hits, Self.band).isEmpty, "no box over the band between the lines: \(Self.show(hits))")
    }

    @Test("In the exported file, the earlier line's ink is under the paint")
    func widenedAddressTailPaintedInTheExport() async throws {
        typealias X = ContentGlyphExportTests
        let data = ContentGlyphWalkTests.data([D.line(72, 600, Self.street), D.line(72, 500, D.oneLine)].joined(separator: "\n"))
        let hits = await ContentGlyphScanTests.scan(try #require(PDFDocument(data: data)))
        let regions = [0: hits.filter { $0.normalizedRect != .zero }.map {
            RedactionRegion(id: UUID(), normalizedRect: $0.normalizedRect, source: .detectedPII(kind: .address))
        }]
        // White paint, so ink the paint misses stays dark.
        let url = try await TestPipeline.processAndExport(data, mode: .secureRasterization, regions: regions, fillColor: .white, dpi: 150)
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try X.render(data), after = try X.render(try Data(contentsOf: url))
        let s = X.dpi / 72
        var ink = 0, left = 0
        for y in Int(595 * s)..<Int(612 * s) {
            for x in Int(70 * s)..<Int(160 * s) where X.gray(before, x, y) < 128 {
                ink += 1
                if X.gray(after, x, y) < 200 { left += 1 }
            }
        }
        try #require(ink > 100, "the earlier line's ink is read: \(ink) px")
        #expect(left == 0, "\(left) of the earlier line's \(ink) ink pixels are still dark in the export: \(Self.show(hits))")
    }

    @Test("Where the pattern's match wins, its own box covers both lines, as before, and no line is listed apart")
    func patternWinnerUnchanged() async throws {
        // "Trail" is a street type to the pattern but not to the assembler's
        // street line, so the assembled address (placed at its own line, in
        // the pattern's group) scores 0.65 and loses to the pattern's 0.70:
        // the survivor is the pattern's match, boxed by its whole range.
        let hits = await ContentGlyphScanTests.scan(try Self.page(address: "1234 Pine Trail Springfield IL 62704"))
        #expect(hits.contains { D.covers($0, Self.streetLine) && D.covers($0, D.oneLineAt(500)) }, "one box over both lines: \(Self.show(hits))")
        #expect(!hits.contains { $0.matchedText == Self.street }, "no part listed apart: \(Self.show(hits))")
    }

    @Test("A widened range's parts outside its places, trimmed, and none where only white space is left")
    func tailsOutsideThePlaces() {
        let text = "  55 Oak Avenue\n1234 Main St IL 62704 \n , 9 Elm St IL 62704  x" as NSString
        let first = text.range(of: "1234 Main St IL 62704"), second = text.range(of: "9 Elm St IL 62704")
        let all = NSRange(location: 0, length: text.length)
        let parts = DocumentSearcher.tails(of: all, outside: [second, first], in: text).map { text.substring(with: $0) }
        #expect(parts == ["55 Oak Avenue", "x"], "before, between (only white space and a comma), after: \(parts)")
        #expect(DocumentSearcher.tails(of: first, outside: [first], in: text).isEmpty, "a survivor at its own place has none")
    }
}
