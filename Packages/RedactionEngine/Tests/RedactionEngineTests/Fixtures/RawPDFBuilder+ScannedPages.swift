import Foundation
import CoreGraphics
import CoreText
import ImageIO

// Page fixtures for the Search Re-check's coverage check, kept beside the
// builder so the builder file itself does not grow.

extension TestFixtures {

    /// A scanned page with a header-only text layer: one JPEG (DCTDecode)
    /// image rendered from `body` at (50, 520, 300 × 150) and `header`
    /// drawn as real text at the top (fewer than ten characters, so the
    /// import classifies the page `.sparse`). The search reads such a page
    /// through OCR; a re-run that trusts the text layer reads only the
    /// header.
    static func sparseHeaderScannedPagePDF(header: String = "Hdr", body: String = "SEED") -> Data {
        let size = CGSize(width: 300, height: 150)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let image = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: Int(size.width) * 4, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue)!
        image.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        image.fill(CGRect(origin: .zero, size: size))
        image.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        image.textMatrix = .identity
        let bodyFont = CTFontCreateWithName("Helvetica" as CFString, 60, nil)
        let bodyLine = CTLineCreateWithAttributedString(NSAttributedString(
            string: body, attributes: [kCTFontAttributeName as NSAttributedString.Key: bodyFont]))
        image.textPosition = CGPoint(x: 20, y: 55)
        CTLineDraw(bodyLine, image)
        let raw = image.makeImage()!
        let jpeg = NSMutableData()
        let dest = CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, raw, nil)
        CGImageDestinationFinalize(dest)
        let provider = CGDataProvider(data: jpeg)!
        let scan = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sparse_\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        ctx.draw(scan, in: CGRect(x: 50, y: 520, width: 300, height: 150))
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.textMatrix = .identity
        let headerFont = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let headerLine = CTLineCreateWithAttributedString(NSAttributedString(
            string: header, attributes: [kCTFontAttributeName as NSAttributedString.Key: headerFont]))
        ctx.textPosition = CGPoint(x: 72, y: 740)
        CTLineDraw(headerLine, ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        defer { try? FileManager.default.removeItem(at: url) }
        return (try? Data(contentsOf: url)) ?? Data()
    }
}
