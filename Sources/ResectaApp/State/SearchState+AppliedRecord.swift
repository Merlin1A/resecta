import Foundation
import RedactionEngine

// The applied-search record the apply seam stamps on every search-origin
// match-audit entry, moved out of the class body as a pure move: the
// session fields it reads (`searchModeType`, the query text and terms,
// `options`, `results` and the coverage facts) stay where they are.

extension SearchState {

    /// The record the apply seam stamps on every search-origin
    /// `MatchAuditSnapshot` (`prepareApply(searchRecord:)`): the query
    /// as the user ran it — kind + query text(s) + the full `options`,
    /// the same fields `SearchAndRedactSheet.buildSearchMode()` reads —
    /// plus this run's result count and coverage facts. Nil for the
    /// Scan interface (`.piiScan` is a detector run, not a typed search)
    /// and for an empty query / term set (nothing was searched). Read
    /// on MainActor at apply time, before the detached prepare step.
    func appliedSearchRecord() -> AppliedSearchRecord? {
        let kind: AppliedSearchQuery.Kind
        switch searchModeType {
        case .text:
            guard !queryText.isEmpty else { return nil }
            kind = .text(queryText)
        case .regex:
            guard !queryText.isEmpty else { return nil }
            kind = .regex(queryText)
        case .multiTerm:
            guard !searchTerms.isEmpty else { return nil }
            kind = .multiTerm(searchTerms)
        case .piiScan:
            return nil
        }
        return AppliedSearchRecord(
            query: AppliedSearchQuery(kind: kind, options: options),
            foundCount: results.count,
            foundHitCap: resultsAtCap,
            ocrSkippedPages: ocrSkippedPages,
            regexTimeoutPages: regexTimeoutPages,
            unscannedPageCount: capUnscannedPageCount)
    }
}
