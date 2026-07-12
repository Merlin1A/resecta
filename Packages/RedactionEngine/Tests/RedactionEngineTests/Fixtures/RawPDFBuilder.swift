import Foundation
import PDFKit
#if canImport(UIKit)
import UIKit
#endif
import ImageIO
@testable import RedactionEngine

// TEST §2.1 — Programmatic PDF fixture construction.
// Builds minimal valid PDFs by hand-constructing byte streams.

/// A PDF object with its reference ID and serialized content.
struct PDFObject {
    let id: Int
    let content: String
}

/// Build a raw PDF from hand-constructed objects.
/// Returns valid PDF data that can be written to a URL and opened with PDFDocument.
/// See TESTING_AND_CI.md §2.1 for the specification.
///
/// Offsets are recorded in UTF-8 byte units so the xref entries align with
/// the actual bytes PDFKit sees — the header carries four non-ASCII bytes
/// (`%\u{E2}\u{E3}\u{CF}\u{D3}\n`, the PDF "binary header" comment) that
/// Swift's `String.count` reports as four single Characters. Counting
/// `body.utf8.count` keeps the xref consistent with the bytes on disk and
/// avoids tripping CGPDF's content-stream parser on otherwise-valid stream
/// payloads (e.g., literal-string octal escapes).
func buildRawPDF(objects: [PDFObject], rootId: Int, infoId: Int? = nil) -> Data {
    var body = ""
    var offsets: [Int: Int] = [:]

    let header = "%PDF-1.4\n%\u{E2}\u{E3}\u{CF}\u{D3}\n"
    body = header

    for obj in objects {
        offsets[obj.id] = body.utf8.count
        body += "\(obj.id) 0 obj\n\(obj.content)\nendobj\n\n"
    }

    let xrefOffset = body.utf8.count
    let sortedIds = objects.map(\.id).sorted()
    let maxId = sortedIds.last ?? 0

    var xref = "xref\n0 \(maxId + 1)\n"
    xref += "0000000000 65535 f \n"
    for id in 1...maxId {
        if let offset = offsets[id] {
            xref += String(format: "%010d 00000 n \n", offset)
        } else {
            xref += "0000000000 00000 f \n"
        }
    }

    let infoEntry = infoId.map { " /Info \($0) 0 R" } ?? ""
    let trailer = """
    trailer
    << /Size \(maxId + 1) /Root \(rootId) 0 R\(infoEntry) >>
    startxref
    \(xrefOffset)
    %%EOF
    """

    body += xref + trailer
    return Data(body.utf8)
}

// MARK: - TestFixtures Namespace

enum TestFixtures {

