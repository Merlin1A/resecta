import Foundation
import RedactionEngine

/// One searched text with its matching options: what the stop at Redact
/// keeps an account for. A Text search is one; a terms search is one per
/// term; a Pattern is its pattern; a Scan is one, named by its kind. Its
/// options are the five that decide what can match and nothing else:
/// Include OCR Pages and "all terms must match" are not among them.
struct RedactStopUnit: Hashable, Sendable {

    enum Kind: Hashable, Sendable {
        /// A typed text, alone or as one term of a terms search.
        case text
        case pattern
        case scan
    }

    let kind: Kind
    /// The text as typed; empty for a Scan.
    let text: String
    let caseSensitive: Bool
    let wholeWord: Bool
    /// The Accents option: accents ignored when on.
    let accents: Bool
    let digitSeparators: Bool
    let quotesAndDashes: Bool

    init(kind: Kind, text: String, options: SearchOptions) {
        self.kind = kind
        self.text = kind == .scan ? "" : text
        caseSensitive = options.caseSensitive
        wholeWord = options.wholeWord
        // Accents and digit separators change nothing a pattern matches, so
        // a pattern's unit does not hold them.
        accents = kind == .pattern ? false : options.foldDiacritics
        digitSeparators = kind == .pattern ? false : options.stripDigitSeparators
        quotesAndDashes = options.normalizeSmartPunctuation
    }

    /// The units an applied or run search holds, in the order typed.
    static func units(of query: AppliedSearchQuery) -> [RedactStopUnit] {
        switch query.kind {
        case .text(let text): [RedactStopUnit(kind: .text, text: text, options: query.options)]
        case .regex(let pattern): [RedactStopUnit(kind: .pattern, text: pattern, options: query.options)]
        case .multiTerm(let terms): terms.map { RedactStopUnit(kind: .text, text: $0, options: query.options) }
        case .piiScan: [RedactStopUnit(kind: .scan, text: "", options: query.options)]
        }
    }

    /// True when this unit matches wherever `other` can: the same kind and
    /// text, and every matching option at least as loose. A page this unit
    /// read was searched for `other` too. A unit covers itself.
    func covers(_ other: RedactStopUnit) -> Bool {
        kind == other.kind && text == other.text
            && (!caseSensitive || other.caseSensitive)
            && (!wholeWord || other.wholeWord)
            && (accents || !other.accents)
            && (digitSeparators || !other.digitSeparators)
            && (quotesAndDashes || !other.quotesAndDashes)
    }
}
