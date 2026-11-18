import Foundation

// A second reading of a page for the literal matcher. A typesetter breaks
// "Brightwater" as "Bright-" at a line end and "water" on the next line; the
// page as read keeps that hyphen (the break folds to nothing and the hyphen
// stays, `TextNormalizer.foldedRun`), so "Bright-water" is found and
// "Brightwater" is not. The rule:
//
// A hyphen that ends a line between two letters of the same case is read
// both ways: kept, as today, and dropped. A match found either way counts
// once and covers the hyphen. A hyphen between digits, between letters of
// different case, or beside a letter that has no case, is only ever kept.
//
// - Same case is judged on the page's own Characters, before any case fold.
// - The dropped reading drops every such hyphen on the page at once, so a
//   phrase holding two such breaks is found with both kept or both dropped.
// - Whole word is tested on the match's span in the page as read.
// - A pattern is never read this way; nor is a one-word search across a
//   page boundary (the page seam asks only for queries with a space or a
//   hyphen).
//
// Privacy rule (audit-lint M-1): locate/match/cover vocabulary.
extension SearchCore {

    /// Whether a run is a closed-spelling break: a line break right after a
    /// hard hyphen (`TextNormalizer.isBreakAfterHardHyphen`) whose letter
    /// before the hyphen and letter after the run are both lower case or both
    /// upper case, on the page's own Characters.
    static func isClosedSpellingBreak(
        _ run: Substring, previous: Character?, beforeThat: Character?, next: Character?
    ) -> Bool {
        guard TextNormalizer.isBreakAfterHardHyphen(run, previous: previous, beforeThat: beforeThat, next: next),
              let beforeThat, let next else { return false }
        return isSameCase(beforeThat, next)
    }

    /// Two letters that are both lower case or both upper case. A digit, or
    /// a letter with no case, is neither.
    static func isSameCase(_ a: Character, _ b: Character) -> Bool {
        (a.isLowercase && b.isLowercase) || (a.isUppercase && b.isUppercase)
    }

    /// The closed-spelling hyphens of a normalized page (Character offsets
    /// in it), expressed in the searched text: through the accent fold's
    /// offset map when one is active, none under the digit-separator strip
    /// (which has already removed every "-"). An offset that does not land
    /// on a hard hyphen of the searched text is not carried.
    static func closedSpellingHyphens(
        _ normalizedOffsets: [Int], searchText: String, offsetMap: [Int]?, options: SearchOptions
    ) -> [Int] {
        guard !normalizedOffsets.isEmpty, !options.stripDigitSeparators else { return [] }
        let searched: [Int]
        if let offsetMap {
            searched = normalizedOffsets.compactMap { offset in
                var low = 0, high = offsetMap.count
                while low < high {
                    let mid = (low + high) / 2
                    if offsetMap[mid] < offset { low = mid + 1 } else { high = mid }
                }
                return low < offsetMap.count && offsetMap[low] == offset ? low : nil
            }
        } else {
            searched = normalizedOffsets
        }
        let characters = Array(searchText)
        return searched.filter { $0 < characters.count && TextNormalizer.hardHyphens.contains(characters[$0]) }
    }

    /// The literal matcher: the walk over the page as read
    /// (`literalSpansAsRead`), and on a page with closed-spelling hyphens a
    /// second walk over the page with them dropped. A second-walk match is
    /// kept only when it crosses a dropped hyphen, and is expressed as a span
    /// of the searched text from its first matched Character to its last, so
    /// it covers the hyphen; one equal to a span of the first walk is
    /// dropped. The spans are returned in page order; with a cap, the first
    /// `cap` of the merged list, `stoppedAtCap` true when the list reached it.
    static func literalSpans(
        in page: PreparedPage,
        query: String,
        comparison: String.CompareOptions,
        wholeWord: Bool,
        cap: Int?
    ) -> (spans: [MatchSpan], stoppedAtCap: Bool) {
        let asRead = literalSpansAsRead(in: page, query: query, comparison: comparison, wholeWord: wholeWord, cap: cap)
        guard !page.closedSpellingHyphens.isEmpty else { return asRead }
        let closed = closedSpellingSpans(in: page, query: query, comparison: comparison, wholeWord: wholeWord, cap: cap)
        guard !closed.isEmpty else { return asRead }
        let seen = Set(asRead.spans.map { SpanKey($0.searchedRange) })
        var merged = asRead.spans + closed.filter { !seen.contains(SpanKey($0.searchedRange)) }
        merged.sort {
            ($0.searchedRange.location, $0.searchedRange.length) < ($1.searchedRange.location, $1.searchedRange.length)
        }
        guard let cap else { return (merged, false) }
        return merged.count >= cap ? (Array(merged.prefix(cap)), true) : (merged, false)
    }

