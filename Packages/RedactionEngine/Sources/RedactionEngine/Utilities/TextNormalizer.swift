import Foundation

// SEARCH-AND-REDACT §D5: Shared Unicode normalization for PDF text matching.
// Used by: search engine, verifier PII scan (Feature 2), audit metadata (Feature 1).

/// Unicode normalization for PDF text matching.
///
/// PDF text layers frequently contain typographic ligatures (fi, fl, ffi, etc.)
/// that must be decomposed before string matching. This normalizer applies
/// targeted ligature expansion followed by NFKC normalization.
public struct TextNormalizer: Sendable {

    /// Targeted ligature expansion + NFKC normalization.
    ///
    /// Expands the five common Latin ligatures that appear in PDF text layers,
    /// then applies NFKC for remaining compatibility decomposition.
    public static func normalize(_ text: String) -> String {
        var result = text
        // Targeted ligature decomposition — order matters (ffi/ffl before fi/fl/ff)
        result = result
            .replacingOccurrences(of: "\u{FB03}", with: "ffi")  // ffi ligature
            .replacingOccurrences(of: "\u{FB04}", with: "ffl")  // ffl ligature
            .replacingOccurrences(of: "\u{FB00}", with: "ff")   // ff ligature
            .replacingOccurrences(of: "\u{FB01}", with: "fi")   // fi ligature
            .replacingOccurrences(of: "\u{FB02}", with: "fl")   // fl ligature
        // NFKC for remaining normalization
        result = result.precomposedStringWithCompatibilityMapping
        return result
    }

    /// Normalize for search comparison: ligature expansion + NFKC + optional case folding.
    public static func normalizeForSearch(
        _ text: String,
        caseSensitive: Bool
    ) -> String {
        var result = normalize(text)
        if !caseSensitive {
            result = result.lowercased()
        }
        return result
    }

    // MARK: - Search-recall extensions

    /// Typographic punctuation → ASCII equivalents. Every entry is a
    /// 1:1 Character substitution (single UTF-16 unit → single UTF-16
    /// unit), so applying the map preserves string length and the
    /// existing rect NSRange math (Risk 1: a wrong rect is a misplaced
    /// redaction).
    static let smartPunctuationMap: [Character: Character] = [
        "\u{201C}": "\"",  // LEFT DOUBLE QUOTATION MARK
        "\u{201D}": "\"",  // RIGHT DOUBLE QUOTATION MARK
        "\u{2018}": "'",   // LEFT SINGLE QUOTATION MARK
        "\u{2019}": "'",   // RIGHT SINGLE QUOTATION MARK
        "\u{2013}": "-",   // EN DASH
        "\u{2014}": "-",   // EM DASH
        "\u{2012}": "-",   // FIGURE DASH
        "\u{2011}": "-",   // NON-BREAKING HYPHEN
        "\u{00AD}": "-",   // SOFT HYPHEN
    ]

    /// Fold smart quotes / dashes to their plain equivalents.
    /// Length-preserving by construction (1:1 Character map) — safe to
    /// apply on both sides of a match without an offset map.
    public static func normalizeSmartPunctuation(_ text: String) -> String {
        String(text.map { smartPunctuationMap[$0] ?? $0 })
    }

    /// Separator characters removed by digit-format-insensitive matching
    /// ("123456789" matches "123-45-6789"). NFKC has already mapped
    /// NBSP → space upstream, so a plain space entry covers it.
    static let separatorCharacters: Set<Character> = ["-", " ", ".", "/"]

    /// Strip separator characters, returning the stripped string plus an
    /// explicit offset map: `offsetMap[i]` is the Character index in
    /// `text` of `normalized[i]`. Length-changing — callers MUST route
    /// match ranges through the map before computing rects (the
    /// offset-mapping strategy; leak-class if skipped).
    public static func stripSeparators(_ text: String) -> (normalized: String, offsetMap: [Int]) {
        var result = ""
        var map: [Int] = []
        map.reserveCapacity(text.count)
        for (originalIdx, char) in text.enumerated() {
            if separatorCharacters.contains(char) { continue }
            result.append(char)
            map.append(originalIdx)
        }
        return (result, map)
    }

    /// Remove diacritics ("Muñoz" → "Munoz"), returning the folded string
    /// plus the same offset-map shape as `stripSeparators`. Works
    /// per-Character: each grapheme is NFD-decomposed, its nonspacing
    /// marks dropped, and the survivors NFC-recomposed so the folded
    /// piece cannot re-cluster with a neighbor on later traversal
    /// (grapheme-count stability is what keeps the map indexable).
    /// A Character consisting solely of marks is removed outright.
    public static func foldDiacritics(_ text: String) -> (normalized: String, offsetMap: [Int]) {
        var result = ""
        var map: [Int] = []
        map.reserveCapacity(text.count)
        for (originalIdx, char) in text.enumerated() {
            let kept = String(char).decomposedStringWithCanonicalMapping.unicodeScalars.filter {
                $0.properties.generalCategory != .nonspacingMark
            }
            guard !kept.isEmpty else { continue }
            let piece = String(String.UnicodeScalarView(kept)).precomposedStringWithCanonicalMapping
            for c in piece {
                result.append(c)
                map.append(originalIdx)
            }
        }
        // Defensive: if a script still re-clusters across appends, the
        // Character count and map desynchronize and every downstream rect
        // would be wrong. Fall back to identity — exact rects, folded
        // recall lost for this string only.
        guard result.count == map.count else {
            return (text, Array(0..<text.count))
        }
        return (result, map)
    }

    /// Compose offset maps from chained length-changing normalizations:
    /// `inner` maps newest → intermediate, `outer` maps intermediate →
    /// oldest. nil `outer` means `inner` already targets the oldest space.
    public static func composeOffsetMaps(outer: [Int]?, inner: [Int]) -> [Int] {
        guard let outer else { return inner }
        return inner.map { outer[$0] }
    }

    /// Result of `applySearchExtensions`: the transformed page/query pair,
    /// the pre-fold/strip base text (the coordinate space rect NSRanges
    /// are expressed in), and the offset map back to that space (nil when
    /// every applied step was 1:1).
    public struct SearchNormalization: Sendable {
        public let pageText: String
        public let query: String
        public let baseText: String
        public let offsetMap: [Int]?
    }

    /// Apply the §4.4 recall extensions on top of an already
    /// NFKC-normalized page/query pair, honoring the SearchOptions
    /// flags. Order matters: smart punctuation first (1:1, folds dashes
    /// so the separator set sees plain "-"), then diacritic fold, then
    /// separator strip, with maps composed back to the input space.
    public static func applySearchExtensions(
        pageText: String,
        query: String,
        options: SearchOptions
    ) -> SearchNormalization {
        var page = pageText
        var q = query
        if options.normalizeSmartPunctuation {
            page = normalizeSmartPunctuation(page)
            q = normalizeSmartPunctuation(q)
        }
        let base = page
        var map: [Int]? = nil
        if options.foldDiacritics {
            let folded = foldDiacritics(page)
            map = folded.offsetMap
            page = folded.normalized
            q = foldDiacritics(q).normalized
        }
        if options.stripDigitSeparators {
            let stripped = stripSeparators(page)
            map = composeOffsetMaps(outer: map, inner: stripped.offsetMap)
            page = stripped.normalized
            q = stripSeparators(q).normalized
        }
        return SearchNormalization(pageText: page, query: q, baseText: base, offsetMap: map)
    }
}
