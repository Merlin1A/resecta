import Testing
import Foundation
import PDFKit
import CoreGraphics
import CoreText
@testable import RedactionEngine

extension VerificationEngineTests {

    // MARK: - Helpers

    func makeCleanPDF() async throws -> (PDFDocument, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("verify_test_\(UUID().uuidString).pdf")

        guard let ctx = createBitmapContext(width: 200, height: 300) else {
            throw TestError.failed
        }
        ctx.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
        guard let image = ctx.makeImage() else { throw TestError.failed }

        let recon = PDFStreamReconstructor(tempURL: url)
        let size = CGSize(width: 200, height: 300)
        try await recon.begin(firstPageSize: size)
        try await recon.appendPage(PageOutput(image: image, size: size, textLayerEntries: nil))
        await recon.finalize()

        guard let doc = PDFDocument(url: url) else { throw TestError.failed }
        return (doc, url)
    }

    // MARK: - Region-scoped-OCR fixture helpers

    func manualRegion(_ rect: CGRect) -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: rect, source: .manual)
    }

    /// Render black text on a white page using the PRODUCTION bottom-left bitmap
    /// context (`createBitmapContext`) so orientation round-trips through
    /// `PDFStreamReconstructor` exactly as a real rasterized page does. Each
    /// baseline origin is in bottom-left pixel coordinates (high y = top).
    func renderTextPageImage(
        _ texts: [(string: String, baseline: CGPoint, fontSize: CGFloat)],
        size: CGSize
    ) throws -> CGImage {
        guard let ctx = createBitmapContext(width: Int(size.width), height: Int(size.height)) else {
            throw TestError.failed
        }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)  // CTLineDraw uses the fill color
        ctx.textMatrix = .identity
        for item in texts {
            let font = CTFontCreateWithName("Helvetica" as CFString, item.fontSize, nil)
            let attr = NSAttributedString(
                string: item.string,
                attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
            let line = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = item.baseline
            CTLineDraw(line, ctx)
        }
        guard let image = ctx.makeImage() else { throw TestError.failed }
        return image
    }

    /// Wrap a single CGImage as a one-page full-page-JPEG PDF via the production
    /// reconstructor — the exact shape Layer 2 verifies.
    func makeImagePDF(_ image: CGImage, size: CGSize) async throws -> (PDFDocument, URL) {
        try await makeImagePDF(pages: [image], size: size)
    }

    /// Multi-page variant: one full-page JPEG per element, each page at its
    /// image's own pixel size (so per-page fixtures can differ).
    func makeImagePDF(pages: [CGImage], size: CGSize) async throws -> (PDFDocument, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("verify_layer2_\(UUID().uuidString).pdf")
        let recon = PDFStreamReconstructor(tempURL: url)
        try await recon.begin(firstPageSize: size)
        for image in pages {
            let pageSize = CGSize(width: image.width, height: image.height)
            try await recon.appendPage(PageOutput(image: image, size: pageSize, textLayerEntries: nil))
        }
        await recon.finalize()
        guard let doc = PDFDocument(url: url) else { throw TestError.failed }
        return (doc, url)
    }

    enum TestError: Error { case failed }
}
