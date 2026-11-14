import Foundation
import RedactionEngine

// Return in the Search field.
//
// Return starts a run for a search that is not the one whose results are
// listed or arriving: a query below the as-you-type floor, a query carried
// across a mode switch, a run that was cancelled or stopped before it
// started. Return on the search that is listed (in full, or up to the
// result cap) or arriving starts nothing: the field gives up the keyboard,
// and the list, its selection and its applied marks stay as they are.

/// What a run searches for: the values the engine query is built from
/// (`SearchAndRedactSheet.buildSearchMode()`), and no others.
struct SearchRunShape: Equatable, Sendable {
    let mode: SearchModeType
    /// The typed query, verbatim (Text and Regex); empty otherwise.
    let query: String
    /// The staged terms (Multi-term); empty otherwise.
    let terms: [String]
    let options: SearchOptions
}

extension SearchState {
    /// What a run started now would search for. In Multi-term the field
    /// holds a term still being typed, which no run reads, so it is left out.
    var currentRunShape: SearchRunShape {
        SearchRunShape(
            mode: searchModeType,
            query: searchModeType == .text || searchModeType == .regex ? queryText : "",
            terms: searchModeType == .multiTerm ? searchTerms : [],
            options: options
        )
    }

    /// Whether Return in the Search field starts a run.
    var returnStartsRun: Bool {
        Self.returnStartsRun(
            current: currentRunShape,
            lastRun: lastRunShape,
            isSearching: isSearching,
            hasCompletedRun: hasCompletedRunSinceClear,
            stoppedAtCap: resultsAtCap
        )
    }

    /// The rule, as a pure function of the five facts it reads.
    /// Pinned by `SearchReturnRuleTests`.
    static func returnStartsRun(
        current: SearchRunShape,
        lastRun: SearchRunShape?,
        isSearching: Bool,
        hasCompletedRun: Bool,
        stoppedAtCap: Bool
    ) -> Bool {
        // Nothing to search for: no run. A typed query runs verbatim, but a
        // whitespace-only one is an invisible query and does not run.
        switch current.mode {
        case .text, .regex:
            if current.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        case .multiTerm:
            if current.terms.isEmpty { return false }
        case .piiScan:
            // Scan has no field; nothing asks the rule there.
            return false
        }
        // A search other than the one last started: run it.
        guard current == lastRun else { return true }
        // The search last started: run it again only when its results are
        // neither listed nor arriving (cancelled, stopped before it started,
        // or cleared since). A run that stopped at the result cap is listed:
        // it ends as a cancelled run, so the completed flag stays down.
        return !isSearching && !hasCompletedRun && !stoppedAtCap
    }
}
