import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

/// The page's own drawing read glyph by glyph: each glyph's place from the
/// text and graphics state, and nil wherever a place or text is not exact.
@Suite("Glyphs from the page's own drawing")
struct ContentGlyphWalkTests {
    static let helvetica = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"
    static let visible = "BT /F1 12 Tf 72 700 Td (Quarterly statement for the account) Tj ET"

    /// One Letter page: `content` as its stream, F1 as its font, and any
    /// further objects (from id 6) the resources name.
    static func page(_ content: String, font: String = helvetica,
                     resources: String = "/Font << /F1 5 0 R >>", extra: [PDFObject] = []) throws -> (PDFPage, CGPDFPage) {
        let page = try #require(try document(content, font: font, resources: resources, extra: extra).page(at: 0))
        return (page, try #require(page.pageRef))
    }

    /// The same page as a document, for a caller that searches it (a page
    /// keeps no strong hold on its document).
    static func document(_ content: String, font: String = helvetica,
                         resources: String = "/Font << /F1 5 0 R >>", extra: [PDFObject] = []) throws -> PDFDocument {
        try #require(PDFDocument(data: data(content, font: font, resources: resources, extra: extra)))
    }

    /// The same page's file.
    static func data(_ content: String, font: String = helvetica,
                     resources: String = "/Font << /F1 5 0 R >>", extra: [PDFObject] = []) -> Data {
        buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << \(resources) >> >>"),
            PDFObject(id: 4, content: "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"),
            PDFObject(id: 5, content: font),
        ] + extra, rootId: 1)
    }

    static func glyphs(_ content: String, font: String = helvetica, resources: String = "/Font << /F1 5 0 R >>",
                       extra: [PDFObject] = []) throws -> [ShownGlyph]? {
        ContentGlyphWalk.glyphs(on: try page(content, font: font, resources: resources, extra: extra).1)
    }

    // MARK: - Places

    @Test("On a plain line each glyph's box starts where PDFKit's own box for its character starts, within 0.05 pt")
    func plainLineMatchesPDFKit() throws {
        let (page, cgPage) = try Self.page(Self.visible)
        let glyphs = try #require(ContentGlyphWalk.glyphs(on: cgPage))
        let text = try #require(page.string)
        #expect(glyphs.map(\.text).joined() == text)
        for (index, glyph) in glyphs.enumerated() {
            let box = try #require(page.selection(for: NSRange(location: index, length: 1))?.bounds(for: page))
            #expect(abs(glyph.box.minX - box.minX) < 0.05, "\(glyph.text) at \(index): \(glyph.box.minX) against \(box.minX)")
            #expect(abs(glyph.box.maxX - box.maxX) < 0.05, "\(glyph.text) at \(index): \(glyph.box.maxX) against \(box.maxX)")
            #expect(!glyph.singular && glyph.renderMode == 0)
        }
    }

    @Test("A word drawn under a zero text matrix is singular, and the visible line's last letter keeps its own advance")
    func zeroMatrixPlant() throws {
        let glyphs = try #require(try Self.glyphs(Self.visible + "\nBT /F1 12 Tf 0 0 0 0 72 700 Tm (QUARTZ7) Tj ET"))
        #expect(glyphs.count == 35 + 7)
        #expect(glyphs.prefix(35).allSatisfy { !$0.singular })
        #expect(glyphs.suffix(7).allSatisfy { $0.singular })
        let t = glyphs[34]
        #expect(t.text == "t" && abs(t.box.maxX - 260.088) < 0.05, "the t ends at \(t.box.maxX)")
    }

    @Test("A TJ number moves the next glyph back by its thousandths of the size: Total's T starts at 98.616")
    func tjMovesBack() throws {
        let glyphs = try #require(try Self.glyphs("BT /F1 12 Tf 72 700 Td [(Inv) -250 (oice) 1200 (Total) -500 (due)] TJ ET"))
        #expect(glyphs.map(\.text).joined() == "InvoiceTotaldue")
        let total = glyphs[7]
        #expect(total.text == "T" && abs(total.box.minX - 98.616) < 0.05, "T starts at \(total.box.minX)")
    }

    @Test("Word spacing moves only after byte 32, character spacing after every glyph, and Tz scales both")
    func spacingAndScale() throws {
        let plain = try #require(try Self.glyphs("BT /F1 10 Tf 0 0 Td (a b) Tj ET"))
        let spaced = try #require(try Self.glyphs("BT /F1 10 Tf 7 Tw 2 Tc 0 0 Td (a b) Tj ET"))
        let squeezed = try #require(try Self.glyphs("BT /F1 10 Tf 50 Tz 0 0 Td (a b) Tj ET"))
        #expect(abs((spaced[1].box.minX - plain[1].box.minX) - 2) < 1e-9, "after a: Tc only")
        #expect(abs((spaced[2].box.minX - plain[2].box.minX) - (2 + 2 + 7)) < 1e-9, "after the space: Tc twice and Tw once")
        #expect(abs(squeezed[2].box.minX - plain[2].box.minX / 2) < 1e-9)
        #expect(abs(squeezed[0].box.width - plain[0].box.width / 2) < 1e-9)
    }

    @Test("TD sets the leading that T*, ' and \" move by")
    func lineMoves() throws {
        let glyphs = try #require(try Self.glyphs("BT /F1 10 Tf 72 700 Td (a) Tj 0 -14 TD (b) Tj T* (c) Tj (d) ' 3 1 (e) \" ET"))
        let baselines = glyphs.map { $0.box.minY - ContentGlyphFontTests.helveticaDescent(10) }
        for (index, expected) in [700.0, 686, 672, 658, 644].enumerated() {
            #expect(abs(baselines[index] - expected) < 1e-6, "\(glyphs[index].text) on \(baselines[index])")
        }
    }

    @Test("q and Q save the font and size, not the text matrix; a zero cm makes every glyph singular")
    func graphicsState() throws {
        let restored = try #require(try Self.glyphs("BT /F1 12 Tf ET q BT /F1 0 Tf ET Q BT 72 700 Td (X) Tj ET"))
        #expect(restored.count == 1 && !restored[0].singular && abs(restored[0].box.width - 8.004) < 0.05)
        let flattened = try #require(try Self.glyphs("0 0 0 0 0 0 cm BT /F1 12 Tf 72 700 Td (X) Tj ET"))
        #expect(flattened.allSatisfy { $0.singular })
        let sized = try #require(try Self.glyphs("BT /F1 0 Tf 72 700 Td (X) Tj ET"))
        #expect(sized.allSatisfy { $0.singular }, "zero size")
        let squeezed = try #require(try Self.glyphs("BT /F1 12 Tf 0 Tz 72 700 Td (X) Tj ET"))
        #expect(squeezed.allSatisfy { $0.singular }, "zero horizontal scale")
    }

    @Test("A form is read under its matrix with its own resources; its render mode is the glyph's")
    func formMatrix() throws {
        let form = "q BT /F1 12 Tf 3 Tr 0 0 Td (X) Tj ET Q"
        let glyphs = try #require(try Self.glyphs("q 1 0 0 1 100 200 cm /X1 Do Q",
            resources: "/XObject << /X1 6 0 R >>",
            extra: [PDFObject(id: 6, content: "<< /Type /XObject /Subtype /Form /BBox [0 0 100 100] /Matrix [2 0 0 2 0 0] /Resources << /Font << /F1 5 0 R >> >> /Length \(form.utf8.count) >>\nstream\n\(form)\nendstream")]))
        #expect(glyphs.count == 1)
        #expect(abs(glyphs[0].box.minX - 100) < 1e-9 && abs(glyphs[0].box.width - 16.008) < 0.05)
        #expect(glyphs[0].renderMode == 3)
    }

    @Test("The f-ligature named in /Differences reads as the two letters it stands for")
    func ligature() throws {
        let font = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding << /Type /Encoding /BaseEncoding /WinAnsiEncoding /Differences [174 /fi] >> >>"
        let glyphs = try #require(try Self.glyphs("BT /F1 12 Tf 72 700 Td (\\256nal) Tj ET", font: font))
        #expect(glyphs.map(\.text) == ["fi", "n", "a", "l"])
    }

    // MARK: - Unknown

    @Test("Unknown, never partial: a gs that sets the font, a font other than a simple one, text outside BT, /ActualText, a form past the depth, an unresolved name")
    func unknownPages() throws {
        #expect(try Self.glyphs("/G1 gs BT /F1 12 Tf (X) Tj ET", resources: "/Font << /F1 5 0 R >> /ExtGState << /G1 6 0 R >>",
                                extra: [PDFObject(id: 6, content: "<< /Type /ExtGState /Font [5 0 R 12] >>")]) == nil)
        #expect(try Self.glyphs("BT /F1 12 Tf (X) Tj ET", font: "<< /Type /Font /Subtype /Type0 /BaseFont /X /Encoding /Identity-H /DescendantFonts [] >>") == nil)
        #expect(try Self.glyphs("BT /F1 12 Tf ET (X) Tj") == nil)
        #expect(try Self.glyphs("/Span << /ActualText (Y) >> BDC BT /F1 12 Tf (X) Tj ET EMC") == nil)
        #expect(try Self.glyphs("BT /F2 12 Tf (X) Tj ET") == nil)
        #expect(try Self.glyphs("/X9 Do") == nil)
        let deep = "/X1 Do"
        #expect(try Self.glyphs("/X1 Do", resources: "/XObject << /X1 6 0 R >>",
            extra: [PDFObject(id: 6, content: "<< /Type /XObject /Subtype /Form /BBox [0 0 1 1] /Resources << /XObject << /X1 6 0 R >> >> /Length \(deep.utf8.count) >>\nstream\n\(deep)\nendstream")]) == nil,
            "a form that draws itself stops at the depth")
        #expect(try Self.glyphs("BT /F1 12 Tf (\\201) Tj ET") == nil, "a code WinAnsi leaves undefined")
    }
}

