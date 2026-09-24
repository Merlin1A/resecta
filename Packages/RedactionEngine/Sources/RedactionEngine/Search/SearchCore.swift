import Foundation
import NaturalLanguage

/// The one matching core for the live-preview and full-search tiers.
///
/// The tiers differ in OUTPUT — counts and visible-page ranges on one side,
/// `SearchResult`s with a bounding rect and a context snippet on the other —
/// never in matching. The page-side normalization, the regex enumeration
/// with its cancellation / cap / timeout head, the literal cursor walk with
/// the offset-map remap and the whole-word check live here as pure,
/// synchronous, `nonisolated` functions; each tier shapes the spans it is
/// handed. Nothing here touches actor state, so no call adds a suspension.
enum SearchCore {

    // MARK: - Text-layer routing

    /// Whether a page's import-time classification permits the text-layer
    /// path. `.rich` (or unknown — a page absent from the status map,
    /// including the default `[:]`) stays on the text layer; `.sparse` /
    /// `.none` do not, so a header-only layer over a scanned body cannot
    /// stand in for the body text. See `TextLayerStatus`.
    static func textLayerIsSearchable(_ status: TextLayerStatus?) -> Bool {
        // Unwrap first: a page absent from the map (nil → unknown) takes the
        // text-layer path. Switching the Optional directly would bind a bare
        // `.none` to `Optional.none` rather than `TextLayerStatus.none`.
        guard let status else { return true }
        switch status {
        case .rich: return true
        case .sparse, .none: return false
        }
    }

    // MARK: - Normalization shared by both tiers

    /// The case / Unicode normalization both tiers apply to a page and to a
    /// query before matching: NFKC + ligature expansion (+ case fold unless
    /// case-sensitive) when `normalizeUnicode` is on, the plain case fold
    /// otherwise, the text unchanged when case-sensitive without NFKC.
    static func normalizedText(_ text: String, options: SearchOptions) -> String {
        if options.normalizeUnicode {
            return TextNormalizer.normalizeForSearch(text, caseSensitive: options.caseSensitive)
        } else if !options.caseSensitive {
            return text.lowercased()
        }
        return text
    }

