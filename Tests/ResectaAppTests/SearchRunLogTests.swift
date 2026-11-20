import Foundation
import Testing
@testable import ResectaApp
import RedactionEngine

// The document's run log for the stop at Redact: every run that started
// reading, oldest first, with the query it ran; a replaced run, which kept
// no account, is not among the closed runs.

@MainActor
@Suite("Redact stop: the document's run log")
struct SearchRunLogTests {

    @Test("A run that opens an account logs its query, as it started")
    func openingLogsTheQuery() {
        let search = SearchState(defaults: makeScratchDefaults().0)
        search.searchModeType = .text
        search.queryText = "Delia"
        var logged: [AppliedSearchQuery] = []
        search.accountOpenedSink = { _, query in logged.append(query) }
        let run = search.beginRun()
        search.beginAccount(run: run, pageCount: 3)
        #expect(logged == [AppliedSearchQuery(kind: .text("Delia"), options: search.options)])
    }

    @Test("Closed runs come oldest first with their queries; a replaced run is left out")
    func closedRunsInOrder() {
        let state = RedactionState()
        let first = UUID(), replaced = UUID(), last = UUID()
        let a = AppliedSearchQuery(kind: .text("Delia"), options: SearchOptions())
        let b = AppliedSearchQuery(kind: .text("Deli"), options: SearchOptions())
        let c = AppliedSearchQuery(kind: .regex("[0-9]+"), options: SearchOptions())
        state.recordSearchRunOpened(token: first, query: a)
        state.recordSearchRunOpened(token: replaced, query: b)
        state.recordSearchRunOpened(token: last, query: c)
        var account = SearchAccount(pageCount: 1)
        account.end(.completed)
        state.recordSearchAccount(account, token: last)
        state.recordSearchAccount(account, token: first)
        #expect(state.closedSearchRuns.map(\.query) == [a, c])
    }
}
