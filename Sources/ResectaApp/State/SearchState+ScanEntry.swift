import Foundation
import RedactionEngine

// One home for opening Scan: the session the editor's Scan button and the
// results screen's Review in Scan both present.
extension SearchState {

    /// The Scan session: the detectors' scan, armed to run once when the
    /// sheet appears (`pendingAutoRun`), so one tap opens the sheet and
    /// runs a full scan with no second confirm.
    static func scanSession() -> SearchState {
        let state = SearchState()
        state.searchModeType = .piiScan
        state.pendingAutoRun = .piiScan
        return state
    }

    /// The session the stop's Search These Pages opens: the re-run's query
    /// in the session's mode, terms and options, armed to run once when
    /// the sheet appears. Recognition is on and any term may match, as the
    /// re-run's options carry them.
    static func reRunSession(for query: AppliedSearchQuery) -> SearchState {
        let state = SearchState()
        switch query.kind {
        case .text(let text):
            state.searchModeType = .text
            state.queryText = text
        case .regex(let pattern):
            state.searchModeType = .regex
            state.queryText = pattern
        case .multiTerm(let terms):
            state.searchModeType = .multiTerm
            state.searchTerms = terms
        case .piiScan(let categories):
            state.searchModeType = .piiScan
            state.enabledPIICategories = categories
        }
        state.options = query.options
        state.pendingAutoRun = state.searchModeType
        return state
    }

    /// The sheet's one consume of the one-shot as it appears: true once, when
    /// a run was armed and the mode it was armed for is the mode in hand.
    func consumeAutoRun() -> Bool {
        guard let armed = pendingAutoRun else { return false }
        pendingAutoRun = nil
        return searchModeType == armed
    }
}
