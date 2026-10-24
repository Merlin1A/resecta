import Foundation
import PDFKit
import RedactionEngine

// Live-preview rect resolution.
//
// The engine returns NSRanges (it has no PDFPage context). The view needs
// normalized rects to draw highlights. This helper bridges the two for the
// visible page only, from the preview's raw page ranges, one rect per line,
// through `DocumentSearcher.boundingRect(for:page:)` (public nonisolated).
//
// Rendering of the resolved rects happens inside `RedactionOverlayView`
// (the existing per-page UIKit overlay) so the live preview shares the
// same coordinate space, scroll/zoom transform, and layer ordering as
// the committed search highlights.
enum PageHighlightOverlay {

    /// The live preview's highlight rects for the visible page, as the
    /// full search places Apply's boxes: each match's range in the raw
    /// page text (`currentPageRawRanges`, the map the boxes come from), one
    /// rect per line the match spans. Ranges PDFKit can't place are left
    /// out.
    static func previewRects(
        for preview: SearchPreviewResult,
        page: PDFPage,
        searcher: DocumentSearcher
    ) -> [CGRect] {
        preview.currentPageRawRanges.flatMap { lineRects(for: $0, page: page, searcher: searcher) }
    }

    /// One normalized rect per line of a raw range's selection
    /// (`selectionsByLine()`), each through the engine's one public
    /// normalize path (`boundingRect`), the path its own per-line boxes
    /// take.
    private static func lineRects(for range: NSRange, page: PDFPage, searcher: DocumentSearcher) -> [CGRect] {
        guard let selection = page.selection(for: range) else { return [] }
        return selection.selectionsByLine().compactMap { line in
            guard line.numberOfTextRanges(on: page) > 0 else { return nil }
            return searcher.boundingRect(for: line.range(at: 0, on: page), page: page)
        }
    }
}
