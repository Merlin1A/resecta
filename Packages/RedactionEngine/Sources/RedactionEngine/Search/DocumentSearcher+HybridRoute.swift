import Foundation
import PDFKit

// A page with a text layer that also carries image content (`PageImageCensus`)
// is read on both legs: the text layer, then the recognised text of the page
// image. An OCR result that repeats a text-layer result is dropped; with text
// recognition off, the page is reported once as not fully analysed.
extension DocumentSearcher {

    /// The share of the smaller of two rects their overlap must cover for an
    /// OCR result to read as the same ink as a text-layer result. The smaller
    /// rect: an OCR rect is a whole recognised line, a text-layer rect the match.
    static let hybridOverlapFloor: CGFloat = 0.5

    /// The second leg on a page whose text layer was searched: nothing unless
    /// the page carries image content; with OCR off, the not-analysed signal
    /// (when `reportsWhenOff`); otherwise the OCR leg's results minus those a
    /// text-layer rect already covers.
    func hybridOCRLeg(
        page: PDFPage, pageIndex: Int, textLayerRects: [CGRect], includeOCR: Bool,
        reportsWhenOff: Bool = true, ocr: () async -> [SearchResult]
    ) async -> [SearchResult] {
        guard PageImageCensus.carriesImageContent(page) else { return [] }
        guard includeOCR else {
            if reportsWhenOff { scannedRegionNotAnalyzedSink?(pageIndex) }
            return []
        }
        return Self.mergeHybridResults(textLayerRects: textLayerRects, ocr: await ocr())
    }

    static func mergeHybridResults(textLayerRects: [CGRect], ocr: [SearchResult]) -> [SearchResult] {
        func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }
        return ocr.filter { result in
            !textLayerRects.contains { rect in
                let smaller = min(area(rect), area(result.normalizedRect))
                return smaller > 0 && area(rect.intersection(result.normalizedRect)) >= hybridOverlapFloor * smaller
            }
        }
    }

    /// Yields `results` until the result cap: the one capped emission every
    /// routing site shares.
    func emitCapped(
        _ results: [SearchResult], into continuation: AsyncStream<SearchResult>.Continuation, total: inout Int
    ) {
        for result in results {
            if total >= Self.maxResults { break }
            continuation.yield(result)
            total += 1
        }
    }
}
