import Foundation

// One home for opening Scan: the session the editor's Scan button and the
// results screen's Review in Scan both present.
extension SearchState {

    /// The Scan session: the detectors' scan, armed to run once when the
    /// sheet appears (`pendingAutoRunScan`), so one tap opens the sheet and
    /// runs a full scan with no second confirm.
    static func scanSession() -> SearchState {
        let state = SearchState()
        state.searchModeType = .piiScan
        state.pendingAutoRunScan = true
        return state
    }
}