    /// The full tier's per-page CJK detection: on a page whose dominant
    /// language is CJK the whole-word / exact-match boundary check is
    /// disabled (CJK runs lack the alphanumeric run-boundaries the predicate
    /// relies on, so it would add no signal). Per-page, because a
    /// multilingual document can change language across pages;
    /// `NLLanguageRecognizer` on 500 chars is sub-millisecond. The preview
    /// passes `detectCJK: false` — it never detected CJK and must not start.
    static func effectiveOptions(
        _ options: SearchOptions, pageText: String, detectCJK: Bool
    ) -> SearchOptions {
        guard detectCJK else { return options }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(pageText.prefix(500)))
        let cjkLanguages: Set<NLLanguage> = [
            .japanese, .korean, .simplifiedChinese, .traditionalChinese
        ]
        let isCJK = recognizer.dominantLanguage.map { cjkLanguages.contains($0) } ?? false
        var effective = options
        if isCJK {
            effective.wholeWord = false
            effective.exactMatch = false
        }
        return effective
    }

    /// The page-side text the regex tiers enumerate over: NFKC when
    /// `normalizeUnicode` is on, then the 1:1 (UTF-16 length-preserving)
    /// smart-punctuation fold, so emitted NSRanges stay valid on the page.
    /// The pattern itself is never transformed, and the length-changing
    /// extensions are excluded from the regex paths; see `SearchOptions`.
    static func regexSearchText(_ pageText: String, options: SearchOptions) -> String {
        var searchText: String
        if options.normalizeUnicode {
            searchText = TextNormalizer.normalize(pageText)
        } else {
            searchText = pageText
        }
        if options.normalizeSmartPunctuation {
            searchText = TextNormalizer.normalizeSmartPunctuation(searchText)
        }
        return searchText
    }

    // MARK: - The literal tier's prepared page

    /// A page after the literal tier's normalization and the recall
    /// extensions: `searchText` is the most-transformed text the cursor walks,
    /// `baseText` the pre-fold/strip text rect NSRanges are expressed in, and
    /// `offsetMap` routes searched Character offsets back to base coordinates
    /// (nil when every applied step was 1:1). `baseChars` is materialized once
    /// per page for the O(1) base-coordinate boundary check, only when a map
    /// is active.
    struct PreparedPage {
        let searchText: String
        let nsString: NSString
        let baseText: String
        let offsetMap: [Int]?
        let baseChars: [Character]?
    }

    /// The literal tier's page preparation: `normalizedText` then the
    /// extension pipeline (`TextNormalizer.applySearchExtensions`) on the page
    /// side. The page and query transforms of that pipeline are independent,
    /// so preparing them apart yields the pair a single call would.
    static func preparePage(_ pageText: String, options: SearchOptions) -> PreparedPage {
        let ext = TextNormalizer.applySearchExtensions(
            pageText: normalizedText(pageText, options: options),
            query: "",
            options: options
        )
        return PreparedPage(
            searchText: ext.pageText,
            nsString: ext.pageText as NSString,
            baseText: ext.baseText,
            offsetMap: ext.offsetMap,
            baseChars: ext.offsetMap != nil ? Array(ext.baseText) : nil
        )
    }

    /// The literal tier's query preparation: the extension pipeline on the
    /// query side of an ALREADY normalized query (`normalizedText`). The strip
    /// path can empty a query made of separators only; callers refuse an
    /// empty result before walking a page.
    static func preparedQuery(normalized query: String, options: SearchOptions) -> String {
        TextNormalizer.applySearchExtensions(pageText: "", query: query, options: options).query
    }

    // MARK: - Spans

    /// One literal match in a prepared page, in every coordinate space a tier
    /// reads: the searched text's UTF-16 range (what the NSString search
    /// returned), its `String.Index` bounds, its Character offsets, and the
    /// base-coordinate span the offset map routes it to (nil when no map is
    /// active — the searched offsets ARE the base offsets then, and each tier
    /// keeps its own convention for which of them it emits).
    struct MatchSpan: Equatable, Sendable {
        let searchedRange: NSRange
        let searchedIndices: Range<String.Index>
        let searchedCharacters: Range<Int>
        let base: Range<Int>?
    }

    // MARK: - The literal matcher

    /// The one literal cursor walk. Locates `query` in `page.searchText` with
    /// `comparison` (the preview passes `.literal`, the full tier the
    /// composed-character-sequence default — both are the same NSString
    /// search; the comparison is a parameter so neither tier's count moves),
    /// remaps every match through the offset map when one is active (a span
    /// the map cannot cover is refused rather than risk a bad rect), applies
    /// the whole-word check — in base coordinates under a map, since the
    /// searched text has no separators left; on the searched text otherwise —
    /// and stops after `cap` accepted spans (nil = unbounded). Character
    /// offsets are measured incrementally along the page (distances along one
    /// string are additive), so a dense page costs one walk, not one per match.
    static func literalSpans(
        in page: PreparedPage,
        query: String,
        comparison: String.CompareOptions,
        wholeWord: Bool,
        cap: Int?
    ) -> (spans: [MatchSpan], stoppedAtCap: Bool) {
        var spans: [MatchSpan] = []
        let text = page.searchText
        let nsString = page.nsString
        let nsLength = nsString.length
        var cursor = 0
        var measuredIndex = text.startIndex
        var measuredOffset = 0

        while cursor < nsLength {
            if Task.isCancelled { break }
            let searchRange = NSRange(location: cursor, length: nsLength - cursor)
            let matchRange = nsString.range(of: query, options: comparison, range: searchRange, locale: nil)
            if matchRange.location == NSNotFound { break }
            // A well-formed query never matches off a scalar boundary; a range
            // that still fails to convert ends the walk (the full tier's
            // `String.range(of:)` returned nil in exactly that case).
            guard let indices = Range(matchRange, in: text) else { break }
            let advance = matchRange.location + max(matchRange.length, 1)

            let start = measuredOffset + text.distance(from: measuredIndex, to: indices.lowerBound)
            let length = text.distance(from: indices.lowerBound, to: indices.upperBound)
            measuredIndex = indices.lowerBound
            measuredOffset = start

            // Map back to base coordinates when a length-changing extension is
            // active. The base span ends AFTER the last matched character's
            // base position, so a match spanning removed separators covers
            // them in the rect. A span the map cannot cover is structurally
            // unreachable (the map covers every searched char); the match is
            // refused rather than risk a bad rect.
            var base: Range<Int>? = nil
            if let map = page.offsetMap {
                guard let span = baseSpan(start: start, length: length, offsetMap: map) else {
                    cursor = advance
                    continue
                }
                base = span
            }

            // Whole-word check: verify word boundaries around the match. With
            // an offset map active the predicate evaluates in base coordinates
            // (separators are gone from the searched text, so boundaries are
            // only meaningful there).
            if wholeWord {
                let isBoundaried: Bool
                if let baseChars = page.baseChars, let base {
                    isBoundaried = isWholeWordInBase(
                        chars: baseChars, start: base.lowerBound, endExclusive: base.upperBound
                    )
                } else {
                    isBoundaried = isWholeWord(indices, in: text)
                }
                if !isBoundaried {
                    cursor = advance
                    continue
                }
            }

            spans.append(MatchSpan(
                searchedRange: matchRange,
                searchedIndices: indices,
                searchedCharacters: start ..< start + length,
                base: base
            ))
            if let cap, spans.count >= cap { return (spans, true) }
            cursor = advance
        }

        return (spans, false)
    }

    // MARK: - The regex enumeration

    /// The one regex enumeration. Walks `searchText` with `.reportProgress`
    /// (the closure fires periodically during a long match attempt, so the
    /// timeout / cancellation check actually samples; catastrophic
    /// backtracking inside a single attempt still blocks the synchronous C
    /// call — `validateRegexPattern` remains the primary defense), stops on
    /// cancellation, when `cap` matches have been ACCEPTED (nil = unbounded)
    /// or when `timeout` has elapsed since `startTime` (firing `onTimeout`
    /// first), skips matches that fail the whole-word check, and hands every
    /// surviving range to `visit`, which returns whether it counted toward
    /// the cap (the full tier counts only the results it could place).
    /// `unconvertibleRangePasses` keeps each tier's handling of a match range
    /// that does not convert to `Range<String.Index>` under the whole-word
    /// check: the preview counted it, the full tiers skipped it.
    @discardableResult
    static func enumerateRegexMatches(
        in searchText: String,
        regex: NSRegularExpression,
        wholeWord: Bool,
        unconvertibleRangePasses: Bool,
        cap: Int?,
        timeout: Duration,
        startTime: ContinuousClock.Instant,
        onTimeout: () -> Void,
        visit: (NSRange) -> Bool
    ) -> (accepted: Int, stoppedAtCap: Bool) {
        var accepted = 0
        var stoppedAtCap = false
        let nsString = searchText as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)

        regex.enumerateMatches(
            in: searchText,
            options: [.reportProgress],
            range: fullRange
        ) { match, _, stop in
            let capReached = cap.map { accepted >= $0 } ?? false
            if Task.isCancelled || capReached {
                if capReached { stoppedAtCap = true }
                stop.pointee = true
                return
            }
            if ContinuousClock.now - startTime > timeout {
                onTimeout()
                stop.pointee = true
                return
            }
            guard let match, match.range.location != NSNotFound else { return }

            if wholeWord {
                if let swiftRange = Range(match.range, in: searchText) {
                    if !isWholeWord(swiftRange, in: searchText) { return }
                } else if !unconvertibleRangePasses {
                    return
                }
            }

            if visit(match.range) { accepted += 1 }
        }

        return (accepted, stoppedAtCap)
    }

    // MARK: - Offset-map remap

    /// The base-coordinate span of a match measured on the searched
    /// (most-transformed) text: `offsetMap` routes it to base coordinates
    /// when a length-changing extension is active, ending AFTER the last
    /// matched character's base position; nil when the map cannot cover
    /// the span. The one remap for the preview, the OCR literal path and
    /// `findTextMatches`, and the span `displaySlice` re-slices under the
    /// same bound guards, so the context-window builder and the display
    /// slice agree on when the fallback is taken.
    static func baseSpan(start: Int, length: Int, offsetMap: [Int]?) -> Range<Int>? {
        guard length > 0, start >= 0 else { return nil }
        if let map = offsetMap {
            guard start < map.count, start + length - 1 < map.count else { return nil }
            return map[start] ..< (map[start + length - 1] + 1)
        }
        return start ..< start + length
    }

    // MARK: - Whole-word predicates

    /// Word-boundary predicate in base-text coordinates, used when a
    /// length-changing normalization (offset map) is active. Mirrors
    /// `isWholeWord`'s alphanumeric/underscore rule.
    static func isWholeWordInBase(
        chars: [Character], start: Int, endExclusive: Int
    ) -> Bool {
        if start > 0 {
            let c = chars[start - 1]
            if c.isLetter || c.isNumber || c == "_" { return false }
        }
        if endExclusive < chars.count {
            let c = chars[endExclusive]
            if c.isLetter || c.isNumber || c == "_" { return false }
        }
        return true
    }

    /// Check if the match range is surrounded by word boundaries. The one
    /// String-index predicate for the preview and full tiers; the
    /// base-coordinate `isWholeWordInBase` covers the offset-map case.
    static func isWholeWord(_ range: Range<String.Index>, in text: String) -> Bool {
        if range.lowerBound > text.startIndex {
            let charBefore = text[text.index(before: range.lowerBound)]
            if charBefore.isLetter || charBefore.isNumber || charBefore == "_" {
                return false
            }
        }
        if range.upperBound < text.endIndex {
            let charAfter = text[range.upperBound]
            if charAfter.isLetter || charAfter.isNumber || charAfter == "_" {
                return false
            }
        }
        return true
    }
}
