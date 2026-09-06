import Foundation

// Applied-search types for the verification search re-check.
//
// The seam: the app stamps an `AppliedSearchRecord` on every search-origin
// match-audit entry at the one apply seam; at run entry it joins the present
// regions to that audit and hands the engine one `SearchRecheckRequest` per
// distinct query through the run context; the `searchRecheck` layer re-runs
// each request on the redacted output through `DocumentSearcher` itself.
//
// Query texts travel on these types for display composition only. Status
// messages stay content-free; nothing here is logged or persisted.

/// The specification of a search the user ran: kind (text · regex ·
/// multi-term), the query string(s) and the full `SearchOptions`. Identity
/// is kind + options, so two applies of the same search merge into one
/// re-check request.
public struct AppliedSearchQuery: Sendable, Hashable {

    public enum Kind: Sendable, Hashable {
        case text(String)
        case regex(String)
        case multiTerm([String])
    }

    public let kind: Kind
    public let options: SearchOptions

    public init(kind: Kind, options: SearchOptions) {
        self.kind = kind
        self.options = options
    }

    /// The engine search mode this query re-runs as (same kind, same
    /// options). The re-check forces `includeOCR` on a copy of `options`
    /// before it re-runs; this mode is the query exactly as the user ran it.
    public var searchMode: SearchMode {
        switch kind {
        case .text(let query): .text(query, options: options)
        case .regex(let pattern): .regex(pattern, options: options)
        case .multiTerm(let terms): .multiTerm(terms, options: options)
        }
    }

    /// Multi-term labels name at most this many terms, then "+K".
    public static let multiTermLabelLimit = 3

    /// Display-only bare text form: the query, the pattern, or up to three
    /// terms joined by ", " then "+K". This is the value the results row
    /// quotes itself (`reviewTermTexts`); never logged or persisted.
    public var displayText: String {
        switch kind {
        case .text(let query): return query
        case .regex(let pattern): return pattern
        case .multiTerm(let terms):
            let shown = terms.prefix(Self.multiTermLabelLimit).joined(separator: ", ")
            let overflow = terms.count - Self.multiTermLabelLimit
            return overflow > 0 ? "\(shown) +\(overflow)" : shown
        }
    }

    /// Display-only query label for the per-query line: the query or the
    /// pattern in quotes, or the multi-term form of `displayText`. Option
    /// badges are separate (`optionBadges`) so the line can append them
    /// after its counts. Never logged or persisted.
    public var displayLabel: String {
        switch kind {
        case .text, .regex: "\u{201C}\(displayText)\u{201D}"
        case .multiTerm: displayText
        }
    }

    /// Display-only option badges in fixed order: "case-sensitive" when
    /// `options.caseSensitive`, "whole word" when `options.wholeWord` or
    /// `options.exactMatch`. Empty for default options.
    public var optionBadges: [String] {
        var badges: [String] = []
        if options.caseSensitive { badges.append("case-sensitive") }
        if options.wholeWord || options.exactMatch { badges.append("whole word") }
        return badges
    }
}

/// One applied search as the app recorded it at apply time: the query plus
/// the original run's result count and coverage facts. `foundHitCap` and
/// the two page sets are what make the page bound (`SearchRecheckRequest
/// .pageBound`) sound or not.
public struct AppliedSearchRecord: Sendable, Hashable {
    public let query: AppliedSearchQuery
    /// The session's result count for this query at apply time (selected or
    /// not). Display-only.
    public let foundCount: Int
    /// The original run stopped at `DocumentSearcher.maxResults`.
    public let foundHitCap: Bool
    /// Pages the original run skipped for OCR (pixel caps), 0-based.
    public let ocrSkippedPages: Set<Int>
    /// Pages where the original run's regex hit the per-page timeout, 0-based.
    public let regexTimeoutPages: Set<Int>
    /// Pages the original run never reached after hitting the cap.
    public let unscannedPageCount: Int

    public init(
        query: AppliedSearchQuery,
        foundCount: Int,
        foundHitCap: Bool = false,
        ocrSkippedPages: Set<Int> = [],
        regexTimeoutPages: Set<Int> = [],
        unscannedPageCount: Int = 0
    ) {
        self.query = query
        self.foundCount = foundCount
        self.foundHitCap = foundHitCap
        self.ocrSkippedPages = ocrSkippedPages
        self.regexTimeoutPages = regexTimeoutPages
        self.unscannedPageCount = unscannedPageCount
    }
}

/// One re-check request: an applied-search record plus what the user
/// applied from it — the regions still present at run entry, by count and
/// by page. Built by the app at run entry; carried on the run context;
/// consumed by `VerificationLayer.searchRecheck`.
public struct SearchRecheckRequest: Sendable, Hashable {
    public let record: AppliedSearchRecord
    /// Present regions whose audit cites this query.
    public let appliedCount: Int
    /// Pages carrying those regions, 0-based.
    public let appliedPages: Set<Int>
    /// Opt-in: restrict this request's re-run to `appliedPages`. Default
    /// OFF — the re-check reads every page, because on rasterized output the
    /// OCR pass is a different sensor from the search the user ran and its
    /// value is on the pages that search never flagged. Honored only when
    /// `pageBoundIsSound`; otherwise the request runs on every page.
    public var pageBound: Bool = false

    public init(
        record: AppliedSearchRecord,
        appliedCount: Int,
        appliedPages: Set<Int>,
        pageBound: Bool = false
    ) {
        self.record = record
        self.appliedCount = appliedCount
        self.appliedPages = appliedPages
        self.pageBound = pageBound
    }

    /// The bound is sound only when the original run was complete: it did
    /// not hit the result cap, skipped no page for OCR, and timed out on no
    /// page. Otherwise a page the original run never read could carry a
    /// match the bound would hide.
    public var pageBoundIsSound: Bool {
        !record.foundHitCap
            && record.ocrSkippedPages.isEmpty
            && record.regexTimeoutPages.isEmpty
    }

    /// `pageBound` as actually applied.
    public var effectivePageBound: Bool { pageBound && pageBoundIsSound }
}
