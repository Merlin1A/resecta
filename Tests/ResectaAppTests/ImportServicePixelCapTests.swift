import Testing
import Foundation
import UIKit
import CoreGraphics
@testable import ResectaApp
@testable import RedactionEngine

// Pkg G.1 / TRUST-import-image-pixel-vs-point-cap: the 5000-dimension cap on
// imported images was checking POINT dimensions (`image.size.width`) instead
// of PIXEL dimensions. A `UIImage` with `scale: 3.0` and 4000×4000 pt size
// is 12000×12000 px = 144 MP and slipped through; the renderer would then
// allocate ~575 MB of backing store to draw it. These tests pin the cap to
// the bitmap-pixel dimensions.

@Suite("ImportService pixel cap", .tags(.importFlow))
@MainActor
struct ImportServicePixelCapTests {

    // MARK: - Pixel-cap rejection (the fix)

    @Test("Scale-3 image at 4000 points rejects as oversize")
    func testScale3Image4000PointsRejectsAsOversize() async {
        let doc = DocumentState()
        let redaction = RedactionState()
        // 4000 pt × 3.0 scale = 12000 px. Both dimensions exceed the 5000 px
        // cap; the import path must reject with .invalidPageDimensions.
        let data = makeJPEGImageDataWithScale(pointSize: 4000, scale: 3.0)

        await ImportService.importDocument(
            data: data, suggestedType: "image",
            documentState: doc, redactionState: redaction)

        #expect(doc.phaseKind == .failed)
        if case .failed(let error, _) = doc.phase {
            if case .importError(.invalidPageDimensions(let pageIndex)) = error {
                #expect(pageIndex == 0)
            } else {
                Issue.record("Expected .importError(.invalidPageDimensions(pageIndex: 0)), got \(error)")
            }
        } else {
            Issue.record("Expected .failed phase, got \(doc.phase)")
        }
    }

    // MARK: - Positive case (preserves prior behavior at scale 1.0)

    @Test("Scale-1 image at 4000 points accepts")
    func testScale1Image4000PointsAccepts() async {
        let doc = DocumentState()
        let redaction = RedactionState()
        // 4000 pt × 1.0 scale = 4000 px, within the 5000 px cap. This must
        // continue to import successfully — prior point-based behavior at
        // scale 1.0 is preserved.
        let data = makeJPEGImageDataWithScale(pointSize: 4000, scale: 1.0)

        await ImportService.importDocument(
            data: data, suggestedType: "image",
            documentState: doc, redactionState: redaction)

        #expect(doc.phaseKind == .editing, "4000×4000 px (scale 1.0) is within the cap")
        #expect(doc.pageCount == 1)
    }

    // MARK: - Boundary case

    @Test("Scale-2 image at 2500 points accepts at exact cap")
    func testScale2Image2500PointsAccepts() async {
        let doc = DocumentState()
        let redaction = RedactionState()
        // 2500 pt × 2.0 scale = 5000 px, equal to the cap. The guard uses
        // `<=` so this is accepted.
        let data = makeJPEGImageDataWithScale(pointSize: 2500, scale: 2.0)

        await ImportService.importDocument(
            data: data, suggestedType: "image",
            documentState: doc, redactionState: redaction)

        #expect(doc.phaseKind == .editing, "5000×5000 px (scale 2.0) is at the cap")
    }

    @Test("Scale-2 image at 2501 points rejects one past cap")
    func testScale2Image2501PointsRejects() async {
        let doc = DocumentState()
        let redaction = RedactionState()
        // 2501 pt × 2.0 scale = 5002 px, one over the cap.
        let data = makeJPEGImageDataWithScale(pointSize: 2501, scale: 2.0)

        await ImportService.importDocument(
            data: data, suggestedType: "image",
            documentState: doc, redactionState: redaction)

        #expect(doc.phaseKind == .failed)
        if case .failed(let error, _) = doc.phase {
            if case .importError(.invalidPageDimensions) = error {
                // Expected
            } else {
                Issue.record("Expected .importError(.invalidPageDimensions), got \(error)")
            }
        }
    }

    // MARK: - Fixture

    /// Encode a JPEG whose backing bitmap is `pixelSize = pointSize * scale`.
    /// Returned bytes decode as a `UIImage` whose `cgImage.width` /
    /// `cgImage.height` equals `pixelSize`, exercising the cgImage branch of
    /// the pixel cap. The encoded JPEG carries no DPI hint that would change
    /// `UIImage.scale` post-decode (scale defaults to 1.0 on `UIImage(data:)`),
    /// but the cgImage's pixel dimensions still reflect the original bitmap
    /// size — which is precisely the dimension the cap protects.
    private func makeJPEGImageDataWithScale(pointSize: Int, scale: CGFloat) -> Data {
        let pixelSide = CGFloat(pointSize) * scale
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0  // 1 px per renderer "point" → bitmap size == pixelSide
        let bitmapSize = CGSize(width: pixelSide, height: pixelSide)
        let renderer = UIGraphicsImageRenderer(size: bitmapSize, format: format)
        return renderer.jpegData(withCompressionQuality: 0.5) { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: bitmapSize))
        }
    }
}
