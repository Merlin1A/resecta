import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import RedactionEngine

// The read defaults that fail closed. A walk that cannot read the structure
// it inspects says so instead of answering "clean", and a per-page check
// that cannot run reports "unchecked" instead of "no": the import refuses
// what it could not scan, and the page takes the secure path. The fixtures
// are raw bytes in shapes a well-formed writer never emits.

@Suite("Fail-closed read defaults", .tags(.security))
struct FailClosedReadDefaultsTests {

    // MARK: - Fixtures

    /// A trailer whose /Root points at an object the file never defines.
    private static func catalogless() -> Data {
        buildRawPDF(objects: [
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] \
                /Contents 4 0 R /Resources << >> >>
                """),
            PDFObject(id: 4, content: "<< /Length 0 >>\nstream\n\nendstream"),
        ], rootId: 1)
    }

    /// A page tree whose one kid is an integer, not a page dictionary.
    private static func pageWithoutDictionary() -> Data {
        buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: "42"),
        ], rootId: 1)
    }

    /// An /OpenAction chain of `length` actions, GoTo after GoTo, whose last
    /// is JavaScript.
    private static func openActionChain(length: Int) -> Data {
        var objects = [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R /OpenAction 5 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] \
                /Contents 4 0 R /Resources << >> >>
                """),
            PDFObject(id: 4, content: "<< /Length 0 >>\nstream\n\nendstream"),
        ]
        for step in 0..<length {
            let id = 5 + step
            if step == length - 1 {
                objects.append(PDFObject(id: id, content: "<< /S /JavaScript /JS (app.alert(1)) >>"))
            } else {
                objects.append(PDFObject(
                    id: id, content: "<< /S /GoTo /D [3 0 R /Fit] /Next \(id + 1) 0 R >>"))
            }
        }
        return buildRawPDF(objects: objects, rootId: 1)
    }

    /// /OCProperties with its required /D configuration missing.
    private static func ocPropertiesWithoutDefaultConfig() -> Data {
        buildRawPDF(objects: [
            PDFObject(id: 1, content: """
                << /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [5 0 R] >> >>
                """),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] \
                /Contents 4 0 R /Resources << >> >>
                """),
            PDFObject(id: 4, content: "<< /Length 0 >>\nstream\n\nendstream"),
            PDFObject(id: 5, content: "<< /Type /OCG /Name (Layer) >>"),
        ], rootId: 1)
    }

    private func cgDocument(_ data: Data) -> CGPDFDocument? {
        CGDataProvider(data: data as CFData).flatMap { CGPDFDocument($0) }
    }

    // MARK: - The walks on a reader that cannot read

    @Test("A document with no catalog answers could-not-scan and hidden, not clean")
    func noCatalogAnswersCouldNotScan() throws {
        let document = cgDocument(Self.catalogless())
        // The shape CoreGraphics gives these bytes is part of the record: a
        // document with no catalog, or no document at all (the app's reader
        // stage refuses that shape on its own).
        #expect(document != nil, "CoreGraphics opened the catalog-less bytes")
        #expect(document?.catalog == nil, "the catalog-less bytes read no catalog")
        if let document {
            #expect(ActiveContentScan.firstLocation(in: document) == .couldNotScan)
            #expect(TextLayerExtractor.documentHasHiddenOCG(document) == true)
        }
    }

    @Test("A page that reads no dictionary answers could-not-scan")
    func pageWithoutDictionaryAnswersCouldNotScan() throws {
        let document = try #require(cgDocument(Self.pageWithoutDictionary()))
        #expect(document.numberOfPages == 1)
        #expect(ActiveContentScan.firstLocation(in: document) == .couldNotScan)
    }

    @Test("An action chain past the depth bound answers could-not-scan; one within it is active")
    func actionChainDepthBound() throws {
        let bound = ActiveContentScan.maxActionChainDepth
        let past = try #require(cgDocument(Self.openActionChain(length: bound + 1)))
        #expect(ActiveContentScan.firstLocation(in: past) == .couldNotScan)
        let within = try #require(cgDocument(Self.openActionChain(length: bound)))
        #expect(ActiveContentScan.firstLocation(in: within) == .openAction)
    }

    @Test("/OCProperties without its default configuration reads as hidden")
    func ocPropertiesWithoutDefaultConfigReadsHidden() throws {
        let document = try #require(cgDocument(Self.ocPropertiesWithoutDefaultConfig()))
        #expect(TextLayerExtractor.documentHasHiddenOCG(document) == true)
    }

    @Test("A plain readable document is clean on both walks")
    func plainDocumentIsClean() throws {
        let document = try #require(cgDocument(TestFixtures.blankPage()))
        #expect(ActiveContentScan.firstLocation(in: document) == nil)
        #expect(TextLayerExtractor.documentHasHiddenOCG(document) == false)
    }

    // MARK: - The per-page checks that cannot run

    @Test("The ink test with no bitmap to read, or no page size, reports an inkless glyph rather than none")
    func inkTestThatCannotRunReportsInkless() throws {
        // A PDF context has no bitmap data to read.
        let sink = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let pdfContext = try #require(CGContext(
            consumer: CGDataConsumer(data: sink as CFMutableData)!, mediaBox: &box, nil))
        #expect(pdfContext.data == nil)
        #expect(try PageRasterizer.hasInklessGlyph(
            context: pdfContext, entries: [], pageSize: CGSize(width: 612, height: 792)) == true)

        // A bitmap with no page size to map glyphs onto.
        let bitmap = try #require(createBitmapContext(width: 8, height: 8))
        #expect(try PageRasterizer.hasInklessGlyph(context: bitmap, entries: [], pageSize: .zero) == true)
        // The same bitmap with a page size and no glyphs has nothing inkless.
        #expect(try PageRasterizer.hasInklessGlyph(
            context: bitmap, entries: [], pageSize: CGSize(width: 8, height: 8)) == false)
    }

    @Test("A page with no page reference reads as referencing hidden content when the document has any")
    func pageWithoutReferenceReadsHidden() {
        let page = PDFPage()
        #expect(page.pageRef == nil)
        #expect(TextLayerExtractor.pageReferencesHiddenOCG(page, hasHiddenOCG: true) == true)
        // No hidden content in the document: nothing to reference.
        #expect(TextLayerExtractor.pageReferencesHiddenOCG(page, hasHiddenOCG: false) == false)
    }

    @Test("The vertical-writing check on a page with no page reference is unknown, not false")
    func verticalWritingUnknownWithoutReference() throws {
        #expect(TextLayerDetector.hasVerticalWritingMode(PDFPage()) == nil)
        let readable = try #require(PDFDocument(data: TestFixtures.blankPage())?.page(at: 0))
        #expect(TextLayerDetector.hasVerticalWritingMode(readable) == false)
    }
}
