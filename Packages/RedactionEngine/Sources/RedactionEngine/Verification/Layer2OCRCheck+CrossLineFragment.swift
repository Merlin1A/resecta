import Foundation

// The OCR Check's cross-line fragment read. A search match that wraps onto
// a second line is boxed one line at a time; with only one line's box
// applied, the rest of the match stays printed on the neighbouring line,
// where no box sits beside it on its own line. This arm reads that shape:
// an OCR line that OPENS with the term's trailing whole words right below a
// box a search placed at the END of the line above, or one that ENDS with
// the term's leading whole words right above such a box at the START of the
// line below. Whole words of a term of two or more words only, and only
// beside a search's box: a hand box vouches for no search.

extension VerificationEngine {

    /// Whether `hit` (its recognised `text`) carries part of `term` across a
    /// line break from a search-placed box among `pageRegions`. `hits` are
    /// the page's other OCR lines: a box with recognised text after it on
    /// its own line does not end that line (and one with text before it
    /// does not open its line). Boxes, hits and regions share the
    /// normalized bottom-left space.
    static func fragmentAcrossLineBreak(
        hit: OCRHit, text: String, hits: [OCRHit], term: SensitiveTerm, pageRegions: [RedactionRegion]
    ) -> Bool {
        let termWords = foldedWords(term.text)
        let lineWords = foldedWords(text)
        guard termWords.count >= 2, !lineWords.isEmpty, hit.box.height > 0 else { return false }
        let pieces = 1..<termWords.count
        let opensWithTail = pieces.contains { lineWords.prefix($0).elementsEqual(termWords.suffix($0)) }
        let endsWithHead = pieces.contains { lineWords.suffix($0).elementsEqual(termWords.prefix($0)) }
        guard opensWithTail || endsWithHead else { return false }
        let lineHeight = hit.box.height
        return pageRegions.contains { region in
            guard case .searchMatch = region.source else { return false }
            let rect = region.normalizedRect
            if opensWithTail {
                // The box on the line directly above, ending it.
                let gap = rect.minY - hit.box.maxY
                if gap >= -lineHeight * 0.5, gap <= lineHeight,
                   !hits.contains(where: { sharesBand($0.box, rect) && $0.box.minX >= rect.maxX }) {
                    return true
                }
            }
            if endsWithHead {
                // The box on the line directly below, opening it.
                let gap = hit.box.minY - rect.maxY
                if gap >= -lineHeight * 0.5, gap <= lineHeight,
                   !hits.contains(where: { sharesBand($0.box, rect) && $0.box.maxX <= rect.minX }) {
                    return true
                }
            }
            return false
        }
    }

    /// The whitespace-separated words of `text`, each in the fragment
    /// comparison's fold (normalized, lowercased, separators dropped).
    private static func foldedWords(_ text: String) -> [[Character]] {
        TextNormalizer.normalize(text).split(whereSeparator: { $0.isWhitespace })
            .map { fragmentFold(String($0)) }.filter { !$0.isEmpty }
    }

    /// Two boxes on one line: they overlap vertically by at least half the
    /// shorter one's height.
    private static func sharesBand(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return overlap >= min(a.height, b.height) * 0.5
    }
}
