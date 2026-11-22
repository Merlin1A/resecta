import RedactionEngine

// The query a search run builds, from the session alone: the body moved
// from SearchAndRedactSheet+DegradeBanner.swift unchanged. A value of its
// own, so the sheet's forward and a test build it from a bare SearchState
// without resolving the sheet's environment objects, and the run
// (`SearchRun`) builds the same query.

@MainActor struct SearchQuery {
    let searchState: SearchState

    func buildSearchMode() -> SearchMode {
        let options = searchState.options
        switch searchState.searchModeType {
        case .text:
            return .text(searchState.queryText, options: options)
        case .regex:
            return .regex(searchState.queryText, options: options)
        case .multiTerm:
            return .multiTerm(searchState.searchTerms, options: options)
        case .piiScan:
            // Empty chip selection = scan everything (the one-tap
            // contract needs no configuration) — the effective set
            // maps no-selection to the full category set.
            return .piiScan(categories: searchState.effectiveScanCategories, options: options)
        }
    }
}
