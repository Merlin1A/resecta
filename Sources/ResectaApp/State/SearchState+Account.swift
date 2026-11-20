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
        /// The run was replaced, or its results were cleared while it was open: nothing is kept.
        case dropped
    }

    func beginAccount(run: Int, pageCount: Int) {
        accountInHand = SearchAccount(pageCount: pageCount)
        accountInHandRun = run
        accountInHandToken = UUID()
    }

    func recordCoverage(_ coverage: PageSearchCoverage, run: Int) {
        amendAccount(run: run) { $0.record(coverage) }
    }

    func recordRecognitionOff(page: Int, run: Int) {
        amendAccount(run: run) { $0.recordRecognitionOff(page: page) }
    }

    func recordPatternTimedOut(page: Int, text: String, run: Int) {
        amendAccount(run: run) { $0.recordPatternTimedOut(page: page, text: text) }
    }

    func recordUnboxedMatch(page: Int, text: String, run: Int) {
        amendAccount(run: run) { $0.recordUnboxedMatch(page: page, text: text) }
    }

    /// A report reaches its own run's account. One that arrives after that
    /// run closed still adds to its account, since a report only adds facts;
    /// a report from any other run is dropped.
    private func amendAccount(run: Int, _ change: (inout SearchAccount) -> Void) {
        if run == accountInHandRun, var account = accountInHand {
            change(&account)
            accountInHand = account
        } else if run == lastAccountRun, var account = lastAccount, let token = lastAccountToken {
            change(&account)
            lastAccount = account
            accountClosedSink?(token, account)
        }
    }

    /// Ends the open account, once. `run` names the run the caller ended;
    /// an account from another run is left open.
    func closeAccount(_ how: AccountClose, run: Int? = nil) {
        guard var account = accountInHand, let token = accountInHandToken else { return }
        if let run, run != accountInHandRun { return }
        accountInHand = nil
        accountInHandToken = nil
        switch how {
        case .dropped:
            return
        case .completed:
            account.end(.completed)
        case .cancelled:
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