    /// Minimal valid 1-page PDF (TEST §2.2).
    static func blankPage(width: Int = 612, height: Int = 792) -> Data {
        buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [0 0 \(width) \(height)] \
                /Contents 4 0 R /Resources << >> >>
                """),
            PDFObject(id: 4, content: "<< /Length 0 >>\nstream\n\nendstream"),
        ], rootId: 1)
    }

    /// Minimal 1-page PDF whose page dictionary has NO /Resources entry at all
    /// (blankPage carries an empty-but-present `/Resources << >>`). CAT-380A:
    /// Layer 8 must WARN — not .pass — when a page has no page-level /Resources.
    static func pageWithoutResources() -> Data {
        buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [0 0 612 792] /Contents 4 0 R >>
                """),
            PDFObject(id: 4, content: "<< /Length 0 >>\nstream\n\nendstream"),
        ], rootId: 1)
    }

    /// PDF with /JavaScript action in catalog (TEST §2.3).
    /// Layer 4 structural check must FAIL on this.
    static func withJavaScript() -> Data {
        buildRawPDF(objects: [
            PDFObject(id: 1, content: """
                << /Type /Catalog /Pages 2 0 R \
                /JavaScript << /Names [(script1) 5 0 R] >> >>
                """),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [0 0 612 792] \
                /Contents 4 0 R /Resources << >> >>
                """),
            PDFObject(id: 4, content: "<< /Length 0 >>\nstream\n\nendstream"),
            PDFObject(id: 5, content: """
                << /Type /Action /S /JavaScript \
                /JS (app.alert\\('test'\\)) >>
                """),
        ], rootId: 1)
    }

    /// PDF with an arbitrary key injected into the catalog.
    /// Use for testing Layer 4 against various FAIL/WARN keys.
    static func withCatalogKey(_ key: String, value: String = "<< >>") -> Data {
        buildRawPDF(objects: [
            PDFObject(id: 1, content: """
                << /Type /Catalog /Pages 2 0 R /\(key) \(value) >>
                """),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [0 0 612 792] \
                /Contents 4 0 R /Resources << >> >>
                """),
            PDFObject(id: 4, content: "<< /Length 0 >>\nstream\n\nendstream"),
        ], rootId: 1)
    }

    /// PDF with /Info dictionary containing metadata.
    /// Layer 5 must detect these keys. /Info is wired to the trailer via infoId.
    static func withMetadata(_ entries: [String: String]) -> Data {
        let infoEntries = entries.map { "/\($0.key) (\($0.value))" }.joined(separator: " ")
        return buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [0 0 612 792] \
                /Contents 4 0 R /Resources << >> >>
                """),
            PDFObject(id: 4, content: "<< /Length 0 >>\nstream\n\nendstream"),
            PDFObject(id: 5, content: "<< \(infoEntries) >>"),
        ], rootId: 1, infoId: 5)
    }

    /// PDF with /Info dictionary built from a raw body string. Lets callers
    /// inject hex-string values (`<DEADBEEF>`) or Name objects (`/Hidden`)
    /// that the keyed `withMetadata` cannot express. M3 fixture support.
    static func withMetadataRaw(infoDictBody: String) -> Data {
        buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [0 0 612 792] \
                /Contents 4 0 R /Resources << >> >>
                """),
            PDFObject(id: 4, content: "<< /Length 0 >>\nstream\n\nendstream"),
            PDFObject(id: 5, content: "<< \(infoDictBody) >>"),
        ], rootId: 1, infoId: 5)
    }

    /// PDF carrying an XMP /Metadata stream but NO /Info dictionary (no infoId).
    /// CAT-378: the Layer 5 XMP byte-scan must run even when /Info is absent.
    /// The raw bytes contain the `<?xpacket` marker the scan looks for.
    static func withXMPNoInfo() -> Data {
        let xmp = "<?xpacket begin=\"\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>"
            + "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"></x:xmpmeta>"
            + "<?xpacket end=\"w\"?>"
        return buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R /Metadata 5 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [0 0 612 792] \
                /Contents 4 0 R /Resources << >> >>
                """),
            PDFObject(id: 4, content: "<< /Length 0 >>\nstream\n\nendstream"),
            PDFObject(id: 5, content: """
                << /Type /Metadata /Subtype /XML /Length \(xmp.utf8.count) >>
                stream
                \(xmp)
                endstream
                """),
        ], rootId: 1)  // no infoId → no /Info dictionary
    }

    /// Minimal JPEG byte stream for CAT-357 Part B tests: SOI, one APP1 segment
    /// per entry in `app1Payloads` (each = length-prefixed `Exif\0\0` + the
    /// entry's UTF-8 bytes), then EOI. `truncateLastLengthTo`, when set, writes
    /// the LAST segment's declared length as that value WITHOUT trimming bytes —
    /// exercises the truncated/oversized-length adversarial path (declared > or <
    /// the bytes actually present). Not a decodable image; used only to exercise
    /// the raw APP1/EXIF byte scan.
    static func exifJPEG(app1Payloads: [String], truncateLastLengthTo: Int? = nil) -> Data {
        var jpeg = Data([0xFF, 0xD8])  // SOI
        let magic: [UInt8] = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]  // "Exif\0\0"
        for (idx, text) in app1Payloads.enumerated() {
            let payload = magic + Array(text.utf8)
            let declaredLen = (idx == app1Payloads.count - 1 ? truncateLastLengthTo : nil)
                ?? (payload.count + 2)  // +2 for the length field itself
            jpeg.append(contentsOf: [0xFF, 0xE1,
                                     UInt8((declaredLen >> 8) & 0xFF),
                                     UInt8(declaredLen & 0xFF)])
            jpeg.append(contentsOf: payload)
        }
        jpeg.append(contentsOf: [0xFF, 0xD9])  // EOI
        return jpeg
    }

    /// Binary PDF whose single page carries one image XObject with `/Filter
    /// /DCTDecode` and the given raw bytes as its stream — so CGPDFStreamCopyData
    /// reports `.jpegEncoded` and extractRawJPEGStreams returns these exact
    /// bytes (APP1/EXIF intact). Built as Data (not the String buildRawPDF)
    /// because the stream is binary. CAT-357 Part B.
    static func pdfWithDCTImageStream(_ jpeg: Data) -> Data {
        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }
        append("%PDF-1.4\n%\u{E2}\u{E3}\u{CF}\u{D3}\n")
        let off1 = body.count
        append("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")
        let off2 = body.count
        append("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n")
        let off3 = body.count
        append("""
            3 0 obj
            << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] \
            /Contents 4 0 R /Resources << /XObject << /Im0 5 0 R >> >> >>
            endobj

            """)
        let off4 = body.count
        append("4 0 obj\n<< /Length 0 >>\nstream\n\nendstream\nendobj\n")
        let off5 = body.count
        append("""
            5 0 obj
            << /Type /XObject /Subtype /Image /Width 1 /Height 1 \
            /BitsPerComponent 8 /ColorSpace /DeviceRGB /Filter /DCTDecode \
            /Length \(jpeg.count) >>
            stream

            """)
        body.append(jpeg)
        append("\nendstream\nendobj\n")
        let xrefOff = body.count
        append("xref\n0 6\n0000000000 65535 f \n")
        for off in [off1, off2, off3, off4, off5] {
            append(String(format: "%010d 00000 n \n", off))
        }
        append("trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n\(xrefOff)\n%%EOF")
        return body
    }

    /// Write PDF data to a temp URL and open as PDFDocument.
    /// Verification layers require URL-based documents (documentURL must be non-nil).
    static func writeTempPDF(_ data: Data, prefix: String = "fixture_") throws -> (PDFDocument, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)\(UUID().uuidString).pdf")
        try data.write(to: url)
        guard let doc = PDFDocument(url: url) else {
            throw FixtureError.invalidPDF
        }
        return (doc, url)
    }

    enum FixtureError: Error {
        case invalidPDF
    }

    // MARK: - Sandwich Pipeline Fixtures (TEST §2.8–§2.10)

    /// PDF with known text at known positions for testing the Searchable
    /// Redaction pipeline. Uses UIGraphicsPDFRenderer for real text layer.
    /// See TEST §2.8.
    static func textLayerPDF(
        text: String = "John Smith SSN 123-45-6789 lives at 742 Evergreen Terrace",
        fontSize: CGFloat = 24
    ) -> Data {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        return renderer.pdfData { context in
            context.beginPage()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize),
                .foregroundColor: UIColor.black
            ]
            (text as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: attrs)
        }
    }

    /// PDF with text positioned for boundary testing — characters at exact
    /// redaction boundaries test the 2-point safety margin (ENGINE §5B.2).
    /// Uses Courier for predictable per-character widths. See TEST §2.9.
    static func boundaryCharacterPDF() -> Data {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        return renderer.pdfData { context in
            context.beginPage()
            let font = UIFont(name: "Courier", size: 24)!
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.black
            ]
            ("ABCDEFGH" as NSString).draw(at: CGPoint(x: 72, y: 100), withAttributes: attrs)
        }
    }

    /// PDF with CJK text — may trigger fallback if >5% U+FFFD in extracted text.
    /// See TEST §2.10.
    static func cjkTextPDF() -> Data {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        return renderer.pdfData { context in
            context.beginPage()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 24),
                .foregroundColor: UIColor.black
            ]
            ("日本語テスト Chinese 中文" as NSString).draw(
                at: CGPoint(x: 72, y: 72), withAttributes: attrs
            )
        }
    }

    /// PDF with no text — only a drawn shape. See TEST §2.10.
    static func imageOnlyPDF() -> Data {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        return renderer.pdfData { context in
            context.beginPage()
            UIColor.blue.setFill()
            UIBezierPath(ovalIn: CGRect(x: 200, y: 300, width: 200, height: 200)).fill()
        }
    }

    // MARK: - Phase 12 Fixtures

    /// PDF with visible text covered by a black annotation — the Manafort/Calipari
    /// attack vector. Text remains extractable despite visual concealment.
    /// See TEST §2.4.
    static func fakeRedaction(text: String = "CLASSIFIED SECRET") -> Data {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let pdfData = renderer.pdfData { context in
            context.beginPage()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 24),
                .foregroundColor: UIColor.black
            ]
            (text as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: attrs)
        }

        guard let doc = PDFDocument(data: pdfData),
              let page = doc.page(at: 0) else {
            fatalError("Failed to create fake redaction fixture")
        }

        // Black-filled square annotation covering the text — see TEST §2.4
        let textBounds = CGRect(x: 70, y: 690, width: 300, height: 40)
        let annotation = PDFAnnotation(bounds: textBounds, forType: .square, withProperties: nil)
        annotation.color = .black
        annotation.interiorColor = .black
        annotation.border = PDFBorder()
        page.addAnnotation(annotation)

        // Self-validate: text must still be extractable under annotation
        assert(page.string?.contains(text) == true,
               "Fixture broken: text should be extractable under annotation")

        return doc.dataRepresentation()!
    }

    /// PDF with incremental update — original objects remain after %%EOF,
    /// potentially recoverable. Tests Layer 4 %%EOF counter. See TEST §2.5.
    static func incrementalUpdate(
        originalText: String = "ORIGINAL SECRET",
        updatedText: String = "REDACTED"
    ) -> Data {
        // Create base PDF with text
        var base = textLayerPDF(text: originalText)

        // Append an incremental update after the existing %%EOF.
        // This simulates a PDF editor that appends rather than rewrites.
        // The original text objects remain in the file bytes.
        let updateChunk = """
        \n
        6 0 obj
        << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 7 0 R >>
        endobj

        7 0 obj
        << /Length \(updatedText.count + 35) >>
        stream
        BT /Helvetica 24 Tf 72 720 Td (\(updatedText)) Tj ET
        endstream
        endobj

        xref
        6 2
        0000000000 00000 n \n0000000000 00000 n \n
        trailer
        << /Size 8 /Root 1 0 R /Prev 0 >>
        startxref
        0
        %%EOF
        """
        base.append(Data(updateChunk.utf8))
        return base
    }

    /// JPEG image with EXIF GPS metadata. See TEST §2.6.
    static func jpegWithGPS(
        latitude: Double = 38.8977,
        longitude: Double = -77.0365,
        imageSize: CGSize = CGSize(width: 200, height: 200)
    ) -> Data {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil,
            width: Int(imageSize.width), height: Int(imageSize.height),
            bitsPerComponent: 8, bytesPerRow: Int(imageSize.width) * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ), let image = ctx.makeImage() else {
            fatalError("Failed to create GPS test image")
        }

        let jpegData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            jpegData, "public.jpeg" as CFString, 1, nil
        ) else { fatalError("Failed to create image destination") }

        let gpsDict: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: abs(latitude),
            kCGImagePropertyGPSLatitudeRef: latitude >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude: abs(longitude),
            kCGImagePropertyGPSLongitudeRef: longitude >= 0 ? "E" : "W",
        ]

        let properties: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: gpsDict
        ]

        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        CGImageDestinationFinalize(dest)
        return jpegData as Data
    }

    /// PDF whose single page embeds the `jpegWithGPS` JPEG as a DCTDecode
    /// image XObject via JPEG-data-provider passthrough (same mechanism as
    /// `twoImageJPEGPagePDF`), so the EXIF/GPS APP1 segment survives into the
    /// source PDF's image stream verbatim. q34 (QD-15): source fixture for the
    /// export-side metadata pin — the test asserts the metadata IS present in
    /// this source before asserting it is absent from the pipeline output.
    static func gpsJPEGPagePDF(
        latitude: Double = 38.8977,
        longitude: Double = -77.0365
    ) -> Data {
        let jpeg = jpegWithGPS(latitude: latitude, longitude: longitude)
        let provider = CGDataProvider(data: jpeg as CFData)!
        let image = CGImage(
            jpegDataProviderSource: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gpsimg_\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        ctx.draw(image, in: CGRect(x: 106, y: 246, width: 400, height: 400))
        ctx.endPDFPage()
        ctx.closePDF()
        defer { try? FileManager.default.removeItem(at: url) }
        return (try? Data(contentsOf: url)) ?? Data()
    }

    /// PDF whose single page carries TWO JPEG (DCTDecode) image XObjects, each
    /// rendered from text. CAT-377: `extractPageImages` must return both, and
    /// runLayer2OCR must OCR each. Images are wrapped via a JPEG data provider
    /// so CGPDFContext embeds them as DCTDecode (passthrough), which is what
    /// `extractPageImages` filters on.
    static func twoImageJPEGPagePDF(
        textA: String = "ALPHA", textB: String = "BRAVO"
    ) -> Data {
        func jpegBackedImage(_ text: String) -> CGImage {
            let size = CGSize(width: 300, height: 150)
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let ctx = CGContext(
                data: nil, width: Int(size.width), height: Int(size.height),
                bitsPerComponent: 8, bytesPerRow: Int(size.width) * 4, space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
            ctx.textMatrix = .identity
            let font = CTFontCreateWithName("Helvetica" as CFString, 60, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: text,
                attributes: [kCTFontAttributeName as NSAttributedString.Key: font]))
            ctx.textPosition = CGPoint(x: 20, y: 55)
            CTLineDraw(line, ctx)
            let raw = ctx.makeImage()!
            let jpeg = NSMutableData()
            let dest = CGImageDestinationCreateWithData(
                jpeg, "public.jpeg" as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, raw, nil)
            CGImageDestinationFinalize(dest)
            // Re-wrap with a JPEG data provider so the draw embeds DCTDecode.
            let provider = CGDataProvider(data: jpeg)!
            return CGImage(
                jpegDataProviderSource: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent)!
        }
        let imgA = jpegBackedImage(textA)
        let imgB = jpegBackedImage(textB)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("twoimg_\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        ctx.draw(imgA, in: CGRect(x: 50, y: 520, width: 300, height: 150))  // upper
        ctx.draw(imgB, in: CGRect(x: 50, y: 200, width: 300, height: 150))  // lower
        ctx.endPDFPage()
        ctx.closePDF()
        defer { try? FileManager.default.removeItem(at: url) }
        return (try? Data(contentsOf: url)) ?? Data()
    }

    /// PDF with non-zero origin mediaBox — tests cropBox origin handling.
    /// See TEST §2.11.
    static func nonZeroOriginPDF() -> Data {
        buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [50 50 662 842] \
                /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>
                """),
            PDFObject(id: 4, content: """
                << /Length 44 >>
                stream
                BT /F1 24 Tf 100 700 Td (TEST TEXT) Tj ET
                endstream
                """),
            PDFObject(id: 5, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"),
        ], rootId: 1)
    }

    /// Non-zero-origin PDF whose text sits at a user-space X *smaller* than the
    /// cropBox origin, so the absolute and cropBox-local coordinate frames are
    /// discriminable. MediaBox origin (200, 200); text drawn at user-space
    /// `220 700 Td` → local minX ≈ 20 ≪ origin.x 200. F13/CAT-366 (ADV-2 A2-6):
    /// the existing `nonZeroOriginPDF` (origin 50, text at 100) cannot tell the
    /// frames apart — local minX 50 and absolute 100 both clear its `≥ 49`
    /// assert — so the origin-frame probe and the CropBox-local correction guard
    /// run against THIS fixture instead.
    static func nonZeroOriginDiscriminatingPDF() -> Data {
        buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [200 200 812 992] \
                /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>
                """),
            PDFObject(id: 4, content: """
                << /Length 44 >>
                stream
                BT /F1 24 Tf 220 700 Td (TEST TEXT) Tj ET
                endstream
                """),
            PDFObject(id: 5, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"),
        ], rootId: 1)
    }

    /// PDF with explicit cropBox smaller than mediaBox. See TEST §2.11.
    static func croppedPDF() -> Data {
        buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [0 0 612 792] \
                /CropBox [36 36 576 756] \
                /Contents 4 0 R /Resources << >> >>
                """),
            PDFObject(id: 4, content: "<< /Length 0 >>\nstream\n\nendstream"),
        ], rootId: 1)
    }

    /// PDF with /Rotate key — tests rotation-aware rendering. See TEST §2.11.
    static func rotatedPDF(rotation: Int = 90) -> Data {
        buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [0 0 612 792] \
                /Rotate \(rotation) \
                /Contents 4 0 R /Resources << >> >>
                """),
            PDFObject(id: 4, content: "<< /Length 0 >>\nstream\n\nendstream"),
        ], rootId: 1)
    }

    /// PDF with OCG hidden layer containing extractable text.
    /// page.string extracts hidden OCG text, which would leak into the output
    /// text layer if not caught. See TEST §2.12.
    static func ocgHiddenLayerPDF(hiddenText: String = "HIDDEN SECRET") -> Data {
        let streamContent = "/OC /OC1 BDC\nBT /F1 24 Tf 72 720 Td (\(hiddenText)) Tj ET\nEMC"
        return buildRawPDF(objects: [
            PDFObject(id: 1, content: """
                << /Type /Catalog /Pages 2 0 R \
                /OCProperties << /OCGs [5 0 R] \
                /D << /OFF [5 0 R] >> >> >>
                """),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [0 0 612 792] \
                /Contents 4 0 R \
                /Resources << /Font << /F1 6 0 R >> \
                /Properties << /OC1 5 0 R >> >> >>
                """),
            PDFObject(id: 4, content: "<< /Length \(streamContent.count) >>\nstream\n\(streamContent)\nendstream"),
            PDFObject(id: 5, content: "<< /Type /OCG /Name (Hidden Layer) >>"),
            PDFObject(id: 6, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"),
        ], rootId: 1)
    }

    /// PDF with PII terms embedded in fictional context for sensitive term
    /// absence testing. Wraps textLayerPDF with terms in natural context.
    /// See OQ-3 resolution, TEST §3.1.
    static func documentWithPII(terms: [String]) -> Data {
        let context = "Jane A. Sample of 742 Evergreen Terrace, Springfield, IL 62704. "
            + "SSN: 123-45-6789. Credit Card: 4111-1111-1111-1111. "
            + "Additional terms: " + terms.joined(separator: ", ") + "."
        return textLayerPDF(text: context, fontSize: 12)
    }

    /// Geometry of `rotatedTextPDF`, in UNROTATED page/user space (y-up). Shared
    /// with the S15 CAT-353 matrix so a region can target a known word. Two words
    /// sit in different quadrants so every rotation — and every mirror error — is
    /// detectable. Absolute Td = `cropBoxOrigin` + local.
    static let rotatedTextBaseSize = CGSize(width: 612, height: 792)
    static let rotatedTextAnchorLocal = CGPoint(x: 72, y: 700)   // "ANCHOR" upper-left
    static let rotatedTextMarkerLocal = CGPoint(x: 360, y: 90)   // "MARKER" lower-right

    /// Rotated PDF with visible, **asymmetrically placed** extractable text — for
    /// the S15 E1 selection-frame probe and the CAT-353 (T_rot) coordinate matrix.
    ///
    /// Built raw so the MediaBox origin (`cropBoxOrigin`) and `/Rotate` are
    /// byte-exact and the text stays extractable via `page.string` /
    /// `page.selection(for:)` — the raw Helvetica Type1 path already proves
    /// selectable text on a non-zero-origin page (`nonZeroOriginPDF`, exercised by
    /// `nonZeroCropBoxSelectionFrameProbe`). For `cropBoxOrigin == .zero` the
    /// MediaBox is `[0 0 612 792]`; the two existing `rotation:`-only callers are
    /// unaffected. See TEST §2.11, ENGINE §5B, ADV-2 A2-7.
    static func rotatedTextPDF(rotation: Int = 90, cropBoxOrigin: CGPoint = .zero) -> Data {
        let ox = Int(cropBoxOrigin.x.rounded())
        let oy = Int(cropBoxOrigin.y.rounded())
        let w = Int(rotatedTextBaseSize.width)
        let h = Int(rotatedTextBaseSize.height)
        let ax = ox + Int(rotatedTextAnchorLocal.x), ay = oy + Int(rotatedTextAnchorLocal.y)
        let bx = ox + Int(rotatedTextMarkerLocal.x), by = oy + Int(rotatedTextMarkerLocal.y)
        let stream = """
            BT /F1 24 Tf \(ax) \(ay) Td (ANCHOR) Tj ET
            BT /F1 24 Tf \(bx) \(by) Td (MARKER) Tj ET
            """
        return buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [\(ox) \(oy) \(ox + w) \(oy + h)] \
                /Rotate \(rotation) \
                /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>
                """),
            PDFObject(id: 4, content: "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"),
            PDFObject(id: 5, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"),
        ], rootId: 1)
    }

    /// CTLineDraw invisible Courier PDF — 10 NATO alphabet words drawn with
    /// CoreText rendering mode 3 (invisible). Validates text extraction from
    /// invisible text layers. Port of GenerateCTLinePDF.swift.
    static func ctLineDrawCourierPDF() -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctline_fixture_\(UUID().uuidString).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil)!
        context.beginPDFPage(nil)
        context.setTextDrawingMode(.invisible)
        let font = CTFontCreateWithName("Courier" as CFString, 12.0, nil)
        let words: [(String, CGFloat)] = [
            ("ALPHA", 700), ("BRAVO", 680), ("CHARLIE", 660),
            ("DELTA", 640), ("ECHO", 620), ("FOXTROT", 600),
            ("GOLF", 580), ("HOTEL", 560), ("INDIA", 540), ("JULIET", 520),
        ]
        for (word, y) in words {
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font
            ]
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: word, attributes: attrs)
            )
            context.textPosition = CGPoint(x: 72, y: y)
            CTLineDraw(line, context)
        }
        context.endPDFPage()
        context.closePDF()
        defer { try? FileManager.default.removeItem(at: url) }
        return (try? Data(contentsOf: url)) ?? Data()
    }

    /// Render a text PDF at 300 DPI to produce a CGImage for pixel-level tests.
    /// Named Async because renderPage is async. See OQ-3 resolution, TEST §3.4.
    static func textPageImageAsync() async throws -> CGImage {
        let pdfData = textLayerPDF()
        guard let doc = PDFDocument(data: pdfData),
              let page = doc.page(at: 0) else {
            throw FixtureError.invalidPDF
        }
        let rasterizer = PageRasterizer()
        return try await rasterizer.renderPage(page, pageIndex: 0, dpi: 300)
    }

    // MARK: - Phase 1 Audit Fixtures

    /// PDF with embedded file attachment via /Names -> /EmbeddedFiles name tree.
    /// Tests audit embedded file detection.
    static func withEmbeddedFile(filename: String = "secret.txt") -> Data {
        buildRawPDF(objects: [
            PDFObject(id: 1, content: """
                << /Type /Catalog /Pages 2 0 R \
                /Names << /EmbeddedFiles << /Names [(\(filename)) 5 0 R] >> >> >>
                """),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [0 0 612 792] \
                /Contents 4 0 R /Resources << >> >>
                """),
            PDFObject(id: 4, content: "<< /Length 0 >>\nstream\n\nendstream"),
            PDFObject(id: 5, content: """
                << /Type /Filespec /F (\(filename)) \
                /EF << /F 6 0 R >> >>
                """),
            PDFObject(id: 6, content: "<< /Length 11 >>\nstream\nhello world\nendstream"),
        ], rootId: 1)
    }

    /// PDF with annotations of specified subtypes. Uses PDFKit API.
    /// Tests audit annotation analysis.
    static func withAnnotations(subtypes: [PDFAnnotationSubtype]) -> Data {
        let data = blankPage()
        guard let doc = PDFDocument(data: data),
              let page = doc.page(at: 0) else {
            fatalError("Failed to create annotation fixture")
        }

        for (index, subtype) in subtypes.enumerated() {
            let bounds = CGRect(x: 72, y: 700 - CGFloat(index * 50), width: 100, height: 30)
            let annotation = PDFAnnotation(bounds: bounds, forType: subtype, withProperties: nil)
            if subtype == .highlight {
                annotation.color = .yellow
            }
            page.addAnnotation(annotation)
        }

        return doc.dataRepresentation()!
    }

    // MARK: - Searchable Trust-Parity Fixtures (SVT-* tightenings)
    //
    // See the trust-parity plan §6 and the Red-Team table at §5 for the
    // attack class each fixture exercises.

    /// PDF where the reconstructed Courier `/Font` dict carries a
    /// `/ToUnicode` CMap on an ACCEPTED Courier-suffixed `/BaseFont`.
    /// Originally the RT-4 attack fixture (EXP-E5.1 era: any CMap FAILed);
    /// since the J-5 SVT-4 refinement (2026-06-09, EXP-E6.2: the writer
    /// emits load-bearing CMaps for encoding-external glyphs) this shape is
    /// INTENTIONALLY tolerated — it now backs the documented-residual tests
    /// (`rt4AcceptedSubsetCMapResidualNote`, RT-6). The re-pointed attack
    /// fixture is `withToUnicodeOnUnacceptedFont()`.
    static func withToUnicodeOnReconstructedFont() -> Data {
        let toUnicode = """
        /CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n\
        /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n\
        /CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n\
        1 begincodespacerange <00> <FF> endcodespacerange\n\
        1 beginbfchar <41> <0041> endbfchar\n\
        endcmap CMapName currentdict /CMap defineresource pop end end
        """
        return buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [0 0 612 792] \
                /Contents 4 0 R \
                /Resources << /Font << /F1 5 0 R >> >> >>
                """),
            PDFObject(id: 4, content: "<< /Length 0 >>\nstream\n\nendstream"),
            PDFObject(id: 5, content: """
                << /Type /Font /Subtype /TrueType \
                /BaseFont /AAAAAB+Courier \
                /ToUnicode 6 0 R >>
                """),
            PDFObject(id: 6, content: "<< /Length \(toUnicode.utf8.count) >>\nstream\n\(toUnicode)\nendstream"),
        ], rootId: 1)
    }

    /// PDF where a `/ToUnicode` CMap rides on a font whose `/BaseFont` is
    /// NOT an accepted CGPDFContext monospace subset. The RT-4-class
    /// structural detection that survives the J-5 SVT-4 refinement
    /// (2026-06-09): the `/BaseFont` accept-check FAILs this font with or
    /// without the CMap, so a CMap smuggled on an unaccepted font is still
    /// reported. See RT-4 (re-pointed), fix-plan §3.4 / §4.2 Branch B.
    static func withToUnicodeOnUnacceptedFont() -> Data {
        let toUnicode = """
        /CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n\
        /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n\
        /CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n\
        1 begincodespacerange <00> <FF> endcodespacerange\n\
        1 beginbfchar <41> <0041> endbfchar\n\
        endcmap CMapName currentdict /CMap defineresource pop end end
        """
        return buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [0 0 612 792] \
                /Contents 4 0 R \
                /Resources << /Font << /F1 5 0 R >> >> >>
                """),
            PDFObject(id: 4, content: "<< /Length 0 >>\nstream\n\nendstream"),
            PDFObject(id: 5, content: """
                << /Type /Font /Subtype /TrueType \
                /BaseFont /AAAAAB+Helvetica \
                /ToUnicode 6 0 R >>
                """),
            PDFObject(id: 6, content: "<< /Length \(toUnicode.utf8.count) >>\nstream\n\(toUnicode)\nendstream"),
        ], rootId: 1)
    }

    /// PDF with a sensitive term written as a literal string inside a
    /// text-show operator. Layer 3's raw-byte scan excludes stream ranges,
    /// so a term whose only occurrence is inside a content stream slips
    /// past the structural pass. The SVT-3 tightening (§4.1) re-scans
    /// PDFKit's decoded `page.string`, which surfaces the term.
    /// See RT-7 (basic case).
    static func withSensitiveTermInTextStream(term: String) -> Data {
        let stream = "BT /F1 24 Tf 100 700 Td (\(term)) Tj ET"
        return buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [0 0 612 792] \
                /Contents 4 0 R \
                /Resources << /Font << /F1 5 0 R >> >> >>
                """),
            PDFObject(id: 4, content: """
                << /Length \(stream.utf8.count) >>
                stream
                \(stream)
                endstream
                """),
            PDFObject(id: 5, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"),
        ], rootId: 1)
    }

    /// Three-page PDF with a Square annotation on pages 1 and 3 (0-based 0
    /// and 2); page 2 is clean. Layer 1 must report BOTH pages in one run —
    /// accumulated page list, not a first-hit return.
    static func threePageAnnotationsOnFirstAndThird() -> Data {
        let pageBody = """
            << /Type /Page /Parent 2 0 R \
            /MediaBox [0 0 612 792] \
            /Contents 6 0 R /Resources << >>
            """
        let annot = "<< /Type /Annot /Subtype /Square /Rect [10 10 100 100] >>"
        return buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>"),
            PDFObject(id: 3, content: pageBody + " /Annots [7 0 R] >>"),
            PDFObject(id: 4, content: pageBody + " >>"),
            PDFObject(id: 5, content: pageBody + " /Annots [8 0 R] >>"),
            PDFObject(id: 6, content: "<< /Length 0 >>\nstream\n\nendstream"),
            PDFObject(id: 7, content: annot),
            PDFObject(id: 8, content: annot),
        ], rootId: 1)
    }

    /// Three-page PDF with a sensitive term in a text-show content stream on
    /// pages 1 and 3 (0-based 0 and 2); page 2 is blank. Multi-page variant
    /// of `withSensitiveTermInTextStream` — Layer 3's SVT-3 decoded-page
    /// re-scan (and Layer 1's selectable-text pass in Secure Rasterization)
    /// must report BOTH pages in one run.
    static func withSensitiveTermOnFirstAndThirdPages(term: String) -> Data {
        let stream = "BT /F1 24 Tf 100 700 Td (\(term)) Tj ET"
        let textPageBody = """
            << /Type /Page /Parent 2 0 R \
            /MediaBox [0 0 612 792] \
            /Contents 6 0 R \
            /Resources << /Font << /F1 8 0 R >> >> >>
            """
        return buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>"),
            PDFObject(id: 3, content: textPageBody),
            PDFObject(id: 4, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [0 0 612 792] \
                /Contents 7 0 R /Resources << >> >>
                """),
            PDFObject(id: 5, content: textPageBody),
            PDFObject(id: 6, content: """
                << /Length \(stream.utf8.count) >>
                stream
                \(stream)
                endstream
                """),
            PDFObject(id: 7, content: "<< /Length 0 >>\nstream\n\nendstream"),
            PDFObject(id: 8, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"),
        ], rootId: 1)
    }

    /// PDF with a sensitive term encoded via UTF-16 surrogate-pair sequences
    /// inside a text-show literal string. Raw bytes carry the surrogate
    /// halves directly via `\NNN` octal escapes (PDF 1.7 §7.9.2.2 Literal
    /// String). PDFKit's `page.string` and `CGPDFStringCopyTextString` both
    /// decode the surrogate halves; Layer 3 SVT-3 and Layer 10 SVT-5 each
    /// surface the decoded term via their respective Aho-Corasick passes.
    ///
    /// The fixture wraps the term in a UTF-16BE encoded literal: a `\xFE\xFF`
    /// BOM (PDF text-string spec) followed by each Swift Character's UTF-16
    /// code units. Supplementary-plane characters legitimately occupy two
    /// 16-bit code units (surrogate pairs); BMP characters occupy one. This
    /// shape is the canonical PDF literal-text encoding that
    /// `CGPDFStringCopyTextString` is documented to decode.
    /// See RT-7 (surrogate-pair variant), plan §4.5 / §6.
    static func withSurrogatePairSensitiveTerm(term: String) -> Data {
        // UTF-16BE bytes prefixed with the BOM `\xFE\xFF` (PDF text-string
        // encoding marker). Each UTF-16 code unit is emitted as two octal
        // escape sequences so the literal-string body remains pure ASCII at
        // the byte level — necessary because raw 0x00–0x1F bytes inside a
        // PDF literal `(...)` operand would break the parser. The escapes
        // round-trip through CGPDFStringCopyTextString verbatim.
        var bytes: [UInt8] = [0xFE, 0xFF]
        for unit in term.utf16 {
            bytes.append(UInt8(unit >> 8))
            bytes.append(UInt8(unit & 0xFF))
        }
        let encoded = bytes
            .map { String(format: "\\%03o", $0) }
            .joined()
        let stream = "BT /F1 24 Tf 100 700 Td (\(encoded)) Tj ET"
        return buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [0 0 612 792] \
                /Contents 4 0 R \
                /Resources << /Font << /F1 5 0 R >> >> >>
                """),
            PDFObject(id: 4, content: """
                << /Length \(stream.utf8.count) >>
                stream
                \(stream)
                endstream
                """),
            PDFObject(id: 5, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"),
        ], rootId: 1)
    }

    /// PDF with a sensitive term encoded via the PDF Name-object form
    /// (`/SSN`) instead of a literal string. The catalog's text-show
    /// operator sequence is `BT /F1 24 Tf 100 700 Td /<term> Tj ET`, which
    /// is a syntactically valid (if semantically unusual) Tj operand
    /// shape — Name objects can be passed where a string is expected and
    /// the PDF parser accepts the name's bytes as the operand. PDFKit's
    /// `page.string` and Layer 1 do not surface the Name's bytes as text;
    /// only the operator-semantic re-extraction layer (Layer 10 SVT-5,
    /// M3) walks the content stream and surfaces it via the
    /// `CGPDFStringCopyTextString` decoder. See RT-8, plan §4.5.
    static func withNameObjectTermInjection(term: String) -> Data {
        let stream = "BT /F1 24 Tf 100 700 Td /\(term) Tj ET"
        return buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [0 0 612 792] \
                /Contents 4 0 R \
                /Resources << /Font << /F1 5 0 R >> >> >>
                """),
            PDFObject(id: 4, content: """
                << /Length \(stream.utf8.count) >>
                stream
                \(stream)
                endstream
                """),
            PDFObject(id: 5, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"),
        ], rootId: 1)
    }

    /// PDF with a sensitive term encoded via PDF octal escape sequences in
    /// a text-show literal string. Raw bytes show the `\NNN\NNN…` escape
    /// form; PDFKit decodes them to the original characters when serving
    /// `page.string`. The SVT-3 tightening surfaces the decoded term where
    /// the raw-byte scan misses both the term (encoded form) and the
    /// stream-data range (excluded).
    /// See RT-7 (octal-escape variant), plan §4.1.
    static func withOctalEscapedSensitiveTerm(term: String) -> Data {
        let encoded = term.utf8
            .map { String(format: "\\%03o", $0) }
            .joined()
        let stream = "BT /F1 24 Tf 100 700 Td (\(encoded)) Tj ET"
        return buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [0 0 612 792] \
                /Contents 4 0 R \
                /Resources << /Font << /F1 5 0 R >> >> >>
                """),
            PDFObject(id: 4, content: """
                << /Length \(stream.utf8.count) >>
                stream
                \(stream)
                endstream
                """),
            PDFObject(id: 5, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"),
        ], rootId: 1)
    }

    /// Render a known character sequence as a real Courier text layer using
    /// `UIGraphicsPDFRenderer`, returning the resulting PDF data. Used by
    /// Layer 9 lineage tests as the "output" side — the test computes the
    /// matching filter-side `lineageHash` independently and asserts the
    /// verifier reports match or mismatch.
    static func courierTextLayerPDF(
        text: String, fontSize: CGFloat = 24
    ) -> Data {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let font = UIFont(name: "Courier", size: fontSize)
            ?? UIFont.systemFont(ofSize: fontSize)
        return renderer.pdfData { context in
            context.beginPage()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.black,
            ]
            (text as NSString).draw(
                at: CGPoint(x: 72, y: 72),
                withAttributes: attrs
            )
        }
    }

    /// Multi-line text PDF for Layer 9 round-trip tests. Each entry is drawn
    /// at its own baseline so `groupIntoRuns` produces one run per line.
    /// Default font is Courier (source-output font alignment) but caller can
    /// override to exercise the non-Courier source path.
    static func multiLineTextLayerPDF(
        lines: [String],
        fontName: String = "Courier",
        fontSize: CGFloat = 12,
        lineSpacing: CGFloat = 48,
        startY: CGFloat = 72
    ) -> Data {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let font = UIFont(name: fontName, size: fontSize)
            ?? UIFont.systemFont(ofSize: fontSize)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.black,
        ]
        return renderer.pdfData { context in
            context.beginPage()
            for (index, line) in lines.enumerated() {
                let y = startY + CGFloat(index) * lineSpacing
                (line as NSString).draw(
                    at: CGPoint(x: 72, y: y),
                    withAttributes: attrs
                )
            }
        }
    }

    /// Layer 9 round-trip fixture: descender-heavy text in Courier. The
    /// `gpqy j` glyphs report `bounds.minY` ~2.5pt below same-line ascenders
    /// — the H1 surface where the pre-redesign hash used a single
    /// `snappedRunY` per run on the filter side but per-character snapped Y
    /// on the verifier side.
    static func descenderHeavyTextLayerPDF() -> Data {
        multiLineTextLayerPDF(lines: [
            "happy puppy goes jogging",
            "funky gypsy quietly snoring",
            "gloomy pog jumps lazily",
        ])
    }

    /// Layer 9 round-trip fixture: descender-heavy text in Helvetica.
    /// Helvetica's descent differs from Courier's, so the pre-redesign hash
    /// could land filter `snappedRunY` and verifier per-character `snappedY`
    /// in different cells. The new globalPos hash domain drops position
    /// entirely and the round-trip agrees regardless of font metrics.
    static func nonCourierSourceTextLayerPDF() -> Data {
        multiLineTextLayerPDF(lines: [
            "happy puppy goes jogging quietly",
        ], fontName: "Helvetica")
    }

    /// Layer 9 round-trip fixture: three paragraphs separated by blank space.
    /// `groupIntoRuns` produces three runs. PDFKit's `outputPage.string` may
    /// synthesize inter-run whitespace; the test exercises whether such
    /// synthesized characters are reported with non-zero bounds (which would
    /// have flipped the pre-redesign hash via N2).
    static func multiParagraphTextLayerPDF() -> Data {
        multiLineTextLayerPDF(lines: [
            "First paragraph of text",
            "",
            "Second paragraph of text",
            "",
            "Third paragraph of text",
        ])
    }

    /// Layer 9 round-trip fixture: text with a regional-indicator pair
    /// (`\u{1F1FA}\u{1F1F8}` = US flag), exercising the N1 grapheme-cluster
    /// surface. Swift `Character` and NSString composed-character-sequence
    /// iteration both treat the pair as one cluster on most platforms; the
    /// new design iterates NSString composed sequences on both sides so the
    /// iteration unit is unambiguous. Courier has no glyphs for these
    /// codepoints — the test documents the actual round-trip outcome rather
    /// than assert one.
    static func composedSequenceTextLayerPDF() -> Data {
        multiLineTextLayerPDF(lines: [
            "ABC \u{1F1FA}\u{1F1F8} XYZ",
        ], fontName: "Helvetica", fontSize: 16)
    }

    /// PDF with a Courier-suffixed `/Font` dict but a TJ array carrying
    /// non-zero kerning displacements between adjacent glyphs. Simulates an
    /// attacker post-processing the reconstructor's output to inject the
    /// Bland–Iyer–Levchenko 2023 attack pattern (sub-pixel glyph-position
    /// shifts via `TJ` kerning). The M2 reconstructor itself emits only
    /// `Tj` operators (CTLineDraw default); this fixture exercises the
    /// detection surface — Layer 6 SVT-1 reports per-character bounds that
    /// deviate from the Courier monospace advance. See RT-1 and plan §4.2.
    static func withBlandKerningInjection(
        text: String = "ABCDEFGH",
        displacement: Int = -300
    ) -> Data {
        // Build a TJ array with kerning between every adjacent glyph pair:
        // [(A) -300 (B) -300 (C) -300 …] TJ
        // Negative units in TJ move text origin backward in 1/1000-em
        // space (PDF spec §9.4.3 Table 109).
        var tj = "["
        for (i, char) in text.enumerated() {
            if i > 0 { tj += " \(displacement) " }
            tj += "(\(char))"
        }
        tj += "] TJ"
        let stream = "BT /F1 12 Tf 100 700 Td \(tj) ET"
        return buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [0 0 612 792] \
                /Contents 4 0 R \
                /Resources << /Font << /F1 5 0 R >> >> >>
                """),
            PDFObject(id: 4, content: """
                << /Length \(stream.utf8.count) >>
                stream
                \(stream)
                endstream
                """),
            PDFObject(id: 5, content: """
                << /Type /Font /Subtype /Type1 /BaseFont /Courier \
                /Encoding /WinAnsiEncoding >>
                """),
        ], rootId: 1)
    }

    /// PDF with black-filled square annotations for profile detection.
    /// Simulates documents with black-square "redactions" (not real PDF redact annotations).
    /// Distinct from fakeRedaction — this tests profile classification, not attack simulation.
    static func withBlackSquareAnnotations(count: Int = 3) -> Data {
        let data = blankPage()
        guard let doc = PDFDocument(data: data),
              let page = doc.page(at: 0) else {
            fatalError("Failed to create black square fixture")
        }

        for i in 0..<count {
            let bounds = CGRect(x: 72, y: 700 - CGFloat(i * 50), width: 200, height: 30)
            let annotation = PDFAnnotation(bounds: bounds, forType: .square, withProperties: nil)
            annotation.color = .black
            annotation.interiorColor = .black
            annotation.border = PDFBorder()
            page.addAnnotation(annotation)
        }

        return doc.dataRepresentation()!
    }

    // MARK: - S01 Searchable-Redaction merge-repro fixture
    //
    // See the searchable-verify-fix plan §2 and the corresponding note.
    // Stands in for a real 23-page born-digital tax PDF (which must never
    // enter the repo, plan §9 / risk R7) so every later session can validate a fix
    // on a committed synthetic regression substrate.

    /// Synthetic born-digital fixture engineered to reproduce the
    /// Searchable-Redaction verification-failure cluster on the UNMODIFIED engine:
    /// Layer 6 (SVT-1 advance), Layer 7 (count deficit), Layer 8 (SVT-4
    /// `/ToUnicode`), and Layer 9 (SVT-2 lineage) FAIL, while Layer 10 (SVT-5)
    /// stays PASS. Built as a REAL Courier text layer via `UIGraphicsPDFRenderer`
    /// (like `multiLineTextLayerPDF`), each line on its own baseline so
    /// `groupIntoRuns` sees distinct lines.
    ///
    /// Three failure substrates (plan §2):
    ///   • **1b run-boundary merge** — table rows whose two columns are separated
    ///     by a gap that breaks the run (`groupIntoRuns`: gap ≥ 1.5×prev.width)
    ///     yet is narrow enough that the reconstructor's pinned-12pt redraw
    ///     (`cellWidth` 7.20pt) overruns the next run's grid-snapped origin →
    ///     boundary glyphs co-locate → PDFKit composed re-extraction merges them
    ///     → output composed count < surviving (Layer 7) and the composed
    ///     sequence diverges (Layer 9). At `sourceFontSize` 9pt the source
    ///     advance is 0.60009765625×9 ≈ 5.40pt, so the redraw drifts
    ///     (7.20−5.40)=1.80pt per glyph and overruns a ~2-space gap after ~6
    ///     glyphs — the `letter −54` mechanism the plan infers is dominant.
    ///   • **1a combining marks** — NFD-decomposed graphemes (base + U+03xx
    ///     combining mark) that CoreText lays out with a ~0-advance combining
    ///     glyph; on re-extraction this can surface as a near-zero positive-width
    ///     composed char that trips the SVT-1 advance crosscheck (Layer 6, plan
    ///     §3.5 case (b)). They also force fallback substitution (below).
    ///   • **2 Courier-uncovered codepoints** — glyphs the embedded Courier subset
    ///     lacks, so CoreText substitutes a fallback subset that CGPDFContext
    ///     emits WITH a `/ToUnicode` CMap (Layer 8 SVT-4). EXP-E5.1's "no
    ///     `/ToUnicode`" attestation holds only for the primary subset.
    ///
    /// ARCH §12.2: synthetic tokens only — contains no real PII. The redaction
    /// box for this fixture belongs in the empty bottom margin (away from the
    /// text), so it filters ≈0 characters — matching the real-doc run where the
    /// failures are reconstruction-fidelity artifacts, redaction-independent.
    ///
    /// - Parameters:
    ///   - sourceFontSize: source Courier point size (< the reconstructor's
    ///     pinned 12pt). Smaller widens the redraw overrun.
    ///   - rightX: x-origin of each row's right column (the left column starts
    ///     at 72). Controls the inter-column gap that `groupIntoRuns` must split.
    static func searchableMergeReproPDF(
        sourceFontSize: CGFloat = 7, rightX: CGFloat = 140
    ) -> Data {
        // Built with CGPDFContext + CTLineDraw (the same writer a born-digital
        // PDF and the reconstructor itself use), NOT UIGraphicsPDFRenderer's
        // `NSString.draw(at:)`. With `NSString.draw`, PDFKit synthesizes a
        // *selectable* (non-zero-bounds) space to bridge a positioned column
        // gap, which survives extraction and keeps the row in one run — no
        // boundary merge. CTLineDraw-positioned columns reproduce the
        // born-digital gap shape, where the gap carries no surviving glyph, so
        // `groupIntoRuns` actually splits the row.
        //
        // 1b run-boundary merge: each row's two columns are positioned with a
        // real coordinate gap and NO space characters. At 7pt the source
        // advance is 0.60009765625×7 ≈ 4.20pt; the left column (13 glyphs)
        // spans ≈[72, 126.6] and the gap to `rightX` (140) is ≈13.4pt >
        // 1.5×4.20 ≈ 6.3pt, so the row splits into two runs. The reconstructor
        // redraws the left run at 12pt (7.20pt/cell) over ≈[72, 165.6] while the
        // right run snaps to floor(140/7.20)×7.20 = 136.8, so the runs overlap
        // by ≈4 cells → boundary glyphs co-locate → PDFKit composed
        // re-extraction merges them (output composed < surviving → Layer 7; the
        // composed sequence diverges → Layer 9).
        let rows: [(left: String, right: String)] = [
            ("ACCOUNTNUMBER", "1234567"),
            ("BALANCEAMOUNT", "9988776"),
            ("PENDINGCHARGE", "4567890"),
            ("CREDITENTRIES", "1029384"),
            ("DEBITRECORDED", "5647382"),
            ("TRANSFERSENT", "8675309"),
        ]
        let leftX: CGFloat = 72
        // 1a + substrate 2: codepoints the embedded Courier subset does not
        // cover (accented + math + box-drawing). CoreText substitutes a
        // fallback subset both in the source render and, decisively, in the
        // reconstructor's 12pt redraw, where CGPDFContext emits the substituted
        // subset WITH a /ToUnicode CMap (Layer 8 SVT-4). These also seed the
        // off-grid advance glyphs Layer 6 SVT-1 reports.
        let fallbackLines = [
            "caf\u{00E9} \u{00E0} pi\u{00F1}ata b\u{00FC}ro",
            "na\u{00EF}ve r\u{00E9}sum\u{00E9} \u{00F4}t\u{00E9}",
            "SUM \u{2211} APX \u{2248} DEL \u{2206} \u{2500}\u{2502}\u{2588}",
        ]

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mergerepro_\(UUID().uuidString).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            return Data()
        }
        let font = CTFontCreateWithName("Courier" as CFString, sourceFontSize, nil)
        func draw(_ s: String, _ x: CGFloat, _ y: CGFloat) {
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font
            ]
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: s, attributes: attrs)
            )
            ctx.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, ctx)
        }
        ctx.beginPDFPage(nil)
        // CGPDFContext is bottom-left origin: start high, step downward.
        var y: CGFloat = 720
        for row in rows {
            draw(row.left, leftX, y)
            draw(row.right, rightX, y)
            y -= 16
        }
        y -= 8
        for line in fallbackLines {
            draw(line, leftX, y)
            y -= 16
        }
        ctx.endPDFPage()
        ctx.closePDF()
        defer { try? FileManager.default.removeItem(at: url) }
        return (try? Data(contentsOf: url)) ?? Data()
    }

    /// Redaction region for `searchableMergeReproPDF`: a small box in the empty
    /// bottom margin (normalized, bottom-left origin) so it filters ≈0 source
    /// characters while still giving the page a region so Layer 6 SVT-1 engages
    /// (verifySpatialExclusion short-circuits to `.pass` when a page has no
    /// region). Returned as a `[Int: [RedactionRegion]]` keyed to page 0.
    static func searchableMergeReproRegions() -> [Int: [RedactionRegion]] {
        [0: [RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.05, y: 0.03, width: 0.25, height: 0.05),
            source: .manual
        )]]
    }

    /// VQ-22: structural bytes carrying the letters "stream" inside a Name
    /// token (`/Downstream`) AHEAD of a sensitive term in structural data,
    /// plus a real (keyword-EOL-correct) content stream after both. Before
    /// the EOL gate, the "stream" inside "Downstream" opened a phantom
    /// stream range reaching the real stream's `endstream`, swallowing the
    /// term-bearing object — Layer 3's structural pass then reported
    /// nothing. With the gate, only the real stream is excluded and the
    /// structural term FAILs as a complete token.
    static func downstreamPhantomRange(term: String) -> Data {
        buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            // Byte order matters: the /Downstream token (obj 3) precedes the
            // term (obj 4), which precedes the only real stream (obj 5).
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [0 0 612 792] \
                /Contents 5 0 R /Resources << >> \
                /PieceInfo << /Marker /Downstream >> >>
                """),
            PDFObject(id: 4, content: "<< /Note /\(term) >>"),
            PDFObject(id: 5, content: "<< /Length 0 >>\nstream\n\nendstream"),
        ], rootId: 1)
    }

    /// VQ-22 fallback pin: the document's ONLY `stream` keyword is malformed
    /// (followed by a bare CR — not the CR LF / LF that ISO 32000-2 §7.3.8
    /// requires), and a sensitive term sits inside that stream's data. The
    /// strict pass yields no ranges, so the permissive fallback must engage
    /// and still exclude the stream data — the term must NOT surface as a
    /// structural FAIL (pre-gate behavior preserved for malformed writers).
    static func malformedStreamKeywordEOL(term: String) -> Data {
        buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R \
                /MediaBox [0 0 612 792] \
                /Contents 4 0 R /Resources << >> >>
                """),
            PDFObject(id: 4, content: "<< /Length \(term.utf8.count) >>\nstream\r\(term)\rendstream"),
        ], rootId: 1)
    }

    /// Two blank pages sharing one empty content stream. Base document for
    /// the VQ-23 unopenable-page tests (see `UnopenablePageDocument` in
    /// VerificationEngineTests — PDFKit synthesizes a PDFPage even for a
    /// broken /Kids entry, so the unopenable condition is modeled by an
    /// override, not by fixture bytes).
    static func twoBlankPages() -> Data {
        let pageBody = """
            << /Type /Page /Parent 2 0 R \
            /MediaBox [0 0 612 792] \
            /Contents 5 0 R /Resources << >> >>
            """
        return buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>"),
            PDFObject(id: 3, content: pageBody),
            PDFObject(id: 4, content: pageBody),
            PDFObject(id: 5, content: "<< /Length 0 >>\nstream\n\nendstream"),
        ], rootId: 1)
    }

    /// Solid mid-gray JPEG of the given pixel size (no text, no metadata).
    /// VQ-32: source data for the Layer-2 decode-cap pin — large enough that
    /// an uncapped decode would exceed `ocrMaxPixelDimension`.
    static func solidJPEG(width: Int, height: Int) -> Data {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { fatalError("Failed to create solid JPEG context") }
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage() else {
            fatalError("Failed to render solid JPEG image")
        }
        let jpegData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            jpegData, "public.jpeg" as CFString, 1, nil
        ) else { fatalError("Failed to create image destination") }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return jpegData as Data
    }
}

