import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import RedactionEngine

// Files for the box check's reading of what a page draws. Two kinds: exports
// made by the app's own pipeline (each page rasterised by PageRasterizer and
// written by PDFStreamReconstructor), which must all be admitted; and one-page
// files written byte by byte in the writer's form, then changed by one key,
// one operator or one segment, which must each be refused by name.

enum PageDrawingFixtures {

    // MARK: Exports through the app's pipeline

    /// A source page: typed lines, or a scanned picture in colour or grey.
    enum Source: Sendable {
        case text(CGSize, [String])
        case scan(CGSize, gray: Bool)
    }

    static let letter = CGSize(width: 612, height: 792), a4 = CGSize(width: 595.28, height: 841.89)
    static let wide = CGSize(width: 792, height: 612)
    /// The last line is kept, below the box, and holds the words the file check counts, so an
    /// export that carries them in its text is shown to be admitted.
    static let typed = ["Jane Roe, 12 Main Street", "Account 4417 1234 5678 9113", "Phone 555 0100",
                        "Read the trailer, startxref and %%EOF"]
    /// Lines the hidden text layer writes, refuses or splits by face.
    static let mixed = ["office affine fine flow", "東京都 新宿区 テスト 한국어", "Zoë Ångström naïve café", "call me 😀 ✅ ☎︎", "עברית العربية"]

