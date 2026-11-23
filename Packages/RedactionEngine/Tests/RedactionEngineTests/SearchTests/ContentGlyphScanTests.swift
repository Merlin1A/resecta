import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

/// The growth to a match's own drawn glyphs on the paths beside a text
/// search's: Scan's addresses assembled line by line, a Scan match boxed
/// whole (and the preview's box), and a page with a hidden layer over a page
/// image that also draws text.
@Suite("Scan's boxes and the hidden-layer paint grown to their own glyphs")
struct ContentGlyphScanTests {
    static let street = "BT /F1 12 Tf 72 700 Td (1234 Main Street) Tj ET"
    static let zip = "BT /F1 12 Tf 72 686 Td (Springfield, IL 62704) Tj ET"
    /// An undrawn comma at the ZIP line's origin: PDFKit then boxes the
    /// line's characters a letter short, so its box ends at 175.392 where
    /// the ZIP's last digit is drawn to 182.064 (the font's own widths).
    static let shortZip = [street, zip, "BT /F1 12 Tf 0 0 0 0 72 686 Tm (,) Tj ET"].joined(separator: "\n")
    static let zipEnd: CGFloat = 182.064

    static func scan(_ doc: PDFDocument) async -> [SearchResult] {
        var options = SearchOptions()
        options.includeOCR = false
        var hits: [SearchResult] = []
        for await r in DocumentSearcher().search(SendablePDFDocument(doc), mode: .piiScan(categories: [.address], options: options),
                                                 progress: { _, _ in }) {
            hits.append(r)
        }
        return hits
    }

    static func points(_ r: CGRect) -> CGRect { ContentGlyphRouteTests.points(r) }

