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
    /// text-layer rect already covers. Either way the page's pictures are
    /// reported: required when the census counts them, below the floors when
    /// the page has a picture it does not count, and whether the text is
    /// another app's hidden layer over a page-size picture.
    func hybridOCRLeg(
        page: PDFPage, pageIndex: Int, textLayerRects: [CGRect], includeOCR: Bool,
        reportsWhenOff: Bool = true, ocr: () async -> [SearchResult]
    ) async -> [SearchResult] {
        guard PageImageCensus.carriesImageContent(page) else {
            if let sink = pageCoverageSink, let cgPage = page.pageRef, PageImageCensus.largestImagePixelArea(of: cgPage) != nil {
                sink(PageSearchCoverage(pageIndex: pageIndex, route: .textLayer, pictures: .belowFloors))
            }
            return []
        }
        if let sink = pageCoverageSink {
            let anotherAppsLayer = page.pageRef.map { Self.carriesHiddenTextOverImage(page, cgPage: $0) } ?? false
            sink(PageSearchCoverage(pageIndex: pageIndex, route: .textLayer, pictures: .required,
                                    throughAnotherAppsLayer: anotherAppsLayer))
        }
        guard includeOCR else {
            if reportsWhenOff { scannedRegionNotAnalyzedSink?(pageIndex) }
            return []
        }
        return Self.mergeHybridResults(textLayerRects: textLayerRects, ocr: await ocr())
    }

    /// The OCR leg's results less those that repeat a text-layer result. An
    /// OCR result repeats a text-layer rect when their overlap covers
    /// `hybridOverlapFloor` of the smaller, or when the text-layer rect's centre
    /// lies inside it. The centre test does not depend on the text-layer rect's
    /// size: a box fitted to the ink, and the drift envelope a page read too
    /// slowly gets (taller than the line, centred where the word should be), both
    /// have their centre on the recognised line. Each text-layer rect accounts
    /// for at most one OCR result, so a second occurrence on the same line, which
    /// the text layer does not hold, keeps its OCR result. An OCR result whose
    /// box a merge of two readings grew is told by the box its read gave it
    /// (`identityRect`), not the grown one, which can reach over a text-layer
    /// word it does not name.
    static func mergeHybridResults(textLayerRects: [CGRect], ocr: [SearchResult]) -> [SearchResult] {
        func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }
        func repeats(_ rect: CGRect, _ ocrRect: CGRect) -> Bool {
            let smaller = min(area(rect), area(ocrRect))
            if smaller > 0 && area(rect.intersection(ocrRect)) >= hybridOverlapFloor * smaller { return true }
            return !rect.isEmpty && ocrRect.contains(CGPoint(x: rect.midX, y: rect.midY))
        }
        var unmatched = textLayerRects
        return ocr.filter { result in
            let identity = result.identityRect ?? result.normalizedRect
            guard let index = unmatched.firstIndex(where: { repeats($0, identity) }) else { return true }
            unmatched.remove(at: index)
            return false
        }
    }

    /// Yields `results` until the result cap: the one capped emission every
    /// routing site shares. The cap counts occurrences, not rows: a match
    /// over several lines, or across a page break, is listed whole or not at
    /// all. The one exception: a piece with no box is an occurrence of its
    /// own (`occurrenceKey`), so a match across a page break with one part
    /// boxed and one not counts as two, and either may fall past the cap.
    /// A piece of an occurrence this call has begun is always yielded; a
    /// new occurrence is begun only under the cap, and `total` counts it once.
    /// Every piece of an occurrence arrives in one call (a page's results, its
    /// recognised lines, or both sides of a page break together).
    func emitCapped(
        _ results: [SearchResult], into continuation: AsyncStream<SearchResult>.Continuation, total: inout Int
    ) {
        var begun = Set<UUID>()
        for result in results {
            let key = Self.occurrenceKey(result)
            if !begun.contains(key) {
                if total >= Self.maxResults { continue }
                begun.insert(key)
                total += 1
            }
            continuation.yield(result)
        }
    }

    /// The occurrence a result belongs to, keyed as the result list keys it:
    /// a piece with a box by its occurrence, a piece with no box on its own.
    static func occurrenceKey(_ result: SearchResult) -> UUID {
        result.hasBox ? (result.occurrenceID ?? result.id) : result.id
    }
}
