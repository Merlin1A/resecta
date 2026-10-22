import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import Testing
@testable import RedactionEngine

// The robustness runner's import mirror, widened to the image route: the
// app's byte sniff and its image loader restated stage by stage, in the
// app's order, with the app's refusal classes, so the host campaign reaches
// the image refusals the app does. The app-side parity pin holds the two
// stage lists equal (`ImportMirrorParityTests`). The mirror declares no app
// type; the page it builds is the loader's shape (one DCT image per page at
// 300 pixels per inch) so the redact and verify legs run on it.

extension RobustnessRunnerTests {

    // MARK: - The route (ImportRouter.route)

    /// The sniff the app's router makes on the first twelve bytes: `%PDF`
    /// and unknown payloads take the PDF mirror; JPEG, PNG and the HEIC
    /// family take the image mirror; every other image signature is
    /// refused before any decode.
    static func importRouteMirror(_ data: Data, password: String? = nil) -> ImportMirrorResult {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x25, 0x50, 0x44, 0x46]) { return importMirror(data, password: password) }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) || bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return imageImportMirror(data)
        }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) || bytes.starts(with: [0x49, 0x49, 0x2A, 0x00])
            || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) || bytes.starts(with: [0x42, 0x4D]) {
            return .reject(errorClass: "unsupportedFormat")
        }
        if bytes.count >= 12, bytes.starts(with: [0x52, 0x49, 0x46, 0x46]),
           bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 {
            return .reject(errorClass: "unsupportedFormat")
        }
        if bytes.count >= 12, bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
            let brand = String(decoding: bytes[8..<12], as: UTF8.self)
            if ["heic", "heix", "hevc", "hevx", "mif1", "msf1", "heim", "heis", "hevm", "hevs"].contains(brand) {
                return imageImportMirror(data)
            }
            if ["avif", "avis"].contains(brand) { return .reject(errorClass: "unsupportedFormat") }
        }
        return importMirror(data, password: password)
    }

    // MARK: - The image stages (ImageImportLoader.pageImage · redraw · encodePageImage)

    static let imageMirrorAcceptedTypes: Set<String> = ["public.jpeg", "public.png", "public.heic", "public.heif"]

    /// One image's stages in the app's order, to the page image; the page
    /// is then built in the loader's shape. Caps as the app's
    /// `ImportLimits.standard`.
    static func imageImportMirror(_ data: Data) -> ImportMirrorResult {
        switch imagePageMirror(data) {
        case .failure(let refusal): return .reject(errorClass: refusal.errorClass)
        case .success(let page): return imagePageDocument(page)
        }
    }

    struct MirrorPageImage {
        let image: CGImage
        let mediaBox: CGRect
    }

    struct ImageMirrorRefusal: Error {
        let errorClass: String
        init(_ errorClass: String) { self.errorClass = errorClass }
    }

    static func imagePageMirror(_ data: Data) -> Result<MirrorPageImage, ImageMirrorRefusal> {
        let maxBytes = 50 * 1024 * 1024, maxDeclared = 100_000_000, minSide = 42
        let maxDecoded = 25_000_000, maxSide = 8_000
        guard data.count <= maxBytes else { return .failure(ImageMirrorRefusal("tooLarge")) }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return .failure(ImageMirrorRefusal("unsupportedFormat"))
        }
        guard let type = CGImageSourceGetType(source) as String?, imageMirrorAcceptedTypes.contains(type) else {
            return .failure(ImageMirrorRefusal("unsupportedFormat"))
        }
        guard CGImageSourceGetStatus(source) == .statusComplete, imageHasEndMarker(data, type: type) else {
            return .failure(ImageMirrorRefusal("corrupt"))
        }
        let primary: Int
        if type == "public.heic" || type == "public.heif" {
            primary = CGImageSourceGetPrimaryImageIndex(source)
        } else {
            guard CGImageSourceGetCount(source) == 1 else { return .failure(ImageMirrorRefusal("unsupportedFormat")) }
            primary = 0
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, primary, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return .failure(ImageMirrorRefusal("corrupt"))
        }
        guard width > 0, height > 0, width * height <= maxDeclared, min(width, height) >= minSide else {
            return .failure(ImageMirrorRefusal("invalidPageDimensions"))
        }
        let longSide = max(width, height)
        let budgeted = Int((Double(longSide) * (Double(maxDecoded) / Double(width * height)).squareRoot()).rounded(.down))
        let target = min(longSide, maxSide, budgeted)
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: target,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, primary, thumbnailOptions as CFDictionary) else {
            return .failure(ImageMirrorRefusal("corrupt"))
        }
        // The redraw: the pixels-only boundary.
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let redraw = CGContext(data: nil, width: decoded.width, height: decoded.height, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return .failure(ImageMirrorRefusal("corrupt"))
        }
        let bounds = CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height)
        redraw.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        redraw.fill(bounds)
        redraw.interpolationQuality = .high
        redraw.draw(decoded, in: bounds)
        guard let pixels = redraw.makeImage() else { return .failure(ImageMirrorRefusal("corrupt")) }
        // The page image: a fresh JPEG at 0.92, passed through as a DCT stream.
        let jpeg = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil) else {
            return .failure(ImageMirrorRefusal("corrupt"))
        }
        CGImageDestinationAddImage(destination, pixels, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination),
              let provider = CGDataProvider(data: jpeg as CFData),
              let pageImage = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            return .failure(ImageMirrorRefusal("corrupt"))
        }
        // The page box: px × 72/300 pt; no rotation entry, no auxiliary information.
        let mediaBox = CGRect(x: 0, y: 0, width: CGFloat(pixels.width) * 72 / 300, height: CGFloat(pixels.height) * 72 / 300)
        return .success(MirrorPageImage(image: pageImage, mediaBox: mediaBox))
    }

    // MARK: - The page (ImageImportLoader.load)

    /// One page in the loader's shape: the image over its box, the
    /// document's default box the same.
    static func imagePageDocument(_ page: MirrorPageImage) -> ImportMirrorResult {
        let pdfData = NSMutableData()
        var box = page.mediaBox
        guard let consumer = CGDataConsumer(data: pdfData),
              let context = CGContext(consumer: consumer, mediaBox: &box, [:] as CFDictionary) else {
            return .reject(errorClass: "corrupt")
        }
        let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
        context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
        context.draw(page.image, in: page.mediaBox)
        context.endPDFPage()
        context.closePDF()
        guard let document = PDFDocument(data: pdfData as Data), document.pageCount == 1 else {
            return .reject(errorClass: "corrupt")
        }
        return .open(document, textLayerStatus: [0: TextLayerStatus.none], hasHiddenOCG: false)
    }


    /// The container's end marker, as the app's loader reads it.
    static func imageHasEndMarker(_ data: Data, type: String) -> Bool {
        switch type {
        case "public.jpeg":
            guard let scan = data.range(of: Data([0xFF, 0xDA])) else { return false }
            return data.range(of: Data([0xFF, 0xD9]), in: scan.upperBound..<data.endIndex) != nil
        case "public.png":
            let iend = Data([0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])
            return data.count >= iend.count && data.suffix(iend.count) == iend
        default:
            return true
        }
    }

    // MARK: - Image fixtures for the runner (built in memory)

    /// A white JPEG or PNG of the given size through Image I/O.
    static func imageFixture(width: Int, height: Int, type: String) -> Data {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, type as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    /// A PNG whose header declares the given size over a tiny image stream.
    static func pngDeclaringFixture(width: UInt32, height: UInt32) -> Data {
        func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
        func crc(_ d: Data) -> UInt32 {
            var c: UInt32 = 0xFFFFFFFF
            for b in d { c ^= UInt32(b); for _ in 0..<8 { c = (c >> 1) ^ (0xEDB88320 & (0 &- (c & 1))) } }
            return ~c
        }
        func chunk(_ type: String, _ body: Data) -> Data {
            var c = Data(be(UInt32(body.count))); var payload = Data(type.utf8); payload.append(body)
            c.append(payload); c.append(contentsOf: be(crc(payload))); return c
        }
        var d = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var ihdr = Data(be(width)); ihdr.append(contentsOf: be(height)); ihdr.append(contentsOf: [8, 2, 0, 0, 0])
        d.append(chunk("IHDR", ihdr))
        d.append(chunk("IDAT", Data([0x78, 0x9C, 0x63, 0x60, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01])))
        d.append(chunk("IEND", Data()))
        return d
    }

    /// A minimal WebP container (a 1 × 1 VP8L bitstream).
    static func webpFixture() -> Data {
        let vp8l: [UInt8] = [0x2F, 0x00, 0x00, 0x00, 0x00, 0x07, 0x10, 0x11, 0x11, 0x88, 0x88, 0xFE, 0x07, 0x00]
        func le(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }
        var chunk = Data("VP8L".utf8); chunk.append(contentsOf: le(UInt32(vp8l.count))); chunk.append(contentsOf: vp8l)
        var d = Data("RIFF".utf8); d.append(contentsOf: le(UInt32(4 + chunk.count))); d.append(Data("WEBP".utf8)); d.append(chunk)
        return d
    }

    /// The image rows of the fixture table.
    static func imageFixtures() -> [Fixture] {
        func exp(_ imp: String, _ impErr: String?, _ red: String) -> Expected {
            Expected(importOutcome: imp, importError: impErr, redact: red, redactError: nil)
        }
        let jpeg = imageFixture(width: 400, height: 300, type: "public.jpeg")
        return [
            Fixture(id: "image-jpeg", source: "factory", data: jpeg, path: nil,
                    expected: exp("open", nil, "open"), notes: "a JPEG becomes one page drawn from its pixels"),
            Fixture(id: "image-png", source: "factory", data: imageFixture(width: 300, height: 400, type: "public.png"), path: nil,
                    expected: exp("open", nil, "open"), notes: "a PNG becomes one page"),
            Fixture(id: "image-jpeg-gps", source: "factory", data: TestFixtures.jpegWithGPS(), path: nil,
                    expected: exp("open", nil, "open"), notes: "a GPS-bearing JPEG opens; the page carries pixels only"),
            Fixture(id: "image-truncated-jpeg", source: "factory", data: jpeg.prefix(jpeg.count * 6 / 10), path: nil,
                    expected: exp("reject", "corrupt", "skip"), notes: "a JPEG cut before its end"),
            Fixture(id: "image-webp", source: "factory", data: webpFixture(), path: nil,
                    expected: exp("reject", "unsupportedFormat", "skip"), notes: "WebP is refused at the route"),
            Fixture(id: "image-gif-header", source: "factory", data: Data("GIF89a".utf8) + Data(count: 32), path: nil,
                    expected: exp("reject", "unsupportedFormat", "skip"), notes: "GIF is refused at the route"),
            Fixture(id: "image-huge-ihdr", source: "factory", data: pngDeclaringFixture(width: 30_000, height: 30_000), path: nil,
                    expected: exp("reject", "corrupt", "skip"),
                    notes: "a 900 MP declaration: Image I/O reports no size above 100 MP, so the size read refuses it unread, before any decode"),
            Fixture(id: "image-tiny", source: "factory", data: imageFixture(width: 20, height: 20, type: "public.jpeg"), path: nil,
                    expected: exp("reject", "invalidPageDimensions", "skip"), notes: "under the 42 px floor"),
        ]
    }
}

