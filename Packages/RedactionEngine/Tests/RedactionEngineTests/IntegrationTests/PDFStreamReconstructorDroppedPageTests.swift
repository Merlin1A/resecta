import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import RedactionEngine

// CAT-369 — writtenPageCount postcondition.
//
// Under draw-on-append (K=0, CND-11) each appendPage draws one page, except
// where the per-page decode guard drops it silently. `writtenPageCount` must
// reflect the pages actually drawn so the coordinator can gate the atomic
// rename on it (PipelineCoordinator: writtenPageCount == pages.count) and never
// promote a truncated temp file over a good output.

@Suite("PDF Reconstructor Dropped-Page Postcondition")
struct PDFStreamReconstructorDroppedPageTests {

    @Test("writtenPageCount equals the buffered count when every page decodes")
    func writtenPageCountMatchesOnHappyPath() async throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let image = try makeTestImage(width: 120, height: 160)
        let size = CGSize(width: 120, height: 160)
        let recon = PDFStreamReconstructor(tempURL: url)

        try await recon.begin(firstPageSize: size)
        try await recon.appendPage(PageOutput(image: image, size: size, textLayerEntries: nil))
        try await recon.appendPage(PageOutput(image: image, size: size, textLayerEntries: nil))
        let buffered = await recon.pageCount
        await recon.finalize()

        #expect(buffered == 2)
        #expect(await recon.writtenPageCount == 2,
                "Every buffered page decoded, so all are written")
    }

    @Test("finalize counts only pages that actually wrote (CAT-369)")
    func finalizeCountsWrittenPages() async throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let image = try makeTestImage(width: 120, height: 160)
        let size = CGSize(width: 120, height: 160)
        let recon = PDFStreamReconstructor(tempURL: url)

        try await recon.begin(firstPageSize: size)
        // Page 0: a real, decodable JPEG.
        try await recon.appendPage(PageOutput(image: image, size: size, textLayerEntries: nil))
        // Page 1: raw garbage that fails the append-time decode guard —
        // counted as appended (pageCount == 2) but never drawn.
        await recon.appendUnencodedPageForTesting(
            jpegData: Data([0x00, 0x01, 0x02, 0x03, 0xFF]), size: size)

        let buffered = await recon.pageCount
        await recon.finalize()
        let written = await recon.writtenPageCount

        #expect(buffered == 2, "Both pages are buffered before finalize")
        #expect(written == 1,
                "The undecodable page is dropped; writtenPageCount must be 1 < 2")
    }

    // MARK: - Helpers

    private func makeTempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cat369_recon_\(UUID().uuidString).pdf")
    }

    private func makeTestImage(width: Int, height: Int) throws -> CGImage {
        guard let ctx = createBitmapContext(width: width, height: height) else {
            throw TestError.failed
        }
        ctx.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage() else { throw TestError.failed }
        return image
    }

    private enum TestError: Error { case failed }
}
