import Testing
import Foundation
import CoreGraphics
import ImageIO
import PDFKit
@testable import RedactionEngine

// q34 (QD-15 / GT §4 gap 1) — export-side EXIF/GPS regression pin.
//
// HONEST ATTRIBUTION: the export path carries no stripper. Source-image
// metadata is absent from exports because the pipeline fully re-rasters each
// page to a bare bitmap and re-encodes a FRESH JPEG (quality-only encode
// properties) before the single CGPDFContext write site — a redraw boundary,
// not a scrubbing pass. This suite converts that architecture-derived
// property into a test-pinned one: it feeds a real EXIF/GPS-bearing JPEG
// through the ACTUAL pipeline (PageRasterizer.rasterize — rasterize + fill +
// verify — then PDFStreamReconstructor) and asserts the OUTPUT's embedded
// image streams carry no GPS/Exif property dictionaries. The import side has
// its own pin (LivePhotoAuxStripperTests, CAT-153 H1); this is the export
// side, which previously had none.

@Suite("Export image metadata pin (redraw boundary)")
struct ExportImageMetadataPinTests {

    /// Runs in `.secureRasterization` mode. Both pipeline modes converge on
    /// the same rasterize→fresh-JPEG-encode→CGPDFContext writer for page
    /// images (searchable mode differs only in the text layer it adds), so
    /// one mode exercises the shared write site; secure-raster is chosen
    /// because the image-only fixture page has no text layer.
    @Test("GPS-bearing source image yields metadata-free embedded images through the real export pipeline")
    func outputEmbeddedImagesCarryNoSourceMetadata() async throws {
        // 1. Fixture honesty — the builder's JPEG itself must carry GPS, so
        // this test fails loudly if the fixture ever goes inert.
        let jpeg = TestFixtures.jpegWithGPS()
        let jpegProps = try imageProperties(jpeg)
        #expect(jpegProps[kCGImagePropertyGPSDictionary] != nil,
                "fixture JPEG must carry a GPS dictionary — builder went inert")

        // 2. Source-side demonstration of the failure mode: the GPS metadata
        // survives DCTDecode passthrough into the source PDF's image stream.
        // (This is what the output would look like if the redraw boundary
        // were ever bypassed.)
        let sourceData = TestFixtures.gpsJPEGPagePDF()
        let sourceStreams = try jpegStreams(inPDF: sourceData)
        #expect(!sourceStreams.isEmpty, "source fixture must embed a DCTDecode image")
        let sourceGPSCount = try sourceStreams.filter {
            try imageProperties($0)[kCGImagePropertyGPSDictionary] != nil
        }.count
        #expect(sourceGPSCount >= 1,
                "SOURCE embedded image must still carry GPS — otherwise the pin proves nothing")

        // 3. The real pipeline: rasterize (fill + verify inside) → reconstruct.
        let doc = try #require(PDFDocument(data: sourceData))
        let page = try #require(doc.page(at: 0))
        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.2, y: 0.4, width: 0.6, height: 0.2),
            source: .manual)
        let pageData = PDFPageData(
            page: page, pageIndex: 0, regions: [region],
            fillColor: .black, targetDPI: 150,
            pipelineMode: .secureRasterization, rotation: 0,
            cropBoxBounds: page.bounds(for: .cropBox),
            cgPage: page.pageRef,
            hasText: false)

        let rasterizer = PageRasterizer()
        let result = try await rasterizer.rasterize(pageData)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("recon_exifpin_\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let recon = PDFStreamReconstructor(tempURL: tempURL)
        try await recon.begin(firstPageSize: result.pageOutput.size)
        try await recon.appendPage(result.pageOutput)
        await recon.finalize()

        // 4. Output asserts — embedded image streams carry no SOURCE metadata.
        // CGPDFContext re-encodes every drawn image (EXP-010) and its encoder
        // injects a purely technical Exif dictionary describing the fresh
        // raster ({ColorSpace, PixelXDimension, PixelYDimension} — measured
        // 2026-07-06 on the iOS 26.5 sim; the dimensions match the OUTPUT
        // raster, not the 200×200 source JPEG, which is asserted below). So
        // the pin is: no GPS dictionary at all, and any Exif dictionary stays
        // within that encoder-injected technical set.
        let encoderInjectedExifKeys: Set<String> = [
            kCGImagePropertyExifColorSpace as String,
            kCGImagePropertyExifPixelXDimension as String,
            kCGImagePropertyExifPixelYDimension as String,
        ]
        let outputData = try Data(contentsOf: tempURL)
        let outputStreams = try jpegStreams(inPDF: outputData)
        #expect(!outputStreams.isEmpty,
                "output must embed at least one JPEG page image — otherwise nothing was checked")
        for stream in outputStreams {
            let props = try imageProperties(stream)
            #expect(props[kCGImagePropertyGPSDictionary] == nil,
                    "output embedded image carried a GPS dictionary under this fixture")
            if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                let keys = Set(exif.keys.map { $0 as String })
                #expect(keys.subtracting(encoderInjectedExifKeys).isEmpty,
                        "output Exif carried keys beyond the encoder-injected technical set: \(keys)")
                if let pixelX = exif[kCGImagePropertyExifPixelXDimension] as? Int {
                    #expect(pixelX == result.pageOutput.image.width,
                            "output Exif dimensions must describe the fresh raster, not the source image")
                }
            }
        }

        // 5. /Info stays within the Apple auto-injected set (same asserts as
        // ReconstructionTests.metadataStripped; /Producer is auto-injected by
        // CGPDFContext — known limitation, ENGINE §5.4).
        let pdfString = String(data: outputData, encoding: .ascii) ?? ""
        #expect(!pdfString.contains("/Author"))
        #expect(!pdfString.contains("/Title"))
        #expect(!pdfString.contains("/Subject"))
        #expect(!pdfString.contains("/Keywords"))
    }

    // MARK: - Helpers

    private enum PinTestError: Error {
        case pdfOpenFailed
        case imageDecodeFailed
    }

    /// ImageIO property dictionary for a JPEG's first image.
    private func imageProperties(_ data: Data) throws -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any] else {
            throw PinTestError.imageDecodeFailed
        }
        return props
    }

    /// Raw bytes of every JPEG-encoded image XObject stream on every page.
    /// Deliberately returns the UNDECODED stream data (unlike the engine's
    /// `extractPageImages`, which decodes to CGImage and thereby drops the
    /// metadata this test needs to inspect).
    private func jpegStreams(inPDF data: Data) throws -> [Data] {
        guard let provider = CGDataProvider(data: data as CFData),
              let doc = CGPDFDocument(provider) else {
            throw PinTestError.pdfOpenFailed
        }
        var streams: [Data] = []
        for pageNumber in 1...max(1, doc.numberOfPages) {
            guard let page = doc.page(at: pageNumber),
                  let dict = page.dictionary else { continue }
            var resources: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources),
                  let res = resources else { continue }
            var xobjects: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(res, "XObject", &xobjects),
                  let xobj = xobjects else { continue }
            CGPDFDictionaryApplyBlock(xobj, { _, value, _ in
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(value, .stream, &stream),
                      let s = stream else { return true }
                var format = CGPDFDataFormat.raw
                guard let streamData = CGPDFStreamCopyData(s, &format),
                      format == .jpegEncoded else { return true }
                streams.append(streamData as Data)
                return true
            }, nil)
        }
        return streams
    }
}