@Suite("Import mirror: the image route")
struct ImportMirrorImageRouteTests {

    private func refusal(_ data: Data) -> String {
        switch RobustnessRunnerTests.importRouteMirror(data) {
        case .reject(let errorClass): return errorClass
        case .open: return "open"
        }
    }

    @Test("The image fixtures take the route the table expects")
    func imageFixturesRoute() {
        for fixture in RobustnessRunnerTests.imageFixtures() {
            let got = refusal(fixture.data!)
            let want = fixture.expected.importOutcome == "open" ? "open" : fixture.expected.importError!
            #expect(got == want, "\(fixture.id): \(got) vs \(want)")
        }
    }

    @Test("An opened image is one page of px × 72/300 pt with no rotation")
    func openedImageIsOnePage() throws {
        guard case .open(let doc, let status, let hidden) = RobustnessRunnerTests.importRouteMirror(
            RobustnessRunnerTests.imageFixture(width: 400, height: 300, type: "public.jpeg")) else {
            Issue.record("the JPEG did not open"); return
        }
        #expect(doc.pageCount == 1)
        let page = try #require(doc.page(at: 0))
        #expect(abs(page.bounds(for: .mediaBox).width - 96) < 0.01)
        #expect(page.rotation == 0)
        #expect(status == [0: TextLayerStatus.none])
        #expect(hidden == false)
    }

    @Test("PDF bytes still take the PDF mirror")
    func pdfBytesTakeThePDFMirror() {
        #expect(refusal(TestFixtures.blankPage()) == "open")
        #expect(refusal(Data()) == "corrupt")
    }
}
