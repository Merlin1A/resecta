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
        /// The fit could not read the page in time: `rect` is the drift
        /// envelope around the hidden glyphs, not the ink they name.
        var degraded = false
        /// The box a hybrid page tells this match's OCR repeat by, where it is
        /// not `rect`: the box the word's tallest band alone paints, when the
        /// fit took more bands, or its box before the growth to the match's own
        /// glyphs (`SearchResult.identityRect`); nil otherwise.
        var identity: CGRect? = nil
        /// The box the hybrid merge compares (`mergeHybridResults`).
        var mergeIdentity: CGRect { identity ?? rect }
        /// The box's characters as a range of the page's string (UTF-16), when
        /// the box is one line of a match or one match's whole range; nil for
        /// a box that stands for no single range.
        var characters: Range<Int>? = nil
    }

    /// One box per line the range's selection touches (the `lineRects`
    /// counting rule), each with its hidden glyphs' box where the page has one.
    nonisolated func textLayerLines(for nsRange: NSRange, page: PDFPage) -> [TextLayerBox]? {
        if let split = textLayerAndInkRects(for: nsRange, page: page) {
            return split.paint.indices.map {
                TextLayerBox(rect: split.paint[$0], textLayerRect: split.strip[$0], degraded: split.degraded,
                             identity: split.identity[$0], characters: Range(split.characters[$0]))
            }
        }
        return lineBoxes(for: nsRange, page: page)?.map {
            TextLayerBox(rect: $0.rect, textLayerRect: nil, identity: $0.identity, characters: Range($0.characters))
        }
    }

    /// One box for the whole range (the `boundingRect` rule, used by the PII
    /// sites): the lines' boxes united, and their hidden glyphs' boxes united.
    nonisolated func textLayerBox(for nsRange: NSRange, page: PDFPage) -> TextLayerBox? {
        if let split = textLayerAndInkRects(for: nsRange, page: page), let paint = split.paint.first,
           let strip = split.strip.first {
            let rect = split.paint.dropFirst().reduce(paint) { $0.union($1) }
            let identities = split.paint.indices.map { split.identity[$0] ?? split.paint[$0] }
            let identity = identities.dropFirst().reduce(identities[0]) { $0.union($1) }
            return TextLayerBox(rect: rect,
                                textLayerRect: split.strip.dropFirst().reduce(strip) { $0.union($1) },
                                degraded: split.degraded, identity: identity == rect ? nil : identity,
                                characters: Range(nsRange))
        }
        return boundingBox(for: nsRange, page: page).map {
            TextLayerBox(rect: $0.rect, textLayerRect: nil, identity: $0.identity, characters: Range(nsRange))
        }
    }
}
