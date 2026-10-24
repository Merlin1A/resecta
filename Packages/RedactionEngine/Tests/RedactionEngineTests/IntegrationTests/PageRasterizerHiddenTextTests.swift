import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import RedactionEngine

// The hidden-text ink test (C12-01). A Searchable page whose surviving
// text-layer glyphs include an ink-less box — white-on-white text, an
// invisible render mode, a box painted over the text in the content
// stream, near-white text, nearly transparent text, text under a nearly
// opaque box — is rasterized as an image with the `.hiddenText` reason, so the
// output's text layer never re-exposes what the page hides. Pages whose
// glyphs all carry ink keep their text layer: ordinary text, pale grey
// text, small text, text separated by non-breaking-space runs, white text
// on a black page, and a rotated page (the box mapping follows the
// displayed frame). RED-first on the parent: the three hidden fixtures came
// through with a text layer and no reason (M12-11's re-exposure).

@Suite("PageRasterizer hidden-text fallback")
struct PageRasterizerHiddenTextTests {

    /// Searchable-mode page data over a one-page fixture, no regions. The
    /// document is returned alongside so the page outlives the call.
    private static func load(_ data: Data) throws -> (PDFDocument, PDFPageData) {
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        let pageData = PDFPageData(
            page: page, pageIndex: 0, regions: [], fillColor: .black, targetDPI: 300,
            pipelineMode: .searchableRedaction, rotation: page.rotation,
            cropBoxBounds: page.bounds(for: .cropBox), cgPage: page.pageRef,
            hasText: page.string?.isEmpty == false)
        return (doc, pageData)
    }

