import Foundation
import CoreGraphics
import PDFKit
@testable import RedactionEngine

// The production page loop for tests: every page through
// `PageRasterizer.rasterize(_:dpiCap:)` and `PDFStreamReconstructor`, the
// path the product's export runs. The verification-corpus runner and the
// test pipeline both call it.

enum ProductionPageLoop {

    struct RedactionOutcome {
        let filterDigests: [PageFilterDigest?]
        let perPageModes: [PipelineMode]
        let perPageFallbackReasons: [TextLayerDetector.FallbackReason?]
    }

    /// Mirror of `PipelineCoordinator.processDocument` + `rasterizeWithRetry`:
    /// rotation-swapped first page size, strict 0..<count append order (pages
    /// run serially here — the app parallelizes for wall clock only; the
    /// reconstructor's order contract is what matters), the one half-DPI
    /// retry on `fillVerificationFailed`, and the written-page-count
    /// postcondition before the atomic promote.
    static func runRedaction(
        pages: [PDFPageData], outputURL: URL, dpiCap: Int = 300
    ) async throws -> RedactionOutcome {
        let rasterizer = PageRasterizer()
        let tempURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent("recon_tmp_\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let reconstructor = PDFStreamReconstructor(tempURL: tempURL)

        let firstSize = pages.first.map { page in
            let raw = page.cropBoxBounds
            switch page.rotation {
            case 90, 270: return CGSize(width: raw.height, height: raw.width)
            default: return raw.size
            }
        } ?? CGSize(width: 612, height: 792)
        try await reconstructor.begin(firstPageSize: firstSize)

        var digests: [PageFilterDigest?] = []
        var modes: [PipelineMode] = []
        var reasons: [TextLayerDetector.FallbackReason?] = []
        for page in pages {
            let result: RasterizeResult
            do {
                result = try await rasterizer.rasterize(page, dpiCap: dpiCap)
            } catch let error as PipelineError { // LegalPhrases:safe (Swift keyword)
                guard case .redactionError(.fillVerificationFailed(let idx)) = error,
                      idx == page.pageIndex else { throw error }
                result = try await rasterizer.rasterize(
                    page, dpiCap: max(96, dpiCap / 2))
            }
            digests.append(result.filterDigest)
            modes.append(result.filterDigest != nil
                ? .searchableRedaction : .secureRasterization)
            reasons.append(result.fallbackReason)
            try await reconstructor.appendPage(result.pageOutput)
        }
        await reconstructor.finalize()
        let written = await reconstructor.writtenPageCount
        guard written == pages.count else {
            throw PipelineError.redactionError(.reconstructionFailed)
        }
        _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: tempURL)
        return RedactionOutcome(
            filterDigests: digests, perPageModes: modes,
            perPageFallbackReasons: reasons)
    }
}