    /// The address the spatial assembly builds from the page's lines (joined
    /// with ", "), and the one the detector reads in the page's text (across
    /// its line break).
    static func addresses(_ hits: [SearchResult]) throws -> (assembled: SearchResult, found: SearchResult) {
        let assembled = try #require(hits.first { !$0.matchedText.contains("\n") && $0.matchedText.contains("62704") },
                                     "the assembled address: \(hits.map(\.matchedText))")
        let found = try #require(hits.first { $0.matchedText.contains("\n") && $0.matchedText.contains("62704") },
                                 "the address found in the text: \(hits.map(\.matchedText))")
        return (assembled, found)
    }

    @Test("A Scan address assembled from its lines reaches its last digit where PDFKit boxes the ZIP line short; it grows sideways, and is told by its box before the growth")
    func assembledAddressGrows() async throws {
        let doc = try ContentGlyphWalkTests.document(Self.shortZip)
        let (assembled, _) = try Self.addresses(await Self.scan(doc))
        let box = Self.points(assembled.normalizedRect)
        let before = Self.points(try #require(assembled.identityRect, "the box before the growth rides as the identity"))
        #expect(before.maxX < 176, "precondition: the lines' union ends at \(before.maxX), short of the 4")
        #expect(box.maxX >= Self.zipEnd - DocumentSearcher.growthSlack, "the address ends at \(box.maxX); the 4 ends at \(Self.zipEnd)")
        #expect(abs(box.minX - before.minX) < 0.001 && abs(box.minY - before.minY) < 0.001 && abs(box.maxY - before.maxY) < 0.001,
                "grown sideways only: \(box) against \(before)")
        #expect(assembled.textLayerRect == nil, "a page with no image under its text has no separate strip")
    }

    @Test("A Scan match boxed whole, and the preview's box, reach the last digit too")
    func boxedWholeGrows() async throws {
        let doc = try ContentGlyphWalkTests.document(Self.shortZip)
        let (_, found) = try Self.addresses(await Self.scan(doc))
        let page = try #require(doc.page(at: 0))
        let range = ((try #require(page.string)) as NSString).range(of: "62704")
        let today = try #require(page.selection(for: range)?.bounds(for: page))
        #expect(today.maxX < 176, "precondition: PDFKit's box ends at \(today.maxX)")
        #expect(Self.points(found.normalizedRect).maxX >= Self.zipEnd - DocumentSearcher.growthSlack,
                "the address found in the text ends at \(Self.points(found.normalizedRect).maxX)")
        #expect(found.identityRect != nil, "told by its box before the growth")
        let preview = try #require(DocumentSearcher().boundingRect(for: range, page: page))
        #expect(Self.points(preview).maxX >= Self.zipEnd - DocumentSearcher.growthSlack, "the preview's box ends at \(Self.points(preview).maxX)")
    }

    @Test("An address whose lines PDFKit boxes right: every line and the address keep their boxes exactly")
    func plainAddressUnchanged() async throws {
        let doc = try ContentGlyphWalkTests.document([Self.street, Self.zip].joined(separator: "\n"))
        let page = try #require(doc.page(at: 0))
        let today = try #require(EmbeddedTextSource.make(from: page, fitLines: true)).lines
        let lines = try #require(DocumentSearcher().addressLines(on: page))
        #expect(lines.map(\.normalizedRect) == today.map(\.normalizedRect))
        #expect(lines.allSatisfy { $0.ungrownRect == nil && $0.identityRect == nil })
        let (assembled, found) = try Self.addresses(await Self.scan(doc))
        #expect(assembled.identityRect == nil && found.identityRect == nil, "no box moved")
    }

    @Test("Lines join into an address on their boxes before the growth: a line grown left past the alignment limit still joins")
    func joinReadsTheUngrownBox() {
        let streetBox = CGRect(x: 0.1176, y: 0.8803, width: 0.15, height: 0.0152)
        let zipBox = CGRect(x: 0.1176, y: 0.8626, width: 0.18, height: 0.0152)
        // Grown 0.06 of the page's width to the left: past the 0.05 the join allows.
        let grownZip = CGRect(x: zipBox.minX - 0.06, y: zipBox.minY, width: zipBox.width + 0.06, height: zipBox.height)
        let lines = [
            OCREngine.TextLine(text: "1234 Main Street", normalizedRect: streetBox, confidence: 1),
            OCREngine.TextLine(text: "Springfield, IL 62704", normalizedRect: grownZip, confidence: 1,
                               identityRect: zipBox, ungrownRect: zipBox),
        ]
        let assembled = AddressSpatialAssembler().assemble(lines: lines)
        let address = assembled.first { $0.text.contains("62704") }
        #expect(address?.text.contains("Main Street") == true, "the street line joins: \(assembled.map(\.text))")
        #expect(address?.unionRect.minX == grownZip.minX, "the paint is the grown union")
        #expect(address?.identityUnionRect == streetBox.union(zipBox), "told by the union before the growth")
    }

    // MARK: - A hidden layer over a page image, on a page that also draws text

    /// A white page-scale image (850 × 1100 one-bit pixels, the image share
    /// a page picture has), `content` drawn over it, and one hidden line
    /// after it (drawn last, so PDFKit reads the text in content order).
    static func overImage(_ content: String) throws -> PDFDocument {
        let bytes = String(repeating: "\u{0}", count: 107 * 1100)
        let image = PDFObject(id: 6, content: "<< /Type /XObject /Subtype /Image /Width 850 /Height 1100 /ColorSpace /DeviceGray /BitsPerComponent 1 /Decode [1 0] /Length \(bytes.utf8.count) >>\nstream\n\(bytes)\nendstream")
        return try ContentGlyphWalkTests.document(
            "q 612 0 0 792 0 0 cm /Im1 Do Q\n" + content + "\nBT /F1 12 Tf 3 Tr 72 300 Td (Hidden layer line here) Tj ET",
            resources: "/Font << /F1 5 0 R >> /XObject << /Im1 6 0 R >>", extra: [image])
    }

    @Test("On a page with a hidden layer over a page image, a drawn word's paint holds each of its glyphs on its line; the strip stays PDFKit's box")
    func hiddenLayerPaintHoldsItsGlyphs() async throws {
        let doc = try Self.overImage(ContentGlyphRouteTests.sliver)
        let page = try #require(doc.page(at: 0))
        await DocumentSearcher.prepareInkFit(page)
        let searcher = DocumentSearcher()
        let range = ((try #require(page.string)) as NSString).range(of: "account")
        let selection = try #require(page.selection(for: range))
        let raw = try #require(searcher.normalizedRect(for: selection, page: page))
        let split = try #require(searcher.textLayerAndInkRects(for: range, page: page), "the page carries a hidden layer over an image")
        try #require(split.paint.count == 1 && !split.degraded, "one line, read in time: \(split)")
        let fit = DocumentSearcher.inkFit(raw, page: page, text: "account", range: range, paintOnly: true)
        let glyphs = try #require(DocumentSearcher.ownGlyphs(for: range, page: page), "the page is mapped")
        let line = selection.bounds(for: page)
        let cut = glyphs.compactMap { glyph -> CGRect? in
            let low = max(glyph.box.minY, line.minY), high = min(glyph.box.maxY, line.maxY)
            return high > low ? searcher.normalizedRect(forPageRect: CGRect(x: glyph.box.minX, y: low, width: glyph.box.width, height: high - low), page: page) : nil
        }
        try #require(cut.count == 7, "the word's seven glyphs: \(cut.count)")
        let tolerance = DocumentSearcher.growthSlack / 792
        #expect(cut.contains { !fit.rect.insetBy(dx: -tolerance, dy: -tolerance).contains($0) },
                "precondition: the ink fit alone \(Self.points(fit.rect)) holds every glyph")
        for glyph in cut {
            #expect(split.paint[0].insetBy(dx: -tolerance, dy: -tolerance).contains(glyph),
                    "the paint \(Self.points(split.paint[0])) leaves out the glyph \(Self.points(glyph))")
        }
        #expect(split.strip[0] == raw, "the strip is PDFKit's box: \(Self.points(split.strip[0]))")
        #expect(split.identity[0] == (fit.identity ?? fit.rect), "told by the paint before the growth")
    }
}
