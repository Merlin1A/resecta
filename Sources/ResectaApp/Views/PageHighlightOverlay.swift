import Foundation
import PDFKit
import RedactionEngine

// W7 — live-preview rect resolution.
//
// The engine returns NSRanges (it has no PDFPage context). The view needs
// normalized rects to draw highlights. This helper bridges the two by
// invoking `DocumentSearcher.boundingRect(for:page:)` (W7 promoted to
// `public nonisolated`) for each range on the visible page only.
//
// Rendering of the resolved rects happens inside `RedactionOverlayView`
// (the existing per-page UIKit overlay) so the live preview shares the
// same coordinate space, scroll/zoom transform, and layer ordering as
// the committed search highlights.
enum PageHighlightOverlay {

    /// Resolve preview NSRanges to normalized PDF rects for the given
    /// page. Skips ranges PDFKit can't map (off-page, no selection).
    /// Caller is expected to pass only the visible page's ranges.
    static func resolveRects(
        for ranges: [NSRange],
        page: PDFPage,
        searcher: DocumentSearcher
    ) -> [CGRect] {
        guard !ranges.isEmpty else { return [] }
        var rects: [CGRect] = []
        rects.reserveCapacity(ranges.count)
        for range in ranges {
            if let rect = searcher.boundingRect(for: range, page: page) {
                rects.append(rect)
            }
        }
        return rects
    }
}