    static func scanPicture(_ size: CGSize, gray: Bool) -> CGImage {
        let width = Int(size.width * 2), height = Int(size.height * 2)
        let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(gray: 0.95, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(gray: 0.1, alpha: 1)
        for row in stride(from: 40, to: height - 40, by: 30) { ctx.fill(CGRect(x: 40, y: row, width: width - 80, height: 12)) }
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        precondition(CGImageDestinationFinalize(dest))
        return CGImage(jpegDataProviderSource: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }

    static func sourcePDF(_ pages: [Source]) -> Data {
        let data = NSMutableData()
        var first = CGRect(origin: .zero, size: letter)
        let ctx = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &first, nil)!
        for page in pages {
            switch page {
            case .text(let size, let lines):
                var box = CGRect(origin: .zero, size: size)
                ctx.beginPage(mediaBox: &box)
                let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
                for (k, line) in lines.enumerated() {
                    let ct = CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: [.init(kCTFontAttributeName as String): font]))
                    ctx.textPosition = CGPoint(x: 72, y: size.height - 100 - CGFloat(k) * 30)
                    CTLineDraw(ct, ctx)
                }
                ctx.endPage()
            case .scan(let size, let gray):
                var box = CGRect(origin: .zero, size: size)
                ctx.beginPage(mediaBox: &box)
                ctx.draw(scanPicture(size, gray: gray), in: box)
                ctx.endPage()
            }
        }
        ctx.closePDF()
        return data as Data
    }

    /// The pipeline's export of `pages`: one box on each, typed pages in `mode`, scans Secure.
    static func export(_ pages: [Source], mode: PipelineMode, dpi: Int, fill: FillColor) async throws -> Data {
        let doc = try #require(PDFDocument(data: sourcePDF(pages)))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("drawing-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = PDFStreamReconstructor(tempURL: url)
        let rasterizer = PageRasterizer()
        for i in 0..<doc.pageCount {
            let page = try #require(doc.page(at: i))
            let region = RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.1, y: 0.8, width: 0.5, height: 0.05), source: .manual)
            let hasText = !(page.string ?? "").isEmpty
            let data = PDFPageData(page: page, pageIndex: i, regions: [region], fillColor: fill, targetDPI: dpi,
                                   pipelineMode: hasText ? mode : .secureRasterization, rotation: 0,
                                   cropBoxBounds: page.bounds(for: .cropBox), cgPage: page.pageRef, hasText: hasText)
            let result = try await rasterizer.rasterize(data)
            if i == 0 { try await writer.begin(firstPageSize: result.pageOutput.size) }
            try await writer.appendPage(result.pageOutput)
        }
        await writer.finalize()
        return try Data(contentsOf: url)
    }

    // MARK: One page in the writer's form, written by hand

    /// The writer's picture: an sRGB page encoded as the writer encodes it.
    static func writersPicture(width: Int = 96, height: Int = 96) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 16, y: 16, width: 32, height: 16))
        return PageImageFixtures.encode(ctx.makeImage()!)
    }

    static let profile: Data = CGColorSpace(name: CGColorSpace.sRGB)!.copyICCData()! as Data

    /// The parts of a one-page file; each case changes one.
    struct Page {
        var picture = PageDrawingFixtures.writersPicture()
        var width = 96, height = 96
        var side = 144
        var catalog = ""
        var pageTree = ""
        var page = ""
        var resources = ""
        var pictureKeys = ""
        var colourSpace = "[/ICCBased 6 0 R]"
        var profileKeys = "/N 3 /Alternate /DeviceRGB"
        var filter = "/DCTDecode"
        var bitsPerComponent = 8
        var pictures = "/Im1 5 0 R"
        var fonts = ""
        var content = "q 144 0 0 144 0 0 cm /Im1 Do Q"
        var more: [String] = []
        var appended = ""
        var trailer = ""

        func file() -> Data {
            var objects: [Data] = []
            func text(_ s: String) -> Data { Data(s.utf8) }
            func stream(_ dict: String, _ body: Data) -> Data {
                text("<< \(dict) /Length \(body.count) >>\nstream\n") + body + text("\nendstream")
            }
            objects.append(text("<< /Type /Catalog /Pages 2 0 R \(catalog) >>"))
            objects.append(text("<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 \(side) \(side)] \(pageTree) >>"))
            let fontEntry = fonts.isEmpty ? "" : "/Font << \(fonts) >>"
            objects.append(text("<< /Type /Page /Parent 2 0 R /Resources << /ProcSet [/PDF /Text /ImageC] /XObject << \(pictures) >> \(fontEntry) \(resources) >> /Contents 4 0 R \(page) >>"))
            objects.append(stream("", text(content)))
            objects.append(stream("/Type /XObject /Subtype /Image /Width \(width) /Height \(height) /BitsPerComponent \(bitsPerComponent) /ColorSpace \(colourSpace) /Filter \(filter) /Interpolate true \(pictureKeys)", picture))
            objects.append(stream(profileKeys, PageDrawingFixtures.profile))
            for m in more { objects.append(text(m)) }
            var out = text("%PDF-1.4\n%\u{E2}\u{E3}\u{CF}\u{D3}\n")
            var offsets: [Int] = []
            for (k, o) in objects.enumerated() {
                offsets.append(out.count)
                out += text("\(k + 1) 0 obj\n") + o + text("\nendobj\n")
            }
            let xref = out.count
            out += text("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n")
            for o in offsets { out += text(String(format: "%010d 00000 n \n", o)) }
            out += text("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R \(trailer) >>\nstartxref\n\(xref)\n%%EOF\n")
            return out + text(appended)
        }
    }

    /// The page's picture with `segment` (marker, body) set in after its first segment.
    static func withSegment(_ jpeg: Data, marker: UInt8, body: [UInt8]) -> Data {
        var b = [UInt8](jpeg)
        let firstLength = Int(b[4]) << 8 | Int(b[5])
        let at = 4 + firstLength
        let length = body.count + 2
        b.insert(contentsOf: [0xFF, marker, UInt8(length >> 8), UInt8(length & 0xFF)] + body, at: at)
        return Data(b)
    }

    /// The bytes of the picture's first segment with `marker`, its marker and length left out.
    static func segmentBody(_ jpeg: Data, marker: UInt8) -> [UInt8]? {
        let b = [UInt8](jpeg)
        var i = 2
        while i + 4 <= b.count, b[i] == 0xFF, b[i + 1] != 0xDA {
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            if b[i + 1] == marker { return Array(b[(i + 4)..<(i + 2 + length)]) }
            i += 2 + length
        }
        return nil
    }

    /// The picture with its segment `marker` taken out.
    static func withoutSegment(_ jpeg: Data, marker: UInt8) -> Data {
        var b = [UInt8](jpeg)
        var i = 2
        while i + 4 <= b.count, b[i] == 0xFF, b[i + 1] != 0xDA {
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            if b[i + 1] == marker { b.removeSubrange(i..<(i + 2 + length)); return Data(b) }
            i += 2 + length
        }
        return jpeg
    }

    /// An Exif body (big-endian) whose first directory holds one entry and names a second at `next`.
    static func exif(next: UInt32) -> [UInt8] {
        let n = next.bigEndian
        return Array("Exif\0\0".utf8) + [0x4D, 0x4D, 0x00, 0x2A, 0, 0, 0, 8, 0, 1, 0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, 1, 0, 0]
            + withUnsafeBytes(of: n) { Array($0) }
    }

    static func walk(_ jpeg: Data) throws -> PageImageWalk {
        switch try JPEGEntropyWalk.walk(jpeg) {
        case .success(let w): return w
        case .failure(let r): throw PageDrawingFixtureError.walkRefused(r)
        }
    }

    enum PageDrawingFixtureError: Error { case walkRefused(PageImageRefusal) }
}
