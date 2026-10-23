import Testing
import Foundation
import PDFKit
import UIKit
import CoreGraphics
import ImageIO
@testable import ResectaApp
@testable import RedactionEngine

// Shared test helpers for ResectaApp tests.
// Centralizes fixture construction and tags.

// MARK: - Tags

extension Tag {
    /// Import validation tests.
    @Tag static var importFlow: Self
    /// Overlay coordinate conversion tests.
    @Tag static var overlay: Self
    /// Display property tests (accessibility, symbols, colors).
    @Tag static var display: Self
    /// Tests that must never regress — pixel destruction, coordinate conversion.
    @Tag static var critical: Self
    /// Pipeline coordination and orchestration tests.
    @Tag static var coordination: Self
    /// Search state, persistence and results tests.
    @Tag static var search: Self
}

// MARK: - Coordinator Factory

/// Create a PipelineCoordinator with fresh state objects. Without an argument
/// the settings are built on a fresh scratch defaults suite (one UUID-named
/// domain per call), so the test never reads or writes the app's own defaults
/// domain; pass a `SettingsState(defaults:)` of your own to share a suite.
@MainActor
func makeCoordinator(settingsState: SettingsState? = nil) -> PipelineCoordinator {
    PipelineCoordinator(
        documentState: DocumentState(),
        redactionState: RedactionState(),
        settingsState: settingsState ?? SettingsState(defaults: makeScratchDefaults().0)
    )
}

/// A coordinator with a source document loaded and parked in the `.editing`
/// phase, so a run can be driven forward. `document` defaults to a blank
/// one-page PDF; `defaults` is the suite the settings read, a fresh scratch
/// suite when nil.
@MainActor
func makeLoadedCoordinator(
    document: PDFDocument = makeTestPDFDocument(),
    defaults: UserDefaults? = nil
) -> PipelineCoordinator {
    let coord = makeCoordinator(settingsState: defaults.map { SettingsState(defaults: $0) })
    coord.documentState.sourceDocument = document
    coord.documentState.phase = .editing
    return coord
}

// MARK: - PDF Fixture Factories

/// Create a minimal 1-page PDFDocument.
func makeTestPDFDocument() -> PDFDocument {
    let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
    let data = renderer.pdfData { ctx in
        ctx.beginPage()
    }
    return PDFDocument(data: data)!
}

/// Create a multi-page PDFDocument with blank pages.
func makeMultiPagePDFDocument(pages: Int) -> PDFDocument {
    let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
    let data = renderer.pdfData { ctx in
        for _ in 0..<pages {
            ctx.beginPage()
        }
    }
    return PDFDocument(data: data)!
}

/// Create a PDFDocument with text content (enables text layer detection).
func makeTextPDFDocument(text: String) -> PDFDocument {
    let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
    let data = renderer.pdfData { ctx in
        ctx.beginPage()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 24)
        ]
        (text as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: attrs)
    }
    return PDFDocument(data: data)!
}

/// Create raw PDF Data for a blank 1-page document.
func makeTestPDFData() -> Data {
    let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
    return renderer.pdfData { ctx in
        ctx.beginPage()
    }
}

/// Create raw PDF Data for a multi-page document.
func makeMultiPagePDFData(pages: Int) -> Data {
    let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
    return renderer.pdfData { ctx in
        for _ in 0..<pages {
            ctx.beginPage()
        }
    }
}

/// Create raw PDF Data with text content.
func makeTextPDFData(text: String) -> Data {
    let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
    return renderer.pdfData { ctx in
        ctx.beginPage()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 24)
        ]
        (text as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: attrs)
    }
}

/// Memory-stress fixture. A multi-page PDF whose
/// lower `noiseFraction` of each page is filled with a deterministic
/// pseudo-random grayscale pattern; the upper portion is white with an index
/// stamp.
///
/// Why noise instead of blank: blank/white rasters are trivially compressible,
/// and the macOS memory compressor on a pressured host can deflate an
/// *unfixed* run's resident footprint below any threshold — a false green for
/// the apply-phase footprint tests. ~50% incompressible content keeps the
/// unfixed per-page resident signal high (≥ ~16.8 MB/page even fully
/// compressed) while JPEG output stays modest, so the fixed run's reconstructor
/// floor stays small. The noise is generated by a fixed-seed LCG so the fixture
/// is byte-reproducible across runs (deterministic, no `Date`/random seed).
///
/// 300-DPI per-page raster is 2550×3300 px × 4 B = ~33.7 MB regardless of
/// content; the noise only governs how compressible that resident bitmap is.
func makeNoiseBandMultiPagePDF(pages: Int, noiseFraction: Double = 0.5) throws -> URL {
    let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)

    // Build one high-entropy grayscale noise image, shared by every page. The
    // source bytes repeat across pages, but each page's 300-DPI raster still
    // contains a full incompressible band, which is what the memory compressor
    // sees. Resolution is high enough that nearest-neighbor upscaling to the
    // raster keeps the entropy high (drawn with interpolation .none below).
    let clampedFraction = min(max(noiseFraction, 0.0), 1.0)
    let noiseW = 1224
    let noiseH = max(1, Int(792.0 * clampedFraction))
    var noiseBytes = [UInt8](repeating: 0, count: noiseW * noiseH)
    // Numerical-Recipes LCG constants; fixed seed → reproducible.
    var state: UInt64 = 0x2545_F491_4F6C_DD1D
    for i in 0..<noiseBytes.count {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        noiseBytes[i] = UInt8((state >> 33) & 0xFF)
    }
    let gray = CGColorSpaceCreateDeviceGray()
    let noiseImage: CGImage? = noiseBytes.withUnsafeMutableBytes { raw -> CGImage? in
        guard let ctx = CGContext(
            data: raw.baseAddress, width: noiseW, height: noiseH,
            bitsPerComponent: 8, bytesPerRow: noiseW, space: gray,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        return ctx.makeImage()  // copies the buffer into an independent image
    }

    let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "cat227-noise-\(UUID().uuidString).pdf"
    )
    try renderer.writePDF(to: url) { ctx in
        // Lower band in UIKit top-left coordinates (y grows downward).
        let band = CGRect(
            x: 0,
            y: pageRect.height * CGFloat(1.0 - clampedFraction),
            width: pageRect.width,
            height: pageRect.height * CGFloat(clampedFraction)
        )
        for i in 0..<pages {
            ctx.beginPage()
            ("Noise page \(i + 1)" as NSString).draw(
                at: CGPoint(x: 36, y: 36),
                withAttributes: [.font: UIFont.systemFont(ofSize: 14)]
            )
            if let noiseImage {
                let cg = ctx.cgContext
                cg.interpolationQuality = .none  // keep blocky, high-entropy
                cg.draw(noiseImage, in: band)
            }
        }
    }
    return url
}

