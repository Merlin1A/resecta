import Foundation
import RedactionEngine

// The account of what each search run read: the sheet's statement, the
// record of an applied search and the Redact stop read it. One account per
// run that starts reading, opened by the run, written only by that run's
// page reports and the app's two signals, and closed once, where the run
// ends: by the cancel funnel (stopped, or at the result limit), by the
// completed tail on the run's own token, or dropped when the run is
// replaced or its results are cleared while it is open. A closed account
// goes to the document's store under a token minted when it opened.

extension SearchState {

    enum AccountClose: Sendable {
        /// The run's tail ran on its own token.
        case completed
        /// A cancel: at the result limit when the results reached it, otherwise stopped.
        case cancelled
        /// The run's results were cleared while it was open: nothing is kept.
        case dropped
        /// A new run replaces it. Kept as a cancel when an Apply took a record
        /// while it was open, since boxes from it are on the document;
        /// otherwise nothing is kept.
        case replaced
    }

    func beginAccount(run: Int, pageCount: Int) {
        accountInHand = SearchAccount(pageCount: pageCount)
        accountInHandRun = run
        accountInHandToken = UUID()
        accountInHandApplied = false
        if let token = accountInHandToken, let query = runQuery() { accountOpenedSink?(token, query) }
    }

    func recordCoverage(_ coverage: PageSearchCoverage, run: Int) {
        amendAccount(run: run, page: coverage.pageIndex) { $0.record(coverage) }
    }

    func recordRecognitionOff(page: Int, run: Int) {
        amendAccount(run: run, page: page) { $0.recordRecognitionOff(page: page) }
    }

    func recordPatternTimedOut(page: Int, text: String, run: Int) {
        amendAccount(run: run, page: page) { $0.recordPatternTimedOut(page: page, text: text) }
    }

    func recordUnboxedMatch(page: Int, text: String, run: Int) {
        amendAccount(run: run, page: page) { $0.recordUnboxedMatch(page: page, text: text) }
    }

    /// A report reaches its own run's account. One that arrives after that
    /// run closed still adds to its account when `lateReportCounts` says so;
    /// a report from any other run is dropped.
    private func amendAccount(run: Int, page: Int, _ change: (inout SearchAccount) -> Void) {
        if run == accountInHandRun, var account = accountInHand {
            change(&account)
            accountInHand = account
        } else if run == lastAccountRun, var account = lastAccount, let token = lastAccountToken,
                  Self.lateReportCounts(page: page, after: account.ending) {
            change(&account)
            lastAccount = account
            accountClosedSink?(token, account)
        }
    }

    /// Whether a report that arrives after its run closed adds to that run's
    /// account. A completed run read every page, so any of its reports counts.
    /// A run stopped by the user or at the result limit dropped what came
    /// after its stop page: the searcher reports a page as it starts, before
    /// matching, so a late report for a page past the stop would mark as read
    /// a page whose matches were never kept. Only a page at or before the stop
    /// page counts.
    static func lateReportCounts(page: Int, after ending: SearchAccount.Ending) -> Bool {
        switch ending {
        case .completed: true
        case .stopped(let stop), .stoppedAtResultLimit(let stop): page <= stop
        }
    }

    /// Ends the open account, once. `run` names the run the caller ended;
    /// an account from another run is left open.
    func closeAccount(_ how: AccountClose, run: Int? = nil) {
        guard var account = accountInHand, let token = accountInHandToken else { return }
        if let run, run != accountInHandRun { return }
        let applied = accountInHandApplied
        accountInHand = nil
        accountInHandToken = nil
        accountInHandApplied = false
        switch how {
        case .dropped:
            return
        case .replaced where !applied:
            return
        case .completed:
            account.end(.completed)
        case .cancelled, .replaced:
            // The progress count is set as each page starts, so the page in hand is one less.
            let page = max(0, currentSearchPage - 1)
            account.end(resultsAtCap ? .stoppedAtResultLimit(page: page) : .stopped(page: page))
        }
        lastAccount = account
        lastAccountRun = accountInHandRun
        lastAccountToken = token
        accountClosedSink?(token, account)
    }
}
