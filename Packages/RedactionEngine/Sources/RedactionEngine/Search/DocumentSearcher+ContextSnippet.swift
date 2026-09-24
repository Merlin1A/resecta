import Foundation

// The display shaping every SearchResult builder path shares: the case-preserved
// display slice and the one context window per match. Moved whole from
// DocumentSearcher.swift; no line inside a moved body changes.

extension DocumentSearcher {

    /// Re-slice the DISPLAYED match span from the case-preserved
    /// analog of the base text, so a match on "Hartwell" displays as
    /// "Hartwell" rather than the case-folded "hartwell". Matching still
    /// runs on the normalized text; this touches only the display slice.
    /// `start`/`length` are Character offsets in the searched
    /// (most-transformed) text; `offsetMap` routes them to base
    /// coordinates when a length-changing extension is active (pass nil
    /// when the offsets are already base coordinates). Returns `fallback`
    /// (the normalized slice — today's behavior) whenever the
    /// case-preserved analog drifted from the base Character count: the
    /// norm-drift trap this guard
    /// exists for.
    static func displaySlice(
        start: Int, length: Int, offsetMap: [Int]?,
        displayChars: [Character], baseCount: Int, fallback: String
    ) -> String {
        guard displayChars.count == baseCount, length > 0 else { return fallback }
        let baseStart: Int
        let baseEndExclusive: Int
        if let map = offsetMap {
            guard start >= 0, start < map.count, start + length - 1 < map.count else {
                return fallback
            }
            baseStart = map[start]
            baseEndExclusive = map[start + length - 1] + 1
        } else {
            baseStart = start
            baseEndExclusive = start + length
        }
        guard baseStart >= 0, baseStart < baseEndExclusive,
              baseEndExclusive <= displayChars.count else {
            return fallback
        }
        return String(displayChars[baseStart..<baseEndExclusive])
    }

    // MARK: - Context Snippet

    /// One context window per match: the snippet
    /// text plus the match's position inside it, in Character offsets
    /// (a leading `…` counts as one). Every `SearchResult` builder path
    /// routes through `contextSnippet` so the row can highlight the
    /// match without re-searching.
    struct ContextWindow: Equatable, Sendable {
        let snippet: String
        let matchRange: Range<Int>
    }

    /// Characters of context kept on each side of the match before a
    /// cut side is trimmed back to a word boundary.
    static let contextRadius = 44

    /// Build the context window around the match. `matchStart` and
    /// `matchLength` are Character offsets (not UTF-16).
    ///
    /// Shape: `contextRadius` characters each side of the match; a side
    /// that cut the text mid-word is trimmed back to the nearest word
    /// boundary (a whitespace/punctuation run) so the window never
    /// starts or ends inside a word — except that the trim never moves
    /// into the match itself: when the partial word adjoins the match,
    /// that side keeps the raw cut. `…` is prepended/appended only on a
    /// side where text was cut. Newlines outside the match flatten to
    /// spaces LAST, one Character each, so the returned offsets stay
    /// valid; the match span itself is copied verbatim so the window
    /// always contains `matchedText`.
    func contextSnippet(text: String, matchStart: Int, matchLength: Int) -> ContextWindow {
        let textCount = text.count
        let clampedStart = min(max(0, matchStart), textCount)
        let clampedLength = min(max(0, matchLength), textCount - clampedStart)
        let matchEnd = clampedStart + clampedLength

        let rawStart = max(0, clampedStart - Self.contextRadius)
        let rawEnd = min(textCount, matchEnd + Self.contextRadius)
        let leftCut = rawStart > 0
        let rightCut = rawEnd < textCount

        let matchStartIdx = text.index(text.startIndex, offsetBy: clampedStart)
        let matchEndIdx = text.index(matchStartIdx, offsetBy: clampedLength)
        var startIdx = text.index(matchStartIdx, offsetBy: rawStart - clampedStart)
        var endIdx = text.index(matchEndIdx, offsetBy: rawEnd - matchEnd)

        if leftCut {
            startIdx = Self.trimmedWindowStart(
                in: text, rawStart: startIdx, matchStart: matchStartIdx
            )
        }
        if rightCut {
            endIdx = Self.trimmedWindowEnd(
                in: text, rawEnd: endIdx, matchEnd: matchEndIdx
            )
        }

        let leading = leftCut ? "…" : ""
        let trailing = rightCut ? "…" : ""
        let matchOffset = leading.count + text.distance(from: startIdx, to: matchStartIdx)
        // Flatten LAST and only OUTSIDE the match, Character for Character
        // (a "\r\n" grapheme is one Character before and after), so
        // `matchOffset` stays valid and the window contains the match
        // verbatim — a match that spans a line break keeps its break.
        func flattened(_ part: Substring) -> String {
            String(part.map { ch -> Character in ch.isNewline ? " " : ch })
        }
        let snippet = leading
            + flattened(text[startIdx..<matchStartIdx])
            + String(text[matchStartIdx..<matchEndIdx])
            + flattened(text[matchEndIdx..<endIdx])
            + trailing
        return ContextWindow(
            snippet: snippet,
            matchRange: matchOffset ..< matchOffset + clampedLength
        )
    }

