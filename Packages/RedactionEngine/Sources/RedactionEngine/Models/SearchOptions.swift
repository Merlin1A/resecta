import Foundation

/// Configuration options for search behavior.
public struct SearchOptions: Sendable, Equatable, Hashable {
    public var caseSensitive: Bool = false
    public var wholeWord: Bool = false
    public var includeOCR: Bool = true
    public var normalizeUnicode: Bool = true

    // Search-recall normalization extensions.
    // The two length-changing flags (separator strip, diacritic fold)
    // apply on the literal text/multi-term matcher and the OCR literal
    // path, where match ranges route through TextNormalizer's offset
    // map back to rect coordinates. They are intentionally NOT applied
    // on the regex paths: transforming a pattern corrupts its semantics
    // (e.g. an em-dash inside a character class), and transforming only
    // the page text without map-through would misplace rects.

    /// Digit-format-insensitive matching: "123456789" matches
    /// "123-45-6789" by stripping `-`, space, `.`, `/` from both sides
    /// before comparison. Off by default.
    public var stripDigitSeparators: Bool = false

    /// Smart-quote / em-dash folding ("—" matches "-"); 1:1 character
    /// substitution, length-preserving. On by default — universally
    /// helpful on typeset PDFs. On the regex paths only the page text
    /// is folded, never the pattern.
    public var normalizeSmartPunctuation: Bool = true

    /// Diacritic-insensitive matching ("Munoz" matches "Muñoz").
    /// Off by default: folding introduces false positives in non-Latin
    /// scripts and many name databases are accent-significant.
    public var foldDiacritics: Bool = false

    // AND mode for multi-term search.
    // When true, `searchMultiTerm` retains only pages where EVERY term
    // has at least one result (page-level conjunction). When false (the
    // default), results from all terms are OR-joined — the historical
    // behavior for all existing callers.
    /// Page-level conjunction for multi-term search. `false` (default) = OR
    /// union (historical behavior); `true` = AND — only pages where every
    /// queried term has at least one result are included in the output.
    /// Has no effect on `.text`, `.regex`, or `.piiScan` modes.
    public var multiTermConjunction: Bool = false

    public init(
        caseSensitive: Bool = false,
        wholeWord: Bool = false,
        includeOCR: Bool = true,
        normalizeUnicode: Bool = true,
        stripDigitSeparators: Bool = false,
        normalizeSmartPunctuation: Bool = true,
        foldDiacritics: Bool = false,
        multiTermConjunction: Bool = false
    ) {
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.includeOCR = includeOCR
        self.normalizeUnicode = normalizeUnicode
        self.stripDigitSeparators = stripDigitSeparators
        self.normalizeSmartPunctuation = normalizeSmartPunctuation
        self.foldDiacritics = foldDiacritics
        self.multiTermConjunction = multiTermConjunction
    }
}
