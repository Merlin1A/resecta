import CoreGraphics
import Foundation
import PDFKit

// The text-layer result sites read their boxes here: the box a fill paints,
// and on a page whose text is an invisible layer over a page image the hidden
// glyphs' own box, which a Searchable export strips (`SearchResult.textLayerRect`).
// On every other page the box is the selection's as before and the hidden
// glyphs' box is nil, so nothing downstream changes there.
extension DocumentSearcher {

    /// One box of a text-layer match.
    struct TextLayerBox: Sendable {
        /// What the fill paints: `SearchResult.normalizedRect`.
        let rect: CGRect
        /// The hidden glyphs' selection box on a page with a hidden layer
        /// over a page image; nil elsewhere.
        let textLayerRect: CGRect?
    }

    /// One box per line the range's selection touches (the `lineRects`
    /// counting rule), each with its hidden glyphs' box where the page has one.
    nonisolated func textLayerLines(for nsRange: NSRange, page: PDFPage) -> [TextLayerBox]? {
        if let split = textLayerAndInkRects(for: nsRange, page: page) {
            return zip(split.paint, split.strip).map { TextLayerBox(rect: $0, textLayerRect: $1) }
        }
        return lineRects(for: nsRange, page: page)?.map { TextLayerBox(rect: $0, textLayerRect: nil) }
    }

    /// One box for the whole range (the `boundingRect` rule, used by the PII
    /// sites): the lines' boxes united, and their hidden glyphs' boxes united.
    nonisolated func textLayerBox(for nsRange: NSRange, page: PDFPage) -> TextLayerBox? {
        if let split = textLayerAndInkRects(for: nsRange, page: page), let paint = split.paint.first,
           let strip = split.strip.first {
            return TextLayerBox(rect: split.paint.dropFirst().reduce(paint) { $0.union($1) },
                                textLayerRect: split.strip.dropFirst().reduce(strip) { $0.union($1) })
        }
        return boundingRect(for: nsRange, page: page).map { TextLayerBox(rect: $0, textLayerRect: nil) }
    }
}