    /// NSRange-safe overload: converts UTF-16 range to Character offsets
    /// before building the window. Use this when the range comes from
    /// NSRegularExpression or PIIDetector (both use NSRange/UTF-16). An
    /// unmappable range yields an empty window.
    func contextSnippet(text: String, matchNSRange: NSRange) -> ContextWindow {
        guard let range = Range(matchNSRange, in: text) else {
            return ContextWindow(snippet: "", matchRange: 0..<0)
        }
        let charStart = text.distance(from: text.startIndex, to: range.lowerBound)
        let charLength = text.distance(from: range.lowerBound, to: range.upperBound)
        return contextSnippet(text: text, matchStart: charStart, matchLength: charLength)
    }

    /// The context window over the case-preserved display analog at the
    /// base span `displaySlice` re-sliced from (so the window's match
    /// slice IS the displayed text), or — when the analog drifted from the
    /// base Character count, the `displaySlice` fallback — over the
    /// searched text at the searched offsets, matching that fallback slice
    /// instead. The one pairing for the OCR literal path and
    /// `findTextMatches`.
    func displayWindow(
        displayChars: [Character], displayText: String, baseCount: Int,
        start: Int, length: Int, offsetMap: [Int]?,
        searchedText: String, searchedStart: Int, searchedLength: Int
    ) -> ContextWindow {
        if displayChars.count == baseCount,
           let span = SearchCore.baseSpan(start: start, length: length, offsetMap: offsetMap),
           span.upperBound <= displayChars.count {
            return contextSnippet(text: displayText, matchStart: span.lowerBound, matchLength: span.count)
        }
        return contextSnippet(text: searchedText, matchStart: searchedStart, matchLength: searchedLength)
    }

    /// Word character for the window trim: letters and digits; every
    /// other Character (whitespace, punctuation, symbols) is a boundary.
    private static func isWordCharacter(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber
    }

    /// Left-side trim. Moves the window start forward past a partial
    /// word and the separator run after it, stopping at the match: when
    /// the partial word runs straight into the match there is no
    /// boundary to trim to, and the raw cut stands.
    private static func trimmedWindowStart(
        in text: String, rawStart: String.Index, matchStart: String.Index
    ) -> String.Index {
        var cursor = rawStart
        let before = text.index(before: rawStart)
        if cursor < matchStart, isWordCharacter(text[before]), isWordCharacter(text[cursor]) {
            while cursor < matchStart, isWordCharacter(text[cursor]) {
                cursor = text.index(after: cursor)
            }
            if cursor == matchStart { return rawStart }
        }
        while cursor < matchStart, !isWordCharacter(text[cursor]) {
            cursor = text.index(after: cursor)
        }
        return cursor
    }

    /// Right-side trim, the mirror of `trimmedWindowStart`: moves the
    /// window end back over a partial word and the separator run before
    /// it, never past the match end.
    private static func trimmedWindowEnd(
        in text: String, rawEnd: String.Index, matchEnd: String.Index
    ) -> String.Index {
        var cursor = rawEnd
        if cursor > matchEnd,
           isWordCharacter(text[text.index(before: cursor)]),
           isWordCharacter(text[rawEnd]) {
            while cursor > matchEnd, isWordCharacter(text[text.index(before: cursor)]) {
                cursor = text.index(before: cursor)
            }
            if cursor == matchEnd { return rawEnd }
        }
        while cursor > matchEnd, !isWordCharacter(text[text.index(before: cursor)]) {
            cursor = text.index(before: cursor)
        }
        return cursor
    }
}
