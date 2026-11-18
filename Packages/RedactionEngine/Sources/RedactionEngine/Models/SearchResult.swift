import Foundation

/// A single search hit — page, bounds, matched text, context.
public struct SearchResult: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let pageIndex: Int
    /// Bounding box in normalized coordinates (0–1, bottom-left origin),
    /// matching RedactionRegion.normalizedRect.
    public let normalizedRect: CGRect
    public let matchedText: String
    /// Surrounding text for context display: the engine's centered
    /// window (`DocumentSearcher.contextRadius` characters each side of
    /// the match, trimmed back to word boundaries on a truncated side,
    /// `…` only where text was cut, newlines outside the match flattened,
    /// the match itself verbatim). Every builder
    /// path — text layer, regex, PII scan, and both OCR legs — yields
    /// this one shape; `matchRangeInSnippet` locates the match inside it.
    public let contextSnippet: String
    public let source: SearchSource
    /// The search term that produced this match.
    public let term: String
    /// Whether this result is selected for redaction in the UI.
    public var isSelected: Bool = false
    /// PII category (nil for text/regex/multi-term results).
    public let piiCategory: PIICategory?
    /// PII detection confidence (nil for text/regex/multi-term results).
    public let piiConfidence: Double?
    /// Why the detector emitted this hit. nil for text/regex/multi-term
    /// rows (no inferred rule to explain). Used by MatchRationaleSheet and
    /// by the audit export.
    public let rationale: MatchRationale?
    /// Where `matchedText` sits inside `contextSnippet`, as
    /// Character offsets into the snippet (the leading `…`, when
    /// present, counts as one). Populated by every engine builder path
    /// so the row can highlight the match without re-searching; nil only
    /// for hand-built values (fixtures, older callers), where the app
    /// falls back to the first verbatim occurrence of `matchedText`.
    public let matchRangeInSnippet: Range<Int>?
    /// The match this result is one line of. A match that wraps onto a
    /// second line is emitted once per line it touches, each result with its
    /// own rect and the same `occurrenceID`; nil for every other result.
    public let occurrenceID: UUID?
    /// The hidden glyphs' own box on a page whose text is an invisible layer
    /// over a page image, where `normalizedRect` is the printed ink the match
    /// names: a Searchable export strips the text layer under both, and the
    /// fill paints `normalizedRect` alone. nil on every other page.
    public let textLayerRect: CGRect?
    /// The ink fit could not read the page in time, so `normalizedRect` is
    /// the drift envelope around the hidden glyphs (a larger box, never a
    /// smaller one). false on every other result.
    public let inkFitDegraded: Bool
    /// false for a match that was found but could not be given a box: it is
    /// listed with its page and no tick box, `normalizedRect` is `.zero`, it is
    /// never selected and Apply makes no region from it. true for every other
    /// result.
    public let hasBox: Bool
    /// The match lies on a line wholly outside the visible page (a crop box
    /// reaching past the media box), the one reason a result has no box that
    /// the app words differently. false on every other result.
    public let liesOffVisiblePage: Bool
    /// The box the read itself gave this match, when merging two readings of
    /// a scanned page grew `normalizedRect` past it: what a hybrid page
    /// compares with its text-layer matches to tell a repeat. nil when
    /// `normalizedRect` is that box (every result but a merged one).
    var identityRect: CGRect? = nil

    public init(
        id: UUID = UUID(),
        pageIndex: Int,
        normalizedRect: CGRect,
        matchedText: String,
        contextSnippet: String,
        source: SearchSource,
        term: String,
        isSelected: Bool = false,
        piiCategory: PIICategory? = nil,
        piiConfidence: Double? = nil,
        rationale: MatchRationale? = nil,
        matchRangeInSnippet: Range<Int>? = nil,
        occurrenceID: UUID? = nil,
        textLayerRect: CGRect? = nil,
        inkFitDegraded: Bool = false,
        hasBox: Bool = true,
        liesOffVisiblePage: Bool = false
    ) {
        self.id = id
        self.pageIndex = pageIndex
        self.normalizedRect = normalizedRect
        self.matchedText = matchedText
        self.contextSnippet = contextSnippet
        self.source = source
        self.term = term
        self.isSelected = isSelected
        self.piiCategory = piiCategory
        self.piiConfidence = piiConfidence
        self.rationale = rationale
        self.matchRangeInSnippet = matchRangeInSnippet
        self.occurrenceID = occurrenceID
        self.textLayerRect = textLayerRect
        self.inkFitDegraded = inkFitDegraded
        self.hasBox = hasBox
        self.liesOffVisiblePage = liesOffVisiblePage
    }

    /// A found match that could not be given a box: listed, never dropped.
    static func unboxed(
        pageIndex: Int,
        matchedText: String,
        contextSnippet: String,
        source: SearchSource,
        term: String,
        piiCategory: PIICategory? = nil,
        piiConfidence: Double? = nil,
        rationale: MatchRationale? = nil,
        matchRangeInSnippet: Range<Int>? = nil,
        occurrenceID: UUID? = nil,
        liesOffVisiblePage: Bool = false
    ) -> SearchResult {
        SearchResult(
            pageIndex: pageIndex, normalizedRect: .zero, matchedText: matchedText,
            contextSnippet: contextSnippet, source: source, term: term,
            piiCategory: piiCategory, piiConfidence: piiConfidence, rationale: rationale,
            matchRangeInSnippet: matchRangeInSnippet, occurrenceID: occurrenceID,
            hasBox: false, liesOffVisiblePage: liesOffVisiblePage)
    }
}

extension SearchResult: Hashable {}
