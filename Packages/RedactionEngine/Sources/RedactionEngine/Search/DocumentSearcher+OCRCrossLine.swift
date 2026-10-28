import Foundation
import OSLog
import PDFKit

// The OCR literal route's one matcher: every literal match on a scanned page
// (Text and Multi-term), within one recognised line or running from the end
// of one line into the next ("Jane" ending one line, "Doe" starting the
// next). It searches the page's recognised lines as Vision read them, joined
// in reading order, one line feed between them, through the literal tier's
// own preparation, where a line feed folds as on a text-layer
// page (to a space, or to nothing after a word's own hyphen). Two lines join only when the next one lies below the
// previous one and their spans across the page overlap: lines of different
// columns never overlap and are kept apart by a character no query holds,
// while an indented first line, a centred line or a short last line joins.
// Both sides of the match take the match skeleton (`OCRMatchSkeleton`): the
// confusable classes of Scan's normalizer, so a typed "Suite 100" matches a
// line read "Suite 1OO"; the lines through Scan's confusable correction are
// read too, as typed (a "1D" Vision read for "ID"), a range both readings
// hold kept once; accents fold on both sides, and the query's edge symbols
// are trimmed. A match is boxed on every line it touches (the
// counting rule of a wrapped text-layer match): one result per line, the
// lines of one match sharing one occurrence. Each line's box is the words
// its part of the match covers (Vision's word boxes,
// `OCREngine.TextLine.wordBoxes`), padded as every OCR box is, never the whole
// line; a line whose words have no box falls back to the line's box, and the
// count of such lines is logged. The displayed text is sliced from the
// recognised text itself, what the OCR Check reads. The Search Re-check
// re-runs this searcher on the output, so an instance left printed reads as
// found there too.
private let ocrLiteralLogger = Logger(subsystem: "com.resecta.app", category: "search")

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

    /// The two readings of a page's recognised lines: as Vision read them,
    /// and through Scan's confusable correction (`OCRTextNormalizer`). The
    /// correction keeps a line's UTF-16 length; a line where it would not
    /// reads raw in both, so one set of line offsets serves both readings and
    /// a range means the same place in either.
    func ocrReadings(_ lines: [OCREngine.TextLine]) -> (raw: [String], corrected: [String]) {
        let raw = lines.map(\.text)
        let corrected = lines.map { line -> String in
            let text = ocrNormalizer.normalize(line.text)
            return text.utf16.count == line.text.utf16.count ? text : line.text
        }
        return (raw, corrected)
    }

    func ocrLiteralMatches(
        lines: [OCREngine.TextLine], query: String, options: SearchOptions,
        page: PDFPage, pageIndex: Int, term: String
    ) -> [SearchResult] {
        guard !lines.isEmpty else { return [] }
        let (rawTexts, correctedTexts) = ocrReadings(lines)
        // Each line's span in the joined text, in UTF-16 units; a line that
        // does not join the next is followed by U+FFFC, which no query holds.
        var separators: [String] = []
        var spans: [Range<Int>] = []
        var cursor = 0
        for (index, text) in rawTexts.enumerated() {
            let length = (text as NSString).length
            spans.append(cursor..<(cursor + length))
            guard index + 1 < rawTexts.count else { break }
            let separator = Self.linesJoin(lines[index].normalizedRect, lines[index + 1].normalizedRect) ? "\n" : "\n\u{FFFC}\n"
            separators.append(separator)
            cursor += length + (separator as NSString).length
        }
        func joinedText(_ texts: [String]) -> String {
            zip(texts, separators + [""]).map { $0 + $1 }.joined()
        }
        let joined = joinedText(rawTexts)
        let effective = SearchCore.effectiveOptions(OCRMatchSkeleton.options(options), pageText: joined, detectCJK: true)
        let normalizedQuery = SearchCore.normalizedText(OCRMatchSkeleton.trimmedQuery(query), options: effective)
        guard !normalizedQuery.isEmpty else { return [] }
        // The raw reading matches on the skeleton (the typed digits against
        // the digits Vision read); the corrected reading matches as typed
        // (letters Vision read as digits, "1D" for "ID"). A range both
        // readings hold is kept once.
        func ranges(in text: String, skeleton: Bool) -> [NSRange] {
            let page = SearchCore.preparePage(text, options: effective)
            let prepared = skeleton ? OCRMatchSkeleton.skeleton(page) : page
            let typed = skeleton ? OCRMatchSkeleton.skeleton(normalizedQuery) : normalizedQuery
            let searchQuery = SearchCore.preparedQuery(normalized: typed, options: effective)
            guard !searchQuery.isEmpty else { return [] }
            return SearchCore.literalSpans(
                in: prepared, query: searchQuery, comparison: [], wholeWord: effective.wholeWord, cap: nil
            ).spans.compactMap { prepared.rawNSRange(of: $0) }
        }
        var seen = Set<NSRange>()
        let matches = (ranges(in: joined, skeleton: true) + ranges(in: joinedText(correctedTexts), skeleton: false))
            .filter { seen.insert($0).inserted }
            .sorted { $0.location < $1.location }
        let text = joined as NSString
        // The context reads the separator of two unjoined lines as a space.
        let shown = joined.replacingOccurrences(of: "\u{FFFC}", with: " ")
        var results: [SearchResult] = []
        var lineFallbacks = 0
        for raw in matches {
            let touched = spans.indices.filter { spans[$0].lowerBound < NSMaxRange(raw) && spans[$0].upperBound > raw.location }
            let matchedText = TextNormalizer.foldWhitespaceRuns(text.substring(with: raw))
            let window = contextSnippet(text: shown, matchNSRange: raw)
            let occurrence = touched.count > 1 ? UUID() : nil
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
            ocrLiteralLogger.log("OCR literal match: \(lineFallbacks, privacy: .public) line part(s) boxed by the whole line (no word box)")
        }
        return results
    }
}
