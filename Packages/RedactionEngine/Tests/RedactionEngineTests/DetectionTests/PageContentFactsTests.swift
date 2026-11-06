import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import RedactionEngine

// The four page facts that decide whether a box can miss a covered word's
// text in a Searchable export, and the rule that reads them. A plain page
// (typed text only) keeps its text layer under any box; a page that reaches an
// image, draws an inline image, shows text in an invisible render mode or uses
// a Type 3 font keeps it only when every box on it was placed from a match in
// the page's own text layer and left where it was placed.

@Suite("Page content facts")
struct PageContentFactsTests {

    // MARK: - Pages

    static let font = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"
    static let text = "BT /F1 14 Tf 72 700 Td (Account holder Delia Hartwell) Tj ET"
    static let image = "<< /Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray "
        + "/BitsPerComponent 8 /Filter /ASCIIHexDecode /Length 9 >>\nstream\n80C040A0>\nendstream"
    static func type3(_ id: Int) -> [PDFObject] {
        let glyph = "1000 0 0 0 1000 1000 d1\n0 0 500 500 re f"
        return [PDFObject(id: id, content: "<< /Type /Font /Subtype /Type3 /FontBBox [0 0 1000 1000] "
                          + "/FontMatrix [0.001 0 0 0.001 0 0] /CharProcs << /square \(id + 1) 0 R >> "
                          + "/Encoding << /Type /Encoding /Differences [97 /square] >> /FirstChar 97 /LastChar 97 /Widths [1000] >>"),
                PDFObject(id: id + 1, content: "<< /Length \(glyph.utf8.count) >>\nstream\n\(glyph)\nendstream")]
    }
    static func stream(_ id: Int, _ body: String, dictionary: String = "") -> PDFObject {
        PDFObject(id: id, content: "<< \(dictionary) /Length \(body.utf8.count) >>\nstream\n\(body)\nendstream")
    }

