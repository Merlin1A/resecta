import Testing
import Foundation
import ImageIO
import CoreGraphics
import UIKit
import PDFKit
@testable import ResectaApp
@testable import RedactionEngine

// SEC-8 prereq: Live Photo / Portrait depth aux-metadata stripper tests.
//
// The helper drops `kCGImagePropertyAuxiliaryData`, `kCGImagePropertyMakerAppleDictionary`,
// and peer keys from the image property dictionary. V1 returns the CGImage unchanged.
//
// `testHookOffByDefault` exercises the import path with the default flag value
// (`stripAuxData == false`) and confirms the image-import flow still completes
// without regression. SEC-8 (unit 23) flips the flag when paranoid mode is on.

@Suite("LivePhotoAuxStripper")
struct LivePhotoAuxStripperTests {

    // MARK: - Helpers

    /// Build a 1×1 CGImage for stripper tests. Content does not matter — V1
    /// returns the image reference unchanged.
    private func makeSmallCGImage() -> CGImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        let uiImage = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return uiImage.cgImage!
    }

    // MARK: - strip(_:properties:) unit tests

    @Test("Stripping drops kCGImagePropertyAuxiliaryData")
    func testStripDropsAuxiliaryData() {
        let stripper = LivePhotoAuxStripper()
        let input: [CFString: Any] = [
            kCGImagePropertyAuxiliaryData: ["depth": "placeholder"] as CFDictionary,
            kCGImagePropertyOrientation: 1 as CFNumber
        ]

        let (_, output) = stripper.strip(
            makeSmallCGImage(),
            properties: input as CFDictionary
        )

        let outDict = output as? [CFString: Any] ?? [:]
        #expect(outDict[kCGImagePropertyAuxiliaryData] == nil)
    }

    @Test("Stripping drops kCGImagePropertyMakerAppleDictionary")
    func testStripDropsMakerApple() {
        let stripper = LivePhotoAuxStripper()
        let input: [CFString: Any] = [
            kCGImagePropertyMakerAppleDictionary: ["17": "placeholder"] as CFDictionary,
            kCGImagePropertyOrientation: 1 as CFNumber
        ]

        let (_, output) = stripper.strip(
            makeSmallCGImage(),
            properties: input as CFDictionary
        )

        let outDict = output as? [CFString: Any] ?? [:]
        #expect(outDict[kCGImagePropertyMakerAppleDictionary] == nil)
    }

    @Test("Denylist covers the expanded Package H key set (Q2)")
    func testDenylistCoverage() {
        // Maintainer-ruled expanded denylist. The set of keys removed
        // by `LivePhotoAuxStripper.strip` is exposed via the static
        // `denylist` property and must include every camera-origin metadata
        // key the SEC-8 contract (`ARCHITECTURE.md §1.2`) enumerates.
        let expected: Set<CFString> = [
            kCGImagePropertyAuxiliaryData,
            kCGImagePropertyMakerAppleDictionary,
            kCGImagePropertyGPSDictionary,
            kCGImagePropertyExifDictionary,
            kCGImagePropertyTIFFDictionary,
            kCGImagePropertyIPTCDictionary,
            kCGImageAuxiliaryDataTypeDepth,
            kCGImageAuxiliaryDataTypeDisparity,
            kCGImageAuxiliaryDataTypePortraitEffectsMatte,
            kCGImageAuxiliaryDataTypeHDRGainMap,
            kCGImageAuxiliaryDataTypeISOGainMap,
            kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte,
            kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte,
        ]
        let actual = Set(LivePhotoAuxStripper.denylist)
        #expect(actual == expected)
    }

    @Test("Stripping drops the expanded peer aux keys")
    func testStripDropsExpandedDenylist() {
        // Populate the property dictionary with every expanded-denylist key.
        // Each value is a placeholder — only the key removal is under test.
        let stripper = LivePhotoAuxStripper()
        var input: [CFString: Any] = [
            kCGImagePropertyOrientation: 1 as CFNumber,
            kCGImagePropertyPixelWidth: 100 as CFNumber,
        ]
        for key in LivePhotoAuxStripper.denylist {
            input[key] = ["placeholder": true] as CFDictionary
        }

        let (_, output) = stripper.strip(
            makeSmallCGImage(),
            properties: input as CFDictionary
        )

        let outDict = output as? [CFString: Any] ?? [:]
        for key in LivePhotoAuxStripper.denylist {
            #expect(outDict[key] == nil,
                    "Denylisted key remained after strip: \(key)")
        }
        // Non-denylisted keys survive.
        #expect(outDict[kCGImagePropertyOrientation] as? Int == 1)
        #expect(outDict[kCGImagePropertyPixelWidth] as? Int == 100)
    }

    @Test("Stripping leaves non-aux keys intact")
    func testStripLeavesOtherKeysIntact() {
        let stripper = LivePhotoAuxStripper()
        let input: [CFString: Any] = [
            kCGImagePropertyAuxiliaryData: ["depth": "placeholder"] as CFDictionary,
            kCGImagePropertyMakerAppleDictionary: ["17": "placeholder"] as CFDictionary,
            kCGImagePropertyOrientation: 6 as CFNumber,
            kCGImagePropertyPixelWidth: 1024 as CFNumber,
            kCGImagePropertyPixelHeight: 768 as CFNumber,
            kCGImagePropertyColorModel: kCGImagePropertyColorModelRGB
        ]

        let (_, output) = stripper.strip(
            makeSmallCGImage(),
            properties: input as CFDictionary
        )

        let outDict = output as? [CFString: Any] ?? [:]
        #expect(outDict[kCGImagePropertyOrientation] as? Int == 6)
        #expect(outDict[kCGImagePropertyPixelWidth] as? Int == 1024)
        #expect(outDict[kCGImagePropertyPixelHeight] as? Int == 768)
        // Color model survives.
        #expect(outDict[kCGImagePropertyColorModel] != nil)
        // Aux keys still gone.
        #expect(outDict[kCGImagePropertyAuxiliaryData] == nil)
        #expect(outDict[kCGImagePropertyMakerAppleDictionary] == nil)
    }

    @Test("CGImage returned unchanged (V1 strips dict only)")
    func testCGImageReturnedUnchanged() {
        let stripper = LivePhotoAuxStripper()
        let input = makeSmallCGImage()
        let inputProps: [CFString: Any] = [
            kCGImagePropertyAuxiliaryData: ["depth": "placeholder"] as CFDictionary
        ]

        let (output, _) = stripper.strip(input, properties: inputProps as CFDictionary)

        // V1 contract: the helper does not re-encode the image. The returned
        // CGImage must be the same instance the caller passed in.
        #expect(output === input)
    }

    // MARK: - Import-path integration

    @Test("Import path: hook is off by default — image import still succeeds")
    @MainActor
    func testHookOffByDefault() async {
        // Default `stripAuxData == false`: image-import path runs without
        // engaging the stripper. Behavior must match the pre-prereq baseline.
        let doc = DocumentState()
        let redaction = RedactionState()

        await ImportService.importDocument(
            data: makeJPEGImageData(), suggestedType: "jpg",
            documentState: doc, redactionState: redaction
        )

        #expect(doc.phaseKind == .editing)
        #expect(doc.pageCount == 1)
    }

    // MARK: - H1 — rendered PDF carries no EXIF (CAT-153)

    /// Distinctive ASCII probe embedded in the fixture's EXIF UserComment.
    static let exifProbe = "RESECTA-EXIF-PROBE-DO-NOT-PROPAGATE"

    /// CAT-153 H1 (SEC-8): a JPEG carrying an EXIF + GPS APP1 segment is driven
    /// through the paranoid import path (`stripAuxData: true`) and the resulting
    /// PDF bytes are inspected. The import render boundary
    /// (`ImportService.renderImageAsPDF`) rebuilds the page from a fresh bitmap
    /// (`UIGraphicsImageRenderer`), which drops ALL ImageIO metadata, so neither
    /// the EXIF APP1 marker nor the UserComment probe may survive into the PDF.
    ///
    /// HISTORY (CAT-NEW-s12-2): an earlier render path drew the
    /// ORIGINAL EXIF-bearing `UIImage(data:)`, so `UIGraphicsPDFRenderer`
    /// embedded the source JPEG (APP1/EXIF incl. GPS) into the PDF as a
    /// DCTDecode stream and the metadata survived. These assertions were pinned
    /// with `withKnownIssue` until the leak was fixed; the render boundary now
    /// strips metadata, so they run as a HARD guard.
    @Test("Import path strips source EXIF/GPS from the rendered PDF (CAT-153 H1)")
    @MainActor
    func testRenderedPDFHasNoEXIF() async throws {
        let jpeg = try #require(makeJPEGWithEXIFAndGPS(), "failed to build EXIF JPEG fixture")
        // Sanity: the SOURCE blob really carries the EXIF APP1 marker — so the
        // assertions below are meaningful, not vacuous.
        #expect(containsEXIFMarker(jpeg), "fixture JPEG should embed an EXIF APP1 marker")

        let doc = DocumentState()
        let redaction = RedactionState()
        await ImportService.importDocument(
            data: jpeg, suggestedType: "jpg",
            documentState: doc, redactionState: redaction,
            stripAuxData: true   // paranoid path
        )
        #expect(doc.phaseKind == .editing)
        let pdfData = try #require(
            doc.sourceDocument?.dataRepresentation(),
            "import did not produce a PDF")

        // HARD guard: the import render boundary rebuilds the page from a fresh
        // bitmap, so no source EXIF/GPS may survive into the PDF (CAT-153 H1).
        #expect(
            !containsEXIFMarker(pdfData),
            "rendered PDF must not embed an EXIF APP1 marker (CAT-153 H1)")
        #expect(
            pdfData.range(of: Data(Self.exifProbe.utf8)) == nil,
            "rendered PDF must not contain the EXIF UserComment probe (CAT-153 H1)")
    }

    /// JPEG APP1 EXIF segment signature: ASCII "Exif" followed by two NUL bytes.
    private func containsEXIFMarker(_ data: Data) -> Bool {
        let exifSig = Data([0x45, 0x78, 0x69, 0x66, 0x00, 0x00]) // "Exif\0\0"
        return data.range(of: exifSig) != nil
    }

    /// Build a small JPEG that embeds an EXIF dictionary (with a probe
    /// UserComment) and a GPS dictionary via ImageIO, so the no-EXIF assertion
    /// is meaningful. Returns nil only if ImageIO fails to construct the image.
    private func makeJPEGWithEXIFAndGPS() -> Data? {
        let width = 8, height = 8
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cg = ctx.makeImage() else { return nil }

        let exif: [CFString: Any] = [
            kCGImagePropertyExifUserComment: Self.exifProbe,
            kCGImagePropertyExifDateTimeOriginal: "2024:01:01 12:00:00"
        ]
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 41.7658,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 72.6734,
            kCGImagePropertyGPSLongitudeRef: "W"
        ]
        let props: [CFString: Any] = [
            kCGImagePropertyExifDictionary: exif,
            kCGImagePropertyGPSDictionary: gps
        ]
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out as CFMutableData, "public.jpeg" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