    /// A one-page raw PDF (Helvetica /F1, WinAnsi) around a content stream.
    private static func rawPage(_ stream: String) -> Data {
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
                + "/Resources << /Font << /F1 5 0 R >> >> >>",
            "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ]
        var out = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (i, object) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(i + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { out += String(format: "%010d 00000 n \n", offset) }
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(out.utf8)
    }

    static let hiddenFixtures: [(String, Data)] = [
        ("white-on-white", TestFixtures.whiteOnWhiteTextPDF()),
        ("painted-box", TestFixtures.opaqueBoxCoveredTextPDF()),
        ("invisible-render-mode", TestFixtures.ctLineDrawCourierPDF()),
        ("one-white-glyph",
         rawPage("BT /F1 12 Tf 72 700 Td (Visible line) Tj ET 1 g BT /F1 12 Tf 72 400 Td (X) Tj ET")),
        ("near-white", TestFixtures.nearWhiteTextPDF()),
        ("low-alpha", TestFixtures.lowAlphaTextPDF()),
        ("translucent-box", TestFixtures.translucentBoxCoveredTextPDF()),
        // Eight levels from the page: inside the band with room to spare.
        ("faint-grey", rawPage("0.97 g BT /F1 9 Tf 72 700 Td (Faint grey text 0123456789) Tj ET")),
    ]

    static let inkedFixtures: [(String, Data)] = [
        ("ordinary-12pt", rawPage("BT /F1 12 Tf 72 700 Td (Ordinary twelve point line 0123456789) Tj ET")),
        ("pale-grey", rawPage("0.90 g BT /F1 9 Tf 72 700 Td (Pale ninety percent grey text 0123456789) Tj ET")),
        // Light but inked: a footer or a watermark one level lighter than the
        // pale-grey line (24 levels from the page). The band's first edge, 24,
        // read it as inkless and sent the page image-only.
        ("light-grey", rawPage("0.905 g BT /F1 9 Tf 72 700 Td (Light grey footer text 0123456789) Tj ET")),
        ("small-4pt", rawPage("BT /F1 4 Tf 72 700 Td (Small four point text 0123456789 abcdefghij) Tj ET")),
        ("nbsp-runs",
         rawPage("BT /F1 12 Tf 72 700 Td (Words\\240\\240\\240\\240separated\\240\\240by\\240runs) Tj ET")),
        ("white-on-black",
         rawPage("0 g 0 0 612 792 re f 1 g BT /F1 12 Tf 72 700 Td (White text on a black page) Tj ET")),
        ("rotated-90", TestFixtures.rotatedTextPDF(rotation: 90)),
    ]

    @Test("a page with an ink-less glyph is rasterized with the hidden-text reason",
          arguments: hiddenFixtures)
    func hiddenTextFallsBack(name: String, data: Data) async throws {
        let (doc, pageData) = try Self.load(data)
        defer { withExtendedLifetime(doc) {} }
        let result = try await PageRasterizer().rasterize(pageData)
        #expect(result.fallbackReason == .hiddenText, "\(name)")
        #expect(result.pageOutput.textLayerEntries == nil, "\(name)")
        #expect(result.filterDigest == nil, "\(name)")
    }

    @Test("a page whose glyphs all carry ink keeps its text layer",
          arguments: inkedFixtures)
    func inkedTextKeepsLayer(name: String, data: Data) async throws {
        let (doc, pageData) = try Self.load(data)
        defer { withExtendedLifetime(doc) {} }
        let result = try await PageRasterizer().rasterize(pageData)
        #expect(result.fallbackReason == nil, "\(name)")
        #expect((result.pageOutput.textLayerEntries?.count ?? 0) > 0, "\(name)")
        #expect(result.filterDigest != nil, "\(name)")
    }

    // MARK: - The floor's band

    @Test("a box within the tolerance of one colour reads as showing no ink; one level past it does not")
    func floorBandEdges() throws {
        let context = try #require(createBitmapContext(width: 16, height: 16))
        context.setFillColor(CGColor(gray: 200.0 / 255.0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let buffer = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let box = CGRect(x: 2, y: 2, width: 8, height: 8)
        // One pixel inside the box, on its last row, moved by Δ then Δ + 1
        // on one channel.
        let base = Int(buffer[0])
        let offset = (context.height - 1 - 9) * context.bytesPerRow + 9 * 4 + 1
        buffer[offset] = UInt8(base - InkContrastFloor.tolerance)
        #expect(try InkContrastFloor.maximumDeviation(context: context, rect: box)
                == InkContrastFloor.tolerance)
        #expect(try InkContrastFloor.isNearUniform(context: context, rect: box))
        buffer[offset] = UInt8(base - InkContrastFloor.tolerance - 1)
        #expect(try InkContrastFloor.maximumDeviation(context: context, rect: box)
                == InkContrastFloor.tolerance + 1)
        #expect(try !InkContrastFloor.isNearUniform(context: context, rect: box))
        // With the box uniform again, a pixel outside it moves nothing.
        buffer[offset] = UInt8(base)
        buffer[(context.height - 1 - 12) * context.bytesPerRow + 12 * 4] = 0
        #expect(try InkContrastFloor.maximumDeviation(context: context, rect: box) == 0)
        #expect(try InkContrastFloor.isNearUniform(context: context, rect: box))
    }

    // MARK: - The visible page

    @Test("a glyph box wholly outside the visible page reads as showing no ink")
    func offPageGlyphReadsInkless() throws {
        let context = try #require(createBitmapContext(width: 64, height: 64))
        // A white page with one black mark inside the in-page glyph's box.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 12, y: 12, width: 4, height: 4))
        let pageSize = CGSize(width: 64, height: 64)
        let inked = CharacterInfo(
            character: "A", bounds: CGRect(x: 10, y: 10, width: 10, height: 10), stringIndex: 0)
        let offPage = CharacterInfo(
            character: "A", bounds: CGRect(x: 10, y: 80, width: 10, height: 10), stringIndex: 1)
        #expect(try PageRasterizer.hasInklessGlyph(
            context: context, entries: [inked], pageSize: pageSize) == false)
        #expect(try PageRasterizer.hasInklessGlyph(
            context: context, entries: [offPage], pageSize: pageSize) == true)
        // A glyph the crop clips partly is read on its visible part.
        let clipped = CharacterInfo(
            character: "A", bounds: CGRect(x: 10, y: 58, width: 10, height: 10), stringIndex: 2)
        #expect(try PageRasterizer.hasInklessGlyph(
            context: context, entries: [clipped], pageSize: pageSize) == true)
    }

    @Test("text outside the crop box never reaches the output text layer")
    func offCropBoxTextStaysOut() async throws {
        let data = TestFixtures.offCropBoxTextPDF()
        let (doc, pageData) = try Self.load(data)
        defer { withExtendedLifetime(doc) {} }
        let result = try await PageRasterizer().rasterize(pageData)
        let survivors = (result.pageOutput.textLayerEntries ?? []).map(\.character).joined()
        #expect(!survivors.contains("ENGCROP"))
    }

    @Test("text PDFKit extracts outside the visible page sends the page image-only")
    func offVisiblePageTextSendsThePageImageOnly() async throws {
        // The crop box reaches past the media box, so the line at 700 lies
        // inside the crop box and outside the visible page. PDFKit extracts
        // it all the same: without the visible-page arm the layer would
        // carry it, and this test fails.
        let data = TestFixtures.offCropBoxTextPDF(cropBoxPastMediaBox: true)
        let (doc, pageData) = try Self.load(data)
        defer { withExtendedLifetime(doc) {} }
        let page = try #require(doc.page(at: 0))
        #expect(page.bounds(for: .cropBox).height == 600, "the visible page is the boxes' intersection")
        #expect(page.string?.contains("PLANT-ENGCROP-01") == true, "PDFKit extracts the line past the visible page")
        let extracted = try await TextLayerExtractor().extractCharacters(from: page)
        #expect(extracted.map(\.character).joined().contains("ENGCROP"), "the line reaches the extractor")
        let result = try await PageRasterizer().rasterize(pageData)
        #expect(result.fallbackReason == .hiddenText, "the arm sends the page image-only")
        #expect(result.pageOutput.textLayerEntries == nil || result.pageOutput.textLayerEntries?.isEmpty == true)
        let survivors = (result.pageOutput.textLayerEntries ?? []).map(\.character).joined()
        #expect(!survivors.contains("ENGCROP"))
    }
}