/// Create JPEG image data for image import tests.
func makeJPEGImageData() -> Data {
    let size = CGSize(width: 200, height: 200)
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.jpegData(withCompressionQuality: 0.8) { ctx in
        UIColor.white.setFill()
        ctx.fill(CGRect(origin: .zero, size: size))
    }
}

/// Create PNG image data for image import tests.
func makePNGImageData() -> Data {
    let size = CGSize(width: 200, height: 200)
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.pngData { ctx in
        UIColor.white.setFill()
        ctx.fill(CGRect(origin: .zero, size: size))
    }
}

/// Build a small JPEG that embeds an EXIF dictionary (the probe string as
/// its UserComment) and a GPS dictionary through ImageIO, so a no-metadata
/// assertion on something derived from it has a marker to miss. Returns
/// nil only if ImageIO fails to construct the image.
func makeJPEGWithEXIFAndGPS(probe: String) -> Data? {
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
        kCGImagePropertyExifUserComment: probe,
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

// MARK: - Mock Factories

extension DetectionResult {
    /// Create a mock detection result for app-target tests.
    static func mock(
        kind: DetectionResult.Kind = .pii(.ssn),
        matchedText: String? = nil,
        recognitionLevel: DetectionResult.RecognitionLevel = .fast
    ) -> DetectionResult {
        DetectionResult(
            id: UUID(),
            normalizedRect: CGRect(x: 0.1, y: 0.8, width: 0.3, height: 0.04),
            kind: kind,
            confidence: 0.95,
            matchedText: matchedText,
            recognitionLevel: recognitionLevel
        )
    }
}

extension RedactionRegion {
    /// Create a mock manual redaction region.
    static func mock(
        rect: CGRect = CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.05)
    ) -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: rect, source: .manual)
    }
}

extension RegionMetadata {
    /// Create a mock region metadata entry.
    static func mock(
        piiKind: DetectionResult.Kind = .pii(.ssn),
        confidence: Double = 0.95,
        matchedText: String? = "123-45-6789",
        recognitionLevel: DetectionResult.RecognitionLevel = .fast
    ) -> RegionMetadata {
        RegionMetadata(
            piiKind: piiKind,
            confidence: confidence,
            matchedText: matchedText,
            recognitionLevel: recognitionLevel
        )
    }
}

// MARK: - UndoManager Helpers

/// UndoManager with groupsByEvent disabled for deterministic test behavior.
@MainActor
func makeUndoManager() -> UndoManager {
    let mgr = UndoManager()
    mgr.groupsByEvent = false
    return mgr
}

/// Wrap an operation in an explicit undo group so each operation
/// can be undone independently (no run loop grouping in tests).
@MainActor
func withUndoGroup(_ mgr: UndoManager, _ body: () -> Void) {
    mgr.beginUndoGrouping()
    body()
    mgr.endUndoGrouping()
}

// MARK: - Last-run inputs fixture

extension RedactionState.LastRunInputs {
    /// The run inputs with every field defaulted to the empty run; the
    /// fallback reasons default to one nil per page.
    static func fixture(
        perPageModes: [PipelineMode] = [.secureRasterization],
        perPageFallbackReasons: [TextLayerDetector.FallbackReason?]? = nil,
        sensitiveTerms: [SensitiveTerm] = [],
        manualRegionsWithoutText: Int = 0,
        appliedSearches: [SearchRecheckRequest] = [],
        deselection: RedactionState.DeselectionSnapshot? = nil,
        ocrSkippedPages: Set<Int> = [],
        degradeFailures: [String]? = nil,
        burnedRegionVersion: Int? = nil
    ) -> RedactionState.LastRunInputs {
        RedactionState.LastRunInputs(
            perPageModes: perPageModes,
            perPageFallbackReasons: perPageFallbackReasons
                ?? Array(repeating: nil, count: perPageModes.count),
            sensitiveTerms: SensitiveTermSet(
                terms: sensitiveTerms, manualRegionsWithoutText: manualRegionsWithoutText),
            appliedSearches: appliedSearches,
            deselection: deselection,
            ocrSkippedPages: ocrSkippedPages,
            degradeFailures: degradeFailures,
            burnedRegionVersion: burnedRegionVersion)
    }
}