    private struct SpanKey: Hashable {
        let location: Int
        let length: Int
        init(_ range: NSRange) { location = range.location; length = range.length }
    }

    /// The second walk: `query` over the searched text with every
    /// closed-spelling hyphen removed, each match routed back to the searched
    /// text, kept only when it crosses a removed hyphen, then remapped and
    /// checked for whole word exactly as the first walk does. At most `cap`
    /// spans (nil = unbounded).
    static func closedSpellingSpans(
        in page: PreparedPage,
        query: String,
        comparison: String.CompareOptions,
        wholeWord: Bool,
        cap: Int?
    ) -> [MatchSpan] {
        let text = page.searchText
        let dropped = Set(page.closedSpellingHyphens)
        var reading = ""
        reading.reserveCapacity(text.utf8.count)
        var searchedOffset: [Int] = []     // per Character of `reading`: its Character offset in `text`
        searchedOffset.reserveCapacity(text.count)
        for (offset, character) in text.enumerated() where !dropped.contains(offset) {
            reading.append(character)
            searchedOffset.append(offset)
        }
        // A Character that re-formed across a removed hyphen would shift the
        // route back; refuse the reading rather than risk a bad box.
        guard reading.count == searchedOffset.count else { return [] }

        var spans: [MatchSpan] = []
        let nsReading = reading as NSString
        let nsLength = nsReading.length
        var cursor = 0
        var readingIndex = reading.startIndex
        var readingOffset = 0
        var textIndex = text.startIndex
        var textOffset = 0

        while cursor < nsLength {
            if Task.isCancelled { break }
            let matchRange = nsReading.range(
                of: query, options: comparison, range: NSRange(location: cursor, length: nsLength - cursor), locale: nil)
            if matchRange.location == NSNotFound { break }
            guard let indices = Range(matchRange, in: reading) else { break }
            let advance = matchRange.location + max(matchRange.length, 1)

            let start = readingOffset + reading.distance(from: readingIndex, to: indices.lowerBound)
            let length = reading.distance(from: indices.lowerBound, to: indices.upperBound)
            readingIndex = indices.lowerBound
            readingOffset = start
            guard length > 0 else { cursor = advance; continue }

            let first = searchedOffset[start]
            let last = searchedOffset[start + length - 1]
            // Only a match across a removed hyphen is the dropped reading's
            // own; any other is the page as read, which the first walk owns.
            guard last - first + 1 > length, first >= textOffset else { cursor = advance; continue }

            let lower = text.index(textIndex, offsetBy: first - textOffset)
            let upper = text.index(lower, offsetBy: last - first + 1)
            textIndex = lower
            textOffset = first

            var base: Range<Int>? = nil
            if let map = page.offsetMap {
                guard let span = baseSpan(start: first, length: last - first + 1, offsetMap: map) else {
                    cursor = advance
                    continue
                }
                base = span
            }
            if wholeWord {
                let isBoundaried: Bool
                if let baseChars = page.baseChars, let base {
                    isBoundaried = isWholeWordInBase(chars: baseChars, start: base.lowerBound, endExclusive: base.upperBound)
                } else {
                    isBoundaried = isWholeWord(lower..<upper, in: text)
                }
                if !isBoundaried {
                    cursor = advance
                    continue
                }
            }

            spans.append(MatchSpan(
                searchedRange: NSRange(lower..<upper, in: text),
                searchedIndices: lower..<upper,
                searchedCharacters: first ..< last + 1,
                base: base
            ))
            if let cap, spans.count >= cap { break }
            cursor = advance
        }
        return spans
    }
}
