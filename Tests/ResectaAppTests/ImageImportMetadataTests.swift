import Testing
import Foundation
import CoreGraphics
import ImageIO
import PDFKit
@testable import ResectaApp
@testable import RedactionEngine

// Pixels only: nothing the source carried beside its pixels — GPS, EXIF
// beyond a DCT stream's technical trio, XMP, maker notes, PNG text, the
// ICC description, an embedded thumbnail, an auxiliary image — reaches the
// imported page or the exported file. The fixtures prove they carry the
// probes before the absence is asserted.

@Suite("Image import: metadata", .tags(.importFlow))
struct ImageImportMetadataTests {

    static let encoderInjectedExifKeys: Set<String> = [
        kCGImagePropertyExifColorSpace as String,
        kCGImagePropertyExifPixelXDimension as String,
        kCGImagePropertyExifPixelYDimension as String,
    ]
    static let byteProbes = ["xmpmeta", "MakerApple", "tEXt", "FixtureMake", "FixtureModel", ImageFixtures.canary, "GPSLatitude"]

    static func properties(_ data: Data) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    /// The undecoded bytes of every DCTDecode image stream in a PDF.
    static func jpegStreams(_ data: Data) throws -> [Data] {
        let doc = try #require(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        var streams: [Data] = []
        for n in 1...max(1, doc.numberOfPages) {
            guard let page = doc.page(at: n), let dict = page.dictionary else { continue }
            var resources: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let resources else { continue }
            var xobjects: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { continue }
            nonisolated final class Box: @unchecked Sendable { var items: [Data] = [] }
            let box = Box()
            CGPDFDictionaryApplyBlock(xobjects, { _, value, info in
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(value, .stream, &stream), let stream else { return true }
                var format = CGPDFDataFormat.raw
                if let d = CGPDFStreamCopyData(stream, &format), format == .jpegEncoded {
                    Unmanaged<Box>.fromOpaque(info!).takeUnretainedValue().items.append(d as Data)
                }
                return true
            }, Unmanaged.passUnretained(box).toOpaque())
            streams.append(contentsOf: box.items)
        }
        return streams
    }

    static func contains(_ data: Data, _ probe: String) -> Bool {
        data.range(of: Data(probe.utf8)) != nil
    }