@Suite("Fonts as the page draws them")
struct ContentGlyphFontTests {
    /// Helvetica with its own two widths from `first`, and a descriptor
    /// that gives its height.
    static func twoWidths(from first: String) -> String {
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding /FirstChar \(first) /Widths [600 600] "
            + "/FontDescriptor << /Type /FontDescriptor /FontName /Helvetica /Flags 32 /Ascent 718 /Descent -207 "
            + "/FontBBox [-166 -225 1000 931] /ItalicAngle 0 /CapHeight 718 /StemV 88 >> >>"
    }

    @Test("A first code outside 0-255 leaves the page unread, however large the number; one inside reads")
    func firstCodeOutOfRange() throws {
        let glyphs = try #require(try ContentGlyphWalkTests.glyphs("BT /F1 12 Tf (XY) Tj ET", font: Self.twoWidths(from: "88")),
                                  "the control: codes 88 and 89 read")
        #expect(glyphs.count == 2)
        for first in ["256", "-1", "9223372036854775806"] {
            #expect(try ContentGlyphWalkTests.glyphs("BT /F1 12 Tf (XY) Tj ET", font: Self.twoWidths(from: first)) == nil,
                    "/FirstChar \(first)")
        }
    }

    /// Helvetica's descent at `size`, from the system font the walker reads it from.
    static func helveticaDescent(_ size: CGFloat) -> CGFloat {
        -CTFontGetDescent(CTFontCreateWithName("Helvetica" as CFString, 1000, nil)) / 1000 * size
    }

    @Test("ToUnicode: bfchar and bfrange (both forms) read; a two-byte source, a CID entry, or a broken line make the whole map unread")
    func toUnicode() {
        let map = ToUnicode.parse(Data("""
            /CIDInit begin 1 begincodespacerange <00> <FF> endcodespacerange
            2 beginbfchar <41> <0058> <42> <00660069> endbfchar
            2 beginbfrange <61> <63> <0071> <70> <71> [<0031> <0032>] endbfrange end
            """.utf8))
        #expect(map == [0x41: "X", 0x42: "fi", 0x61: "q", 0x62: "r", 0x63: "s", 0x70: "1", 0x71: "2"])
        #expect(ToUnicode.parse(Data("1 beginbfchar <0041> <0058> endbfchar".utf8)) == nil)
        #expect(ToUnicode.parse(Data("1 begincidrange <00> <FF> 1 endcidrange".utf8)) == nil)
        #expect(ToUnicode.parse(Data("1 beginbfchar <41> endbfchar".utf8)) == nil)
    }

    @Test("Glyph names: the table, single letters, uniXXXX and uXXXX; any other name has no text")
    func glyphNames() {
        #expect(GlyphNames.text("hyphen") == "-")
        #expect(GlyphNames.text("Q") == "Q")
        #expect(GlyphNames.text("uni00E9") == "\u{E9}")
        #expect(GlyphNames.text("u1F600") == "\u{1F600}")
        #expect(GlyphNames.text("ffl") == "ffl")
        #expect(GlyphNames.text("eacute") == nil)
        #expect(GlyphNames.text("g123") == nil)
    }
}