    /// One page: catalog 1, tree 2, page 3 with content 4 and `resources`, Helvetica 5, then `extra`.
    static func page(_ content: String, resources: String, extra: [PDFObject] = []) throws -> PDFDocument {
        let objects = [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
                      + "/Resources << \(resources) >> >>"),
            stream(4, content),
            PDFObject(id: 5, content: font),
        ] + extra
        return try #require(PDFDocument(data: buildRawPDF(objects: objects, rootId: 1)))
    }

    static func facts(_ doc: PDFDocument) throws -> PageContentFacts {
        PageContentFacts.read(try #require(doc.page(at: 0)).pageRef)
    }

    // MARK: - The facts

    @Test("typed text alone is plain")
    func typedTextIsPlain() throws {
        let f = try Self.facts(Self.page(Self.text, resources: "/Font << /F1 5 0 R >>"))
        #expect(f == PageContentFacts(reachesImage: false, drawsInlineImage: false, showsInvisibleText: false, usesType3Font: false))
        #expect(f.isPlain)
    }

    @Test("a vector logo (paths only) is plain")
    func vectorLogoIsPlain() throws {
        let f = try Self.facts(Self.page("0 0 1 rg 480 740 60 30 re f\n" + Self.text, resources: "/Font << /F1 5 0 R >>"))
        #expect(f.isPlain)
    }

    @Test("an image object the page reaches, however small, is read")
    func imageObject() throws {
        let f = try Self.facts(Self.page("q 60 0 0 30 480 740 cm /Im1 Do Q\n" + Self.text,
                                         resources: "/Font << /F1 5 0 R >> /XObject << /Im1 6 0 R >>",
                                         extra: [PDFObject(id: 6, content: Self.image)]))
        #expect(f.reachesImage)
        #expect(!f.isPlain)
    }

    @Test("an inline image in the page's content is read")
    func inlineImageInPage() throws {
        let f = try Self.facts(Self.page("q 60 0 0 30 480 740 cm BI /W 2 /H 2 /CS /G /BPC 8 /F /AHx ID 80C040A0> EI Q\n" + Self.text,
                                         resources: "/Font << /F1 5 0 R >>"))
        #expect(f.drawsInlineImage)
        #expect(!f.reachesImage)
        #expect(!f.isPlain)
    }

    @Test("an inline image inside a form object is read")
    func inlineImageInForm() throws {
        let form = Self.stream(6, "BI /W 2 /H 2 /CS /G /BPC 8 /F /AHx ID 80C040A0> EI",
                               dictionary: "/Type /XObject /Subtype /Form /BBox [0 0 1 1]")
        let f = try Self.facts(Self.page("q 60 0 0 30 480 740 cm /Fm1 Do Q\n" + Self.text,
                                         resources: "/Font << /F1 5 0 R >> /XObject << /Fm1 6 0 R >>", extra: [form]))
        #expect(f.drawsInlineImage)
    }

    @Test("text in an invisible render mode is read")
    func invisibleText() throws {
        let f = try Self.facts(Self.page("BT 3 Tr /F1 14 Tf 72 700 Td (Hidden) Tj ET", resources: "/Font << /F1 5 0 R >>"))
        #expect(f.showsInvisibleText)
        #expect(!f.isPlain)
    }

    @Test("a Type 3 font in the page's own resources is read")
    func type3InPage() throws {
        let f = try Self.facts(Self.page(Self.text + "\nBT /T3 14 Tf 72 600 Td (a) Tj ET",
                                         resources: "/Font << /F1 5 0 R /T3 6 0 R >>", extra: Self.type3(6)))
        #expect(f.usesType3Font)
        #expect(!f.isPlain)
    }

    @Test("a Type 3 font in a form object's resources is read")
    func type3InForm() throws {
        let form = Self.stream(6, "BT /T3 14 Tf 0 0 Td (a) Tj ET",
                               dictionary: "/Type /XObject /Subtype /Form /BBox [0 0 100 100] /Resources << /Font << /T3 7 0 R >> >>")
        let f = try Self.facts(Self.page("/Fm1 Do\n" + Self.text, resources: "/Font << /F1 5 0 R >> /XObject << /Fm1 6 0 R >>",
                                         extra: [form] + Self.type3(7)))
        #expect(f.usesType3Font)
    }

    @Test("a Type 3 font in resources inherited from the page tree is read")
    func type3Inherited() throws {
        let objects = [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 /Resources << /Font << /F1 5 0 R /T3 6 0 R >> >> >>"),
            PDFObject(id: 3, content: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>"),
            Self.stream(4, Self.text + "\nBT /T3 14 Tf 72 600 Td (a) Tj ET"),
            PDFObject(id: 5, content: Self.font),
        ] + Self.type3(6)
        let doc = try #require(PDFDocument(data: buildRawPDF(objects: objects, rootId: 1)))
        #expect(try Self.facts(doc).usesType3Font)
    }

    @Test("a form chain past the depth limit is never read as plain")
    func formChainPastTheLimit() throws {
        let depth = PageImageCensus.maxFormDepth + 1
        var extra: [PDFObject] = []
        for k in 0..<depth {
            let id = 6 + k
            let next = k + 1 < depth ? "/Resources << /XObject << /Fm1 \(id + 1) 0 R >> >>" : ""
            extra.append(Self.stream(id, k + 1 < depth ? "/Fm1 Do" : "0 0 1 1 re f",
                                     dictionary: "/Type /XObject /Subtype /Form /BBox [0 0 1 1] \(next)"))
        }
        let f = try Self.facts(Self.page("/Fm1 Do\n" + Self.text, resources: "/Font << /F1 5 0 R >> /XObject << /Fm1 6 0 R >>",
                                         extra: extra))
        #expect(!f.isPlain)
    }

    @Test("no page reads as unread, never plain")
    func noPageIsUnread() {
        #expect(PageContentFacts.read(nil) == .unread)
        #expect(!PageContentFacts.unread.isPlain)
    }

    @Test("BI is read only as a whole token")
    func inlineImageToken() {
        #expect(PageContentFacts.ContentWalk.hasInlineImageOperator(Data("q BI /W 2 ID x EI Q".utf8)))
        #expect(PageContentFacts.ContentWalk.hasInlineImageOperator(Data("BI\n/W 2".utf8)))
        #expect(!PageContentFacts.ContentWalk.hasInlineImageOperator(Data("BT (BIRD) Tj ET /BIx Do".utf8)))
        #expect(!PageContentFacts.ContentWalk.hasInlineImageOperator(Data("0 0 1 1 re f".utf8)))
    }

    // MARK: - The rule (pure)

    static let plain = PageContentFacts(reachesImage: false, drawsInlineImage: false, showsInvisibleText: false, usesType3Font: false)
    static let picture = PageContentFacts(reachesImage: true, drawsInlineImage: false, showsInvisibleText: false, usesType3Font: false)
    static let scan = PageContentFacts(reachesImage: true, drawsInlineImage: false, showsInvisibleText: true, usesType3Font: false)
    static let invisible = PageContentFacts(reachesImage: false, drawsInlineImage: false, showsInvisibleText: true, usesType3Font: false)
    static let type3Only = PageContentFacts(reachesImage: false, drawsInlineImage: false, showsInvisibleText: false, usesType3Font: true)
    static let inline = PageContentFacts(reachesImage: false, drawsInlineImage: true, showsInvisibleText: false, usesType3Font: false)

    static let box = CGRect(x: 0.2, y: 0.5, width: 0.1, height: 0.02)
    static func region(_ source: RedactionRegion.Source = .manual, anchored: Bool = false, rect: CGRect = box) -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: rect, source: source, textAnchored: anchored)
    }
    static let match = RedactionRegion.Source.searchMatch(term: "delia")

    static func keeps(_ facts: PageContentFacts, _ regions: [RedactionRegion]) -> Bool {
        PageContentFacts.keepsTextLayer(regions: regions, facts: { facts })
    }

    @Test("image only: a box not anchored to the page's text, on a page that is not plain")
    func rejectCases() {
        #expect(!Self.keeps(Self.picture, [Self.region()]), "hand box, image")
        #expect(!Self.keeps(Self.invisible, [Self.region()]), "hand box, invisible text")
        #expect(!Self.keeps(Self.type3Only, [Self.region()]), "hand box, Type 3 font")
        #expect(!Self.keeps(Self.inline, [Self.region()]), "hand box, inline image")
        #expect(!Self.keeps(Self.picture, [Self.region(Self.match, anchored: false)]), "an edited or picture-read match")
        #expect(!Self.keeps(Self.picture, [Self.region(Self.match, anchored: true), Self.region()]),
                "one anchored match beside a hand box: every box must be anchored")
    }

    @Test("kept: a plain page, anchored matches, a whole-page box, or no box")
    func acceptCases() {
        #expect(Self.keeps(Self.plain, [Self.region()]), "hand box, plain page")
        #expect(Self.keeps(Self.picture, [Self.region(Self.match, anchored: true)]), "anchored match, image")
        #expect(Self.keeps(Self.scan, [Self.region(Self.match, anchored: true)]), "anchored match, scan")
        #expect(Self.keeps(Self.scan, [Self.region(rect: CGRect(x: 0, y: 0, width: 1, height: 1))]), "whole-page box")
        #expect(Self.keeps(Self.scan, []), "no box")
    }

    @Test("the facts are read only when some box is neither anchored nor whole-page")
    func factsReadOnlyWhenNeeded() {
        var reads = 0
        let read = { () -> PageContentFacts in reads += 1; return Self.scan }
        _ = PageContentFacts.keepsTextLayer(regions: [Self.region(Self.match, anchored: true)], facts: read)
        _ = PageContentFacts.keepsTextLayer(regions: [], facts: read)
        #expect(reads == 0)
        _ = PageContentFacts.keepsTextLayer(regions: [Self.region()], facts: read)
        #expect(reads == 1)
    }

    // MARK: - The region field

    @Test("a region encoded without the anchoring key decodes as not anchored; the key round-trips")
    func anchoringCodable() throws {
        let anchored = Self.region(Self.match, anchored: true)
        let decoded = try JSONDecoder().decode(RedactionRegion.self, from: JSONEncoder().encode(anchored))
        #expect(decoded == anchored)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(anchored)) as? [String: Any])
        object.removeValue(forKey: "textAnchored")
        let old = try JSONDecoder().decode(RedactionRegion.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.textAnchored == false)
        #expect(old.normalizedRect == anchored.normalizedRect)
    }
}
