import Foundation
import PDFKit

// The text-layer literal matcher every literal search mode calls per page:
// the shared preparation, the one literal matcher, the per-line boxes and the
// case-preserved display of each match.
extension DocumentSearcher {

    // MARK: - Text Matching Core

    /// Every substring match in a page's text, as SearchResults (one per line
    /// a match touches).
    func findTextMatches(
        pageText: String,
        query: String,
        options: SearchOptions,
        page: PDFPage,
        pageIndex: Int,
        term: String
    ) -> [SearchResult] {
        // Per-page CJK detection disables the boundary check (see
        // `SearchCore.effectiveOptions`); the full tier detects, the preview
        // does not.
        let effectiveOptions = SearchCore.effectiveOptions(options, pageText: pageText, detectCJK: true)

        let normalizedQuery = SearchCore.normalizedText(query, options: effectiveOptions)
        guard !normalizedQuery.isEmpty else { return [] }

        // Recall extensions on top of the NFKC path (the shared
        // preparation). Smart punctuation is 1:1 (length-preserving), so rect
        // NSRanges stay in the normalized text's coordinates. Diacritic fold
        // and separator strip are length-changing: matching runs on the
        // transformed text and every match range routes through the offset
        // map back to base coordinates BEFORE the rect is computed (Risk 1: a
        // wrong rect is a misplaced redaction).
        let prepared = SearchCore.preparePage(pageText, options: effectiveOptions)
        let searchPageText = prepared.searchText
        let searchQuery = SearchCore.preparedQuery(normalized: normalizedQuery, options: effectiveOptions)
        // The strip path can empty a query made of separators only.
        guard !searchQuery.isEmpty else { return [] }

        // Case-preserved analog of the base text, used only to
        // re-slice the DISPLAYED span (see `displaySlice`). Mirrors the
        // base chain minus the case fold: page text → (ligature/NFKC
        // normalize) → (smart punctuation).
        let displayBaseChars: [Character] = {
            var display = effectiveOptions.normalizeUnicode
                ? TextNormalizer.normalize(pageText)
                : pageText
            if effectiveOptions.normalizeSmartPunctuation {
                display = TextNormalizer.normalizeSmartPunctuation(display)
            }
            return Array(TextNormalizer.foldWhitespaceRuns(display))
        }()
        let displayBaseText = String(displayBaseChars)

        var results: [SearchResult] = []

        let (spans, _) = SearchCore.literalSpans(
            in: prepared, query: searchQuery, comparison: [],
            wholeWord: effectiveOptions.wholeWord,
            cap: nil
        )
        for span in spans {
            // Offsets on the searched (most-transformed) text, and the base span.
            let matchStartOffset = span.searchedCharacters.lowerBound
            let matchLength = span.searchedCharacters.count
            let (baseStartOffset, baseLength) = span.baseOffsets
            // The rect's range on the RAW page text.
            guard let nsRange = prepared.rawNSRange(of: span) else { continue }
            if let rects = textLayerLines(for: nsRange, page: page) {
                // Display span re-slices from the case-preserved
                // analog at the already-mapped base offsets; matching stays
                // on the normalized text. The
                // norm-drift trap is guarded inside `displaySlice`,
                // which falls back to the normalized slice on drift.
                let normalizedSlice = String(searchPageText[span.searchedIndices])
                let matchedText = Self.displaySlice(
                    start: baseStartOffset, length: baseLength,
                    offsetMap: nil,
                    displayChars: displayBaseChars,
                    baseCount: prepared.baseText.count,
                    fallback: normalizedSlice)
                // The context window is built over the
                // same case-preserved analog `displaySlice` re-sliced from,
                // at the base span, so its match slice IS `matchedText`; on
                // display drift (the `displaySlice` fallback) it comes from
                // the searched text at the searched offsets instead.
                let window = displayWindow(
                    displayChars: displayBaseChars, displayText: displayBaseText,
                    baseCount: prepared.baseText.count,
                    start: baseStartOffset, length: baseLength, offsetMap: nil,
                    searchedText: searchPageText, searchedStart: matchStartOffset, searchedLength: matchLength
                )

                // One result per line the match touches (the counting rule).
                let occurrence = rects.count > 1 ? UUID() : nil
                for line in rects {
                    results.append(SearchResult(
                        pageIndex: pageIndex,
                        normalizedRect: line.rect,
                        matchedText: matchedText,
                        contextSnippet: window.snippet,
                        source: .textLayer,
                        term: term,
                        matchRangeInSnippet: window.matchRange,
                        occurrenceID: occurrence, textLayerRect: line.textLayerRect, inkFitDegraded: line.degraded
                    ))
                }
            }
        }

        return results
    }
}
