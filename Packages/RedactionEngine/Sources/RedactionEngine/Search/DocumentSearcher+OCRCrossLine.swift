import Foundation
import OSLog
import PDFKit

// A literal phrase on a scanned page that runs from the end of one recognised
// line into the next ("Jane" ending one line, "Doe" starting the next). The
// per-line matcher (`searchPageViaOCR`) searches each Vision observation on
// its own, so it cannot see such a phrase. This pass searches the page's
// lines joined in reading order, one line feed between them, through the
// literal tier's own preparation, where a line feed folds as on a text-layer
// page (to a space, or to nothing after a word's own hyphen). Two lines join only when the next one lies below the
// previous one and their spans across the page overlap: lines of different
// columns never overlap and are kept apart by a character no query holds,
// while an indented first line, a centred line or a short last line joins. It keeps only the matches that cross a line; a match
// inside one line is the per-line matcher's, unchanged. Each crossing match
// is boxed on every line it touches (the counting rule of a wrapped
// text-layer match): one result per line, one shared occurrence. Each line's
// box is the words its part of the match covers (Vision's word boxes,
// `OCREngine.TextLine.wordBoxes`), padded as every OCR box is, never the whole
// line; a line whose words have no box falls back to the line's box, and the
// count of such lines is logged. The Search Re-check re-runs this searcher on
// the output, so a crossing instance left printed reads as found there too.
private let crossLineLogger = Logger(subsystem: "com.resecta.app", category: "search")

extension DocumentSearcher {

    /// Whether a phrase may run from the end of `line` into the start of `next`:
    /// `next` lies below `line` and the two lines' spans across the page
    /// overlap (one column).
    nonisolated static func linesJoin(_ line: CGRect, _ next: CGRect) -> Bool {
        next.midY < line.midY && next.minX < line.maxX && line.minX < next.maxX
    }

    /// The box of the part `local` (UTF-16, in the line's text) of a match on
    /// `line`: the union of the words it overlaps, or nil when no word has a box.
    nonisolated static func matchedWordsRect(_ line: OCREngine.TextLine, local: NSRange) -> CGRect? {
        let boxes = line.wordBoxes.filter { NSIntersectionRange($0.range, local).length > 0 }.map(\.normalizedRect)
        guard let first = boxes.first else { return nil }
        return boxes.dropFirst().reduce(first) { $0.union($1) }
    }

    func crossLineOCRMatches(
        lines: [OCREngine.TextLine], query: String, options: SearchOptions,
        page: PDFPage, pageIndex: Int, term: String
    ) -> [SearchResult] {
        guard lines.count > 1 else { return [] }
        let lineTexts = lines.map { ocrNormalizer.normalize($0.text) }
        // Each line's span in the joined text, in UTF-16 units; a line that
        // does not join the next is followed by U+FFFC, which no query holds.
        var joined = ""
        var spans: [Range<Int>] = []
        var cursor = 0
        for (index, text) in lineTexts.enumerated() {
            let length = (text as NSString).length
            spans.append(cursor..<(cursor + length))
            joined += text
            guard index + 1 < lineTexts.count else { break }
            let separator = Self.linesJoin(lines[index].normalizedRect, lines[index + 1].normalizedRect) ? "\n" : "\n\u{FFFC}\n"
            joined += separator
            cursor += length + (separator as NSString).length
        }
        let effective = SearchCore.effectiveOptions(options, pageText: joined, detectCJK: true)
        let normalizedQuery = SearchCore.normalizedText(query, options: effective)
        guard !normalizedQuery.isEmpty else { return [] }
        let prepared = SearchCore.preparePage(joined, options: effective)
        let searchQuery = SearchCore.preparedQuery(normalized: normalizedQuery, options: effective)
        guard !searchQuery.isEmpty else { return [] }
        let (matches, _) = SearchCore.literalSpans(
            in: prepared, query: searchQuery, comparison: [], wholeWord: effective.wholeWord, cap: nil)
        let text = joined as NSString
        var results: [SearchResult] = []
        var lineFallbacks = 0
        for match in matches {
            guard let raw = prepared.rawNSRange(of: match) else { continue }
            let touched = spans.indices.filter { spans[$0].lowerBound < NSMaxRange(raw) && spans[$0].upperBound > raw.location }
            guard touched.count > 1 else { continue }
            let matchedText = TextNormalizer.foldWhitespaceRuns(text.substring(with: raw))
            let window = contextSnippet(text: joined, matchNSRange: raw)
            let occurrence = UUID()
            for index in touched {
                let lower = max(raw.location, spans[index].lowerBound), upper = min(NSMaxRange(raw), spans[index].upperBound)
                let local = NSRange(location: lower - spans[index].lowerBound, length: upper - lower)
                let words = Self.matchedWordsRect(lines[index], local: local)
                if words == nil { lineFallbacks += 1 }
                results.append(SearchResult(
                    pageIndex: pageIndex,
                    normalizedRect: Self.paddedNormalizedRect(words ?? lines[index].normalizedRect, in: page),
                    matchedText: matchedText,
                    contextSnippet: window.snippet,
                    source: .ocr(confidence: lines[index].confidence),
                    term: term,
                    matchRangeInSnippet: window.matchRange,
                    occurrenceID: occurrence))
            }
        }
        if lineFallbacks > 0 {
            crossLineLogger.log("cross-line OCR match: \(lineFallbacks, privacy: .public) line part(s) boxed by the whole line (no word box)")
        }
        return results
    }
}
