import Foundation
import RedactionEngine

// The applied-search record the apply seam stamps on every search-origin
// match-audit entry — a typed search or a Scan — moved out of the class
// body: the session fields it reads (`searchModeType`, the query text and
// terms, `options`, `results`, the kickoff configuration and the coverage
// facts) stay where they are.

extension SearchState {

    /// The record the apply seam stamps on every search-origin
    /// `MatchAuditSnapshot` (`prepareApply(searchRecord:)`): the query
    /// as the user ran it — kind + query text(s) + the full `options`,
    /// the same fields `SearchAndRedactSheet.buildSearchMode()` reads —
    /// plus this run's result count and coverage facts. A Scan records the
    /// categories it ran (the effective set — an empty selection is every
    /// category) and the configuration the kickoff compiled, so the
    /// Detection Sweep re-runs the scan as the user ran it. Nil for an
    /// empty query / term set and for a Scan session that never ran. Read
    /// on MainActor at apply time, before the detached prepare step.
    func appliedSearchRecord() -> AppliedSearchRecord? {
        let kind: AppliedSearchQuery.Kind
        var scanConfiguration: ScanRunConfiguration?
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
            guard let configuration = lastRunScanConfiguration else { return nil }
            kind = .piiScan(categories: effectiveScanCategories)
            scanConfiguration = configuration
        }
        return AppliedSearchRecord(
            query: AppliedSearchQuery(kind: kind, options: options),
            foundCount: results.count,
            foundHitCap: resultsAtCap,
            ocrSkippedPages: ocrSkippedPages,
            regexTimeoutPages: regexTimeoutPages,
            unscannedPageCount: capUnscannedPageCount,
            scanConfiguration: scanConfiguration)
    }
}
