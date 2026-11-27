import Foundation
import RedactionEngine

extension SearchState {

    /// The query of the run in hand, as it started: the mode's text or terms
    /// and the options the run took. Nil for an empty query or term set.
    func runQuery() -> AppliedSearchQuery? {
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
            kind = .piiScan(categories: effectiveScanCategories)
        }
        return AppliedSearchQuery(kind: kind, options: lastRunOptions ?? options)
    }
}
