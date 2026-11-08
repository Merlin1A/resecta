import Testing
import Foundation
import PDFKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
@testable import RedactionEngine

// The ink fit places a page's box from that page's own print. Two pages whose
// hidden text layers are the same, whose pictures sit inside form objects (so
// no direct image tells them apart) and whose print sits at different places
// must each get a box on their own words; and nothing read from one document
// places a box in the next.
//
// Privacy rule (audit-lint M-1): locate/read/report vocabulary.

@Suite("Ink fit: a page's box comes from its own print", .serialized, .tags(.search))
struct InkFitPageIdentityTests {

    static let lines: [(String, CGFloat, CGFloat)] = [
        ("Account holder DELIA HARTWELL", 100, 700),
        ("Payee NORTHLINE LOGISTICS", 100, 670),
        ("Reference 4827 Boise Idaho", 100, 640),
    ]
    static let word = "HARTWELL"
    static let pointSize: CGFloat = 14
    static let page = CGSize(width: 612, height: 792)
    static let dpi: CGFloat = 150

    /// A picture of the three printed lines, shifted `shift` points right.
    static func printJPEG(shift: CGFloat) throws -> Data {
        let scale = dpi / 72
        let w = Int(page.width * scale), h = Int(page.height * scale)
        let cs = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        let font = CTFontCreateWithName("Helvetica" as CFString, pointSize, nil)
        for (text, x, y) in lines {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            ctx.textPosition = CGPoint(x: x + shift, y: y)
            CTLineDraw(line, ctx)
        }
        let image = try #require(ctx.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// A scan of `shifts.count` pages: each page draws a form object holding
    /// its picture, then the same hidden (render mode 3) text layer at the
    /// unshifted positions, so every page has the same text, box and rotation.
    /// With `sharedPicture`, every page draws the one picture object, moved
    /// by its shift inside its form, so the pages' image bytes are the same too.
    static func scanPDF(shifts: [CGFloat], sharedPicture: Bool = false) throws -> Data {
        var objects: [Data] = []
        func add(_ s: String) -> Int { objects.append(Data(s.utf8)); return objects.count }
        func add(_ d: Data) -> Int { objects.append(d); return objects.count }
        func stream(_ dict: String, _ body: Data) -> Data {
            var d = Data("<< \(dict) /Length \(body.count) >>\nstream\n".utf8); d.append(body); d.append(Data("\nendstream".utf8)); return d
        }
        let catalog = add("<< /Type /Catalog /Pages 2 0 R >>")
        let pagesIndex = add("PLACEHOLDER")
        let font = add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
        var hidden = "3 Tr BT /F1 \(Int(pointSize)) Tf "
        for (text, x, y) in lines { hidden += "1 0 0 1 \(Int(x)) \(Int(y)) Tm (\(text)) Tj " }
        hidden += "ET"
        var kids: [Int] = []
        let scale = dpi / 72
        var sharedImage: Int?
        for shift in shifts {
            let image: Int
            if sharedPicture {
                if sharedImage == nil {
                    sharedImage = add(stream("/Type /XObject /Subtype /Image /Width \(Int(page.width * scale)) /Height \(Int(page.height * scale)) /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", try printJPEG(shift: 0)))
                }
                image = sharedImage!
            } else {
                image = add(stream("/Type /XObject /Subtype /Image /Width \(Int(page.width * scale)) /Height \(Int(page.height * scale)) /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", try printJPEG(shift: shift)))
            }
            let placement = sharedPicture ? "q 1 0 0 1 \(Int(shift)) 0 cm 612 0 0 792 0 0 cm /Im1 Do Q" : "q 612 0 0 792 0 0 cm /Im1 Do Q"
            let form = add(stream("/Type /XObject /Subtype /Form /BBox [-100 0 712 792] /Resources << /XObject << /Im1 \(image) 0 R >> >>",
                                  Data(placement.utf8)))
            let content = add(stream("", Data("/Fx1 Do \(hidden)".utf8)))
            kids.append(add("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents \(content) 0 R /Resources << /XObject << /Fx1 \(form) 0 R >> /Font << /F1 \(font) 0 R >> >> >>"))
        }
        objects[pagesIndex - 1] = Data("<< /Type /Pages /Kids [\(kids.map { "\($0) 0 R" }.joined(separator: " "))] /Count \(kids.count) >>".utf8)
        _ = catalog
        var out = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (i, object) in objects.enumerated() {
            offsets.append(out.count)
            out.append(Data("\(i + 1) 0 obj\n".utf8)); out.append(object); out.append(Data("\nendobj\n".utf8))
        }
        let xref = out.count
        out.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for o in offsets { out.append(Data(String(format: "%010d 00000 n \n", o).utf8)) }
        out.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return out
    }

    /// The word's own ink on a page printed at `shift`, from the font's metrics.
    static func wordInk(shift: CGFloat) -> CGRect {
        let font = CTFontCreateWithName("Helvetica" as CFString, pointSize, nil)
        func width(_ s: String) -> CGFloat {
            let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
            return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attributes)), nil, nil, nil))
        }
        return CGRect(x: 100 + shift + width("Account holder DELIA "), y: 700 - CTFontGetDescent(font),
                      width: width(word), height: CTFontGetAscent(font) + CTFontGetDescent(font))
    }

    /// The word's boxes by page, in points, from a text-layer search.
    static func boxes(_ document: PDFDocument) async -> [Int: CGRect] {
        var options = SearchOptions()
        options.includeOCR = false
        var out: [Int: CGRect] = [:]
        for await hit in DocumentSearcher().search(SendablePDFDocument(document), mode: .text(word, options: options), progress: { _, _ in }) {
            out[hit.pageIndex] = PageImageInkFitTests.points(hit.normalizedRect, page)
        }
        return out
    }

    /// Every pixel of the word's ink on `page` lies inside `box`.
    static func covers(_ box: CGRect, wordAt shift: CGFloat, on page: PDFPage) throws -> Bool {
        try PageImageInkFitTests.inkOutside(page, word: wordInk(shift: shift), boxes: [box]).share == 0
    }

    @Test("two pages with one hidden text and different print: each box covers its own page's word")
    func pagesWithOneTextAreFittedApart() async throws {
        let document = try #require(PDFDocument(data: try Self.scanPDF(shifts: [0, 40])))
        let first = try #require(document.page(at: 0)), second = try #require(document.page(at: 1))
        try #require(DocumentSearcher.carriesHiddenTextOverImage(first, cgPage: try #require(first.pageRef)), "the fit runs on these pages")
        try #require(first.string == second.string, "the two pages share a text layer")
        let boxes = await Self.boxes(document)
        let boxA = try #require(boxes[0]), boxB = try #require(boxes[1])
        #expect(try Self.covers(boxA, wordAt: 0, on: first), "page 1's box holds its word: \(boxA)")
        #expect(try Self.covers(boxB, wordAt: 40, on: second), "page 2's box holds its word, 40 pt right of page 1's: \(boxB)")
        #expect(boxB.minX > boxA.minX + 20, "the two boxes are not one box: \(boxA) \(boxB)")
    }

    @Test("two pages drawing one picture at different places: each box covers its own page's word")
    func pagesSharingOnePictureAreFittedApart() async throws {
        let document = try #require(PDFDocument(data: try Self.scanPDF(shifts: [0, 40], sharedPicture: true)))
        let first = try #require(document.page(at: 0)), second = try #require(document.page(at: 1))
        try #require(first.string == second.string, "the two pages share a text layer")
        let boxes = await Self.boxes(document)
        let boxA = try #require(boxes[0]), boxB = try #require(boxes[1])
        #expect(try Self.covers(boxA, wordAt: 0, on: first), "page 1's box holds its word: \(boxA)")
        #expect(try Self.covers(boxB, wordAt: 40, on: second), "page 2's box holds its word, 40 pt right of page 1's: \(boxB)")
        #expect(boxB.minX > boxA.minX + 20, "the two boxes are not one box: \(boxA) \(boxB)")
    }

    @Test("a closed document's read never places the next document's box")
    func closedDocumentReadsDoNotCarryOver() async throws {
        let before = try #require(PDFDocument(data: try Self.scanPDF(shifts: [0])))
        let boxBefore = try #require(await Self.boxes(before)[0])
        #expect(try Self.covers(boxBefore, wordAt: 0, on: try #require(before.page(at: 0))))
        // The document boundary the app crosses between two documents.
        DocumentSearcher.startNewInkFitSession()
        let after = try #require(PDFDocument(data: try Self.scanPDF(shifts: [40])))
        let page = try #require(after.page(at: 0))
        let boxAfter = try #require(await Self.boxes(after)[0])
        #expect(try Self.covers(boxAfter, wordAt: 40, on: page), "the next document's box holds its own word: \(boxAfter)")
    }
}
