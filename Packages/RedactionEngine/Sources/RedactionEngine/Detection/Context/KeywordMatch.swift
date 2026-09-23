import Foundation

// Token-bound keyword matching — the one predicate every keyword-match site in
// Detection/ applies: the context-window scorer (boolean signals and the
// per-keyword breakdown), the scoped negative-context gazetteer, the
// calibrated context features and the phone and date-of-birth label windows.
//
// A keyword matches at a position only when each ALPHANUMERIC edge of the
// keyword meets a non-alphanumeric scalar or the window edge; a punctuation
// edge is free. So `lp` is not read inside "help", `tag` not inside "stage",
// `ein` not inside "herein", `tel` not inside "Patel"; `ss#` still reads
// "SS#123-45-6789" (its right edge is punctuation), `v.` reads " v. " but not
// "rev.", and a multi-word keyword such as "social security number" reads as a
// phrase because its edges are letters.
//
// The alphanumeric class is `CharacterSet.alphanumerics` over unicode scalars
// (letters, marks, numbers), the class the label-anchor route already uses; a
// combining mark at a keyword's edge belongs to its base letter and closes the
// token. A surrogate pair is decoded from either half so a supplementary-plane
// letter closes a token like any other letter.
//
// Every caller lowercases its window and ships lowercased keywords; the
// predicate compares scalars as given and never folds case itself.

enum KeywordMatch {

    /// True when `keyword` occurs in `window` as a whole token (see the file
    /// comment for the edge rule). An empty keyword never matches.
    static func containsToken(_ keyword: String, in window: String) -> Bool {
        containsToken(keyword, in: window as NSString)
    }

    /// The `NSString` form for callers that test many keywords against one
    /// window: bridge the window once, then call this per keyword.
    static func containsToken(_ keyword: String, in window: NSString) -> Bool {
        firstTokenRange(of: keyword, in: window, from: 0) != nil
    }

    /// Every token-bound occurrence of `keyword` in `window` as UTF-16 ranges
    /// in ascending order — the range twin of `containsToken` for the feature
    /// path's nearest-occurrence distance. `containsToken` is exactly "this
    /// array is non-empty".
    static func rangesOfToken(_ keyword: String, in window: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var searchFrom = 0
        while let found = firstTokenRange(of: keyword, in: window, from: searchFrom) {
            ranges.append(found)
            searchFrom = found.location + 1
        }
        return ranges
    }

    // MARK: - Private

    /// The first token-bound occurrence of `keyword` at or after `searchFrom`.
    private static func firstTokenRange(of keyword: String, in window: NSString, from searchFrom: Int) -> NSRange? {
        let needle = keyword as NSString
        let needleLength = needle.length
        let windowLength = window.length
        guard needleLength > 0, searchFrom < windowLength else { return nil }
        let leftEdgeIsAlphanumeric = isAlphanumeric(needle, at: 0)
        let rightEdgeIsAlphanumeric = isAlphanumeric(needle, at: needleLength - 1)
        var cursor = searchFrom
        while cursor < windowLength {
            let found = window.range(
                of: keyword, options: [],
                range: NSRange(location: cursor, length: windowLength - cursor))
            guard found.location != NSNotFound else { return nil }
            let end = found.location + found.length
            let leftBounded = !leftEdgeIsAlphanumeric
                || found.location == 0
                || !isAlphanumeric(window, at: found.location - 1)
            let rightBounded = !rightEdgeIsAlphanumeric
                || end >= windowLength
                || !isAlphanumeric(window, at: end)
            if leftBounded && rightBounded { return found }
            cursor = found.location + 1
        }
        return nil
    }

    /// True when the scalar whose UTF-16 encoding covers `index` is a letter,
    /// a mark or a number; an unpaired surrogate is none of those.
    private static func isAlphanumeric(_ text: NSString, at index: Int) -> Bool {
        guard let scalar = scalar(in: text, at: index) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    /// The unicode scalar at a UTF-16 index, decoding a surrogate pair from
    /// either of its halves; nil for an unpaired surrogate.
    private static func scalar(in text: NSString, at index: Int) -> Unicode.Scalar? {
        let unit = text.character(at: index)
        if UTF16.isLeadSurrogate(unit) {
            guard index + 1 < text.length else { return nil }
            let trail = text.character(at: index + 1)
            guard UTF16.isTrailSurrogate(trail) else { return nil }
            return pairedScalar(lead: unit, trail: trail)
        }
        if UTF16.isTrailSurrogate(unit) {
            guard index > 0 else { return nil }
            let lead = text.character(at: index - 1)
            guard UTF16.isLeadSurrogate(lead) else { return nil }
            return pairedScalar(lead: lead, trail: unit)
        }
        return Unicode.Scalar(unit)
    }

    private static func pairedScalar(lead: UInt16, trail: UInt16) -> Unicode.Scalar? {
        let value = 0x10000 + ((UInt32(lead) - 0xD800) << 10) + (UInt32(trail) - 0xDC00)
        return Unicode.Scalar(value)
    }
}
