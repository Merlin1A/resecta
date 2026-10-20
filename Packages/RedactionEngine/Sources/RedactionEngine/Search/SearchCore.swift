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

    /// The page-side text the regex tiers enumerate over (`regexPage`'s
    /// text): NFKC when `normalizeUnicode` is on, then the smart-punctuation
    /// fold. The pattern itself is never transformed, and the length-changing
    /// extensions are excluded from the regex paths; see `SearchOptions`.
    static func regexSearchText(_ pageText: String, options: SearchOptions) -> String {
        regexPage(pageText, options: options).text
    }

    /// The regex tiers' page with its route back to the raw page text. NFKC
    /// is not UTF-16 length-preserving (a ligature expands, a compatibility
    /// character or a decomposed accent contracts), so a match range in the
    /// normalized text is not a range on the raw page: `rawNSRange` maps it
    /// unit by unit. A page of single-unit ASCII is normalized whole with no
    /// map (every step is the identity on it).
    struct RegexPage {
        let text: String
        /// Per UTF-16 unit of `text`: the raw Character it came from; nil
        /// when `text`'s units are the raw page's.
        let rawCharacterOfUnit: [Int]?
        /// `rawUTF16Offsets[i]` is the UTF-16 offset of raw Character i;
        /// one entry more than the raw Character count (the end).
        let rawUTF16Offsets: [Int]

        /// The raw page range of a match range in `text`; nil when the map
        /// cannot cover it (a match the caller refuses rather than risk a
        /// bad rect).
        func rawNSRange(_ range: NSRange) -> NSRange? {
            guard let rawCharacterOfUnit else { return range.length > 0 ? range : nil }
            guard range.length > 0, range.location >= 0,
                  range.location + range.length - 1 < rawCharacterOfUnit.count else { return nil }
            let first = rawCharacterOfUnit[range.location]
            let last = rawCharacterOfUnit[range.location + range.length - 1]
            let location = rawUTF16Offsets[first]
            return NSRange(location: location, length: rawUTF16Offsets[last + 1] - location)
        }
    }

    static func regexPage(_ pageText: String, options: SearchOptions) -> RegexPage {
        if isSingleUnitASCII(pageText) {
            return RegexPage(text: pageText, rawCharacterOfUnit: nil, rawUTF16Offsets: [])
        }
        var text = ""
        text.reserveCapacity(pageText.utf8.count)
        var units: [Int] = []
        units.reserveCapacity(pageText.utf16.count)
        var utf16: [Int] = [0]
        utf16.reserveCapacity(pageText.count + 1)
        for (i, character) in pageText.enumerated() {
            var piece = String(character)
            if options.normalizeUnicode { piece = TextNormalizer.normalize(piece) }
            if options.normalizeSmartPunctuation { piece = TextNormalizer.normalizeSmartPunctuation(piece) }
            text.append(piece)
            units.append(contentsOf: repeatElement(i, count: piece.utf16.count))
            utf16.append(utf16[utf16.count - 1] + character.utf16.count)
        }
        return RegexPage(text: text, rawCharacterOfUnit: units, rawUTF16Offsets: utf16)
    }

    /// A page on which Character offsets ARE UTF-16 offsets and no
    /// normalization step changes a length: every scalar ASCII (one unit
    /// each) and no CR LF cluster (one Character, two units).
    static func isSingleUnitASCII(_ text: String) -> Bool {
        text.utf8.count == text.utf16.count && text.count == text.utf16.count
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
        let rawMap: RawTextMap?

        /// The `NSRange` in the RAW page text (`page.string`) of a base span:
        /// through `rawMap` on every page that has one (every page that is
        /// not single-unit ASCII), the base offsets themselves otherwise —
        /// they ARE UTF-16 offsets on such a page; nil when the map cannot
        /// cover the span (a match the caller refuses rather than risk a bad
        /// rect — the rule the offset map already applies).
        func rawNSRange(baseStart: Int, length: Int) -> NSRange? {
            guard let rawMap else { return NSRange(location: baseStart, length: length) }
            return rawMap.nsRange(baseStart: baseStart, length: length)
        }
    }

    /// The route from the normalized page back to the raw page text, built
    /// for every page that is not single-unit ASCII: for each normalized
    /// Character the first and the last raw Character it came from (the
    /// same one, except where a cluster re-forms across a raw boundary), and
    /// the raw text's UTF-16 offsets per Character. Without it a ligature
    /// expansion before a match shifts its rect by as many characters as the
    /// expansion added, and a Character wider than one UTF-16 unit (an
    /// emoji, a surrogate pair, a base letter with a combining mark) shifts
    /// and shortens it by the extra units.
    struct RawTextMap: Sendable {
        /// One entry per normalized Character: the first raw Character index.
        let rawFirst: [Int]
        /// One entry per normalized Character: the last raw Character index.
        let rawLast: [Int]
        /// `rawUTF16Offsets[i]` is the UTF-16 offset of raw Character i;
        /// one entry more than the raw Character count (the end).
        let rawUTF16Offsets: [Int]

        func nsRange(baseStart: Int, length: Int) -> NSRange? {
            guard length > 0, baseStart >= 0,
                  baseStart + length - 1 < rawFirst.count else { return nil }
            let first = rawFirst[baseStart]
            let last = rawLast[baseStart + length - 1]
            let location = rawUTF16Offsets[first]
            return NSRange(location: location, length: rawUTF16Offsets[last + 1] - location)
        }
    }

    /// The page side of `normalizedText` (plus the smart-punctuation fold,
    /// which re-clusters at a soft hyphen before a combining mark and so
    /// belongs under the map) with its route back to the raw text. A page of
    /// single-unit ASCII is normalized whole and carries no map: its
    /// Character offsets are UTF-16 offsets and every step is 1:1 on it.
    /// Every other page is normalized one Character at a time — the searched
    /// text is the pieces joined, which differs from the whole-string
    /// normalization only where a cluster re-forms across a raw boundary (a
    /// compatibility jamo pair) — and the map is built from the pieces'
    /// scalars, so such a seam keeps one entry per final Character instead
    /// of desynchronizing the map or dropping it. A rect is never placed
    /// from unmapped offsets on a page that needs the map.
    static func normalizedPage(
        _ pageText: String, options: SearchOptions
    ) -> (text: String, rawMap: RawTextMap?) {
        if isSingleUnitASCII(pageText) {
            let whole = normalizedText(pageText, options: options)
            if whole.count == pageText.count, isSingleUnitASCII(whole) { return (whole, nil) }
        }
        var text = ""
        text.reserveCapacity(pageText.utf8.count)
        var scalarRaw: [Int] = []   // per scalar of `text`: the raw Character index
        scalarRaw.reserveCapacity(pageText.unicodeScalars.count)
        var utf16: [Int] = [0]
        utf16.reserveCapacity(pageText.count + 1)
        for (i, character) in pageText.enumerated() {
            var piece = normalizedText(String(character), options: options)
            if options.normalizeSmartPunctuation { piece = TextNormalizer.normalizeSmartPunctuation(piece) }
            text.append(piece)
            scalarRaw.append(contentsOf: repeatElement(i, count: piece.unicodeScalars.count))
            utf16.append(utf16[utf16.count - 1] + character.utf16.count)
        }
        // Appending never changes scalars, only Character boundaries: walk
        // the joined text's Characters over the per-scalar raw indices.
        var first: [Int] = []
        var last: [Int] = []
        first.reserveCapacity(text.count)
        last.reserveCapacity(text.count)
        var scalar = 0
        for character in text {
            let count = character.unicodeScalars.count
            first.append(scalarRaw[scalar])
            last.append(scalarRaw[scalar + count - 1])
            scalar += count
        }
        return (text, RawTextMap(rawFirst: first, rawLast: last, rawUTF16Offsets: utf16))
    }

    /// The literal tier's page preparation: `normalizedPage` then the
    /// extension pipeline (`TextNormalizer.applySearchExtensions`) on the page
    /// side — minus the smart-punctuation fold, which `normalizedPage`
    /// applied under the map (on a single-unit ASCII page it has nothing to
    /// fold). The page and query transforms of that pipeline are independent,
    /// so preparing them apart yields the pair a single call would.
    static func preparePage(_ pageText: String, options: SearchOptions) -> PreparedPage {
        let normalized = normalizedPage(pageText, options: options)
        var pageSide = options
        pageSide.normalizeSmartPunctuation = false
        let ext = TextNormalizer.applySearchExtensions(
            pageText: normalized.text,
            query: "",
            options: pageSide
        )
        return PreparedPage(
            searchText: ext.pageText,
            nsString: ext.pageText as NSString,
            baseText: ext.baseText,
            offsetMap: ext.offsetMap,
            baseChars: ext.offsetMap != nil ? Array(ext.baseText) : nil,
            rawMap: normalized.rawMap
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