    /// The source HEIC with GPS, the canary and a depth auxiliary image:
    /// built here where the runtime encodes HEIC, else the committed copy.
    static func heicFixture() throws -> Data {
        if let built = ImageFixtures.heicWithProbesAndDepth() { return built }
        let url = try #require(Bundle(for: ImageFixtureBundleToken.self)
            .url(forResource: "probe-gps-depth", withExtension: "heic"))
        return try Data(contentsOf: url)
    }

    static func assertClean(_ pdf: Data, label: String) throws {
        for probe in byteProbes {
            #expect(!contains(pdf, probe), "\(label): '\(probe)' in the bytes")
        }
        let streams = try jpegStreams(pdf)
        #expect(!streams.isEmpty, "\(label): a DCT page image to inspect")
        for stream in streams {
            let props = try properties(stream)
            #expect(props[kCGImagePropertyGPSDictionary] == nil, "\(label): a GPS dictionary")
            #expect(props[kCGImagePropertyTIFFDictionary].flatMap { ($0 as? [CFString: Any])?[kCGImagePropertyTIFFMake] } == nil, "\(label): a TIFF make")
            #expect(props[kCGImagePropertyMakerAppleDictionary] == nil, "\(label): a maker note")
            if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                let keys = Set(exif.keys.map { $0 as String })
                #expect(keys.subtracting(encoderInjectedExifKeys).isEmpty, "\(label): Exif keys \(keys.sorted())")
            }
            let source = try #require(CGImageSourceCreateWithData(stream as CFData, nil))
            #expect(CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeDisparity) == nil, "\(label): a disparity image")
        }
    }

    // MARK: - Fixture honesty

    @Test("The JPEG fixture carries GPS, the canary and a make; the HEIC fixture carries GPS and a depth image")
    func fixturesCarryTheProbes() throws {
        let jpeg = try Self.properties(ImageFixtures.jpegWithProbes())
        #expect(jpeg[kCGImagePropertyGPSDictionary] != nil)
        #expect((jpeg[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment] as? String == ImageFixtures.canary)
        #expect((jpeg[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] as? String == "FixtureMake")

        let heicData = try Self.heicFixture()
        let heic = try Self.properties(heicData)
        #expect(heic[kCGImagePropertyGPSDictionary] != nil)
        let source = try #require(CGImageSourceCreateWithData(heicData as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.heic")
        #expect(CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeDisparity) != nil,
                "the HEIC fixture carries a disparity auxiliary image")
    }

    // MARK: - The imported page

    @Test("The imported page carries none of the JPEG's probes")
    func jpegProbesAreAbsentFromThePage() async throws {
        let loaded = try await ImageImportLoaderTests.load(ImageFixtures.jpegWithProbes())
        let pdf = try #require(loaded.document.document.dataRepresentation())
        try Self.assertClean(pdf, label: "JPEG page")
    }

    @Test("The imported page carries none of the HEIC's probes or its depth image")
    func heicProbesAreAbsentFromThePage() async throws {
        let loaded = try await ImageImportLoaderTests.load(try Self.heicFixture())
        let pdf = try #require(loaded.document.document.dataRepresentation())
        try Self.assertClean(pdf, label: "HEIC page")
    }

    @Test("A stale embedded thumbnail never reaches the page: the page shows the primary image")
    func staleThumbnailIsIgnored() async throws {
        let data = ImageFixtures.staleThumbnailJPEG()
        // Honesty: the file carries a second JPEG — the embedded thumbnail —
        // whose own bytes show the marker, while the primary does not.
        let bytes = [UInt8](data)
        var secondSOI: Int? = nil
        var i = 2
        while i + 1 < bytes.count { if bytes[i] == 0xFF, bytes[i + 1] == 0xD8 { secondSOI = i; break }; i += 1 }
        let start = try #require(secondSOI, "the stale-thumbnail fixture carries an embedded JPEG")
        var end = start + 2
        while end + 1 < bytes.count, !(bytes[end] == 0xFF && bytes[end + 1] == 0xD9) { end += 1 }
        let thumbData = Data(bytes[start...min(end + 1, bytes.count - 1)])
        let thumbSource = try #require(CGImageSourceCreateWithData(thumbData as CFData, nil))
        let thumb = try #require(CGImageSourceCreateImageAtIndex(thumbSource, 0, nil))
        let tctx = CGContext(data: nil, width: thumb.width, height: thumb.height, bitsPerComponent: 8, bytesPerRow: thumb.width * 4,
                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        tctx.draw(thumb, in: CGRect(x: 0, y: 0, width: thumb.width, height: thumb.height))
        #expect(ImageFixtures.isRed(ImageFixtures.samples(in: tctx)["topLeft"]!), "the embedded thumbnail (\(thumb.width)×\(thumb.height)) shows the marker")
        let primarySource = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let primary = try #require(CGImageSourceCreateImageAtIndex(primarySource, 0, nil))
        #expect(primary.width == 400, "the primary is the full-size white image")

        let loaded = try await ImageImportLoaderTests.load(data)
        let page = try ImageImportLoaderTests.page(loaded)
        #expect(ImageFixtures.redPixelCount(of: page) == 0, "the page is the primary image, not the thumbnail")
    }

    // MARK: - The exported file

    @Test("The Secure export of an imported photo carries no source probe and only the technical Exif trio")
    func exportCarriesNoSourceProbe() async throws {
        let loaded = try await ImageImportLoaderTests.load(ImageFixtures.jpegWithProbes())
        let page = try #require(loaded.document.document.page(at: 0))
        let region = RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.2, y: 0.4, width: 0.6, height: 0.2), source: .manual)
        let pageData = PDFPageData(
            page: page, pageIndex: 0, regions: [region], fillColor: .black, targetDPI: 150,
            pipelineMode: .secureRasterization, rotation: 0,
            cropBoxBounds: page.bounds(for: .cropBox), cgPage: page.pageRef, hasText: false)
        let result = try await PageRasterizer().rasterize(pageData)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("recon_imageprobe_\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let recon = PDFStreamReconstructor(tempURL: tempURL)
        try await recon.begin(firstPageSize: result.pageOutput.size)
        try await recon.appendPage(result.pageOutput)
        await recon.finalize()
        try Self.assertClean(try Data(contentsOf: tempURL), label: "export")
    }
}
