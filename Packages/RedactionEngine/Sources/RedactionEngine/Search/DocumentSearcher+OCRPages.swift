import Foundation
import PDFKit
#if canImport(UIKit)
import UIKit
#else
import AppKit

// macOS tooling destination: PDFPage.thumbnail returns NSImage; mirror the
// UIImage.cgImage property so the shared call sites compile unchanged.
private extension NSImage {
    var cgImage: CGImage? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
#endif

// Moved whole from DocumentSearcher.swift; no line inside a moved body changes.

extension DocumentSearcher {

    // MARK: - OCR Search Path

    /// The literal matches on a page read by OCR (no usable text layer, or
    /// the hybrid leg of a text-layer page): the page's recognised lines,
    /// from the per-session cache when present, through the one OCR literal
    /// matcher (`ocrLiteralMatches`).
    func searchPageViaOCR(
        page: PDFPage,
        pageIndex: Int,
        query: String,
        options: SearchOptions,
        term: String
    ) async -> [SearchResult] {
        let textLines = await ocrLines(for: page, pageIndex: pageIndex)
        let accurate = ocrLiteralMatches(lines: textLines, query: query, options: options, page: page, pageIndex: pageIndex, term: term)
        // iOS 27: the same matcher over the page's fast read, merged.
        guard Self.readsFastOCRBeside, let fast = ocrPageCache.fastLines(for: pageIndex), !fast.isEmpty else {
            return accurate
        }
        return Self.unionFastOCRResults(
            accurate: accurate,
            fast: ocrLiteralMatches(lines: fast, query: query, options: options, page: page, pageIndex: pageIndex, term: term))
    }

    // MARK: - OCR page lines (the one render→cache→evict body for every OCR path)

    /// The OCR lines for a page, from the per-session cache when present.
    /// On a cache miss the page is rendered at 300 DPI off-actor (the
    /// SendablePDFPage + thumbnail-in-detached-Task idiom), read by Vision,
    /// and inserted through the shared eviction path so the verbatim lines
    /// and the normalized inputs stay in lockstep. The three OCR entry paths
    /// (manual OCR search, PII scan, regex OCR fallback) share this body.
    ///
    /// Memory guard: oversized pages (e.g., architectural drawings) can
    /// produce multi-gigabyte bitmaps at 300 DPI, so a page past the OCR
    /// pixel caps is skipped rather than risk an allocation crash (see KI-5
    /// re: os_proc_available_memory()). The per-axis cap admits a
    /// 10000 × 10000 (~ 400 MB) bitmap that can still trip jetsam; the
    /// pixel-count cap rejects near-axis-cap pages on top of it.
    ///
    /// Coverage: the `.ocr` route is reported once per call, after the
    /// get-or-compute block, on both the hit and the miss path; a skipped
    /// or unreadable page reports its own route and returns no lines.
    func ocrLines(for page: PDFPage, pageIndex: Int) async -> [OCREngine.TextLine] {
        let textLines: [OCREngine.TextLine]
        if let cached = ocrPageCache.touch(pageIndex) {
            textLines = cached
        } else {
            let pageBounds = page.bounds(for: .cropBox)
            let thumbnailSize = Self.ocrThumbnailSize(
                pageBounds: pageBounds, rotation: page.rotation)
            let pixelCount = thumbnailSize.width * thumbnailSize.height
            guard thumbnailSize.width <= Self.maxOCRPixelDimension,
                  thumbnailSize.height <= Self.maxOCRPixelDimension,
                  pixelCount <= Self.maxOCRPixelCount else {
                // Report the skip so the app layer can tell the
                // user this page's image content was never text-scanned.
                ocrSkipSink?(pageIndex)
                pageCoverageSink?(PageSearchCoverage(pageIndex: pageIndex, route: .ocrSkippedOversize))
                return []
            }

            // Render off-actor — page.thumbnail is synchronous PDFKit and
            // can take seconds on a near-cap page. Holding the actor for
            // that span starves queued setters (sinks, thresholds).
            let sendablePage = SendablePDFPage(page)
            let thumbnail = await Task.detached(priority: .userInitiated) {
                sendablePage.page.thumbnail(of: thumbnailSize, for: .cropBox)
            }.value
            guard let cgImage = thumbnail.cgImage else {
                pageCoverageSink?(PageSearchCoverage(pageIndex: pageIndex, route: .ocrUnavailable))
                return []
            }

            do {
                let lines = try await ocrEngine.recognizeText(
                    in: cgImage, recognitionLevel: .accurate
                )
                // iOS 27: the fast read of the same image beside the accurate
                // one (`DocumentSearcher+OCRFastUnion`); nil elsewhere, and
                // when the fast read fails the accurate read stands alone.
                var fast: [OCREngine.TextLine]? = nil
                if Self.readsFastOCRBeside {
                    fast = try? await ocrEngine.recognizeText(in: cgImage, recognitionLevel: .fast)
                }
                ocrPageCache.insert(lines, fast: fast, for: pageIndex)
                textLines = lines
            } catch { // LegalPhrases:safe (Swift keyword)
                pageCoverageSink?(PageSearchCoverage(pageIndex: pageIndex, route: .ocrUnavailable))
                return []
            }
        }

        pageCoverageSink?(PageSearchCoverage(pageIndex: pageIndex, route: .ocr))
        return textLines
    }
}
