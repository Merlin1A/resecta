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
        #expect(!on.isEmpty, "a result on the lower copy's street line: \(hits.map { "\($0.matchedText.debugDescription) \(ContentGlyphScanTests.points($0.normalizedRect))" })")
        #expect(on.allSatisfy { ContentGlyphScanTests.points($0.normalizedRect).maxY < 600 }, "and on the lower copy only")
    }
}
