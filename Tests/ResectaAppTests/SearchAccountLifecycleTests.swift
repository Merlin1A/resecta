import CoreGraphics
import Foundation
import Testing
@testable import RedactionEngine
@testable import ResectaApp

// One closed account per run that started reading, closed where the run
// ends: the cancel funnel, the completed tail on the run's own token, or
// dropped for a replaced run or one whose results are cleared while open.
// Driven on the session alone; no searcher runs. Pages are zero-based.

@MainActor
@Suite("Search account: one per run, closed where the run ends")
struct SearchAccountLifecycleTests {

    final class Store {
        var closed: [UUID: SearchAccount] = [:]
        var order: [UUID] = []
        /// A late report re-sends an account under its token: kept once, updated.
        func keep(_ account: SearchAccount, _ token: UUID) {
            if closed[token] == nil { order.append(token) }
            closed[token] = account
        }
    }

    /// A session with a run that has started reading a ten-page document.
    static func running(_ store: Store, mode: SearchModeType = .text) -> (SearchState, Int) {
        let search = SearchState(defaults: makeScratchDefaults().0)
        search.searchModeType = mode
        search.queryText = "Delia"
        search.accountClosedSink = { token, account in store.keep(account, token) }
        search.clearResults()
        let run = search.beginRun()
        search.totalPages = 10
        search.beginAccount(run: run, pageCount: 10)
        for page in 0..<5 {
            search.recordCoverage(PageSearchCoverage(pageIndex: page, route: .textLayer), run: run)
        }
        search.currentSearchPage = 6
        return (search, run)
    }

    static func only(_ store: Store) -> SearchAccount? {
        store.order.count == 1 ? store.closed[store.order[0]] : nil
    }

    @Test("Completed: the tail on the run's own token closes it completed")
    func completed() {
        let store = Store()
        let (search, run) = Self.running(store)
        search.closeAccount(.completed, run: run)
        #expect(Self.only(store)?.ending == .completed)
        #expect(search.accountInHand == nil)
    }

    @Test("The completed close on another run's token leaves the account open")
    func completedOnAnotherToken() {
        let store = Store()
        let (search, run) = Self.running(store)
        search.closeAccount(.completed, run: run + 1)
        #expect(store.order.isEmpty)
        #expect(search.accountInHand != nil)
    }

    @Test("The engine stops at the result limit: the run's end closes it at the limit, on the page in hand")
    func engineLimit() {
        let store = Store()
        let (search, run) = Self.running(store)
        search.noteCapReached()
        #expect(search.runEndsCancelled(run: run, taskCancelled: false))
        #expect(Self.only(store)?.ending == .stoppedAtResultLimit(page: 5))
    }

    @Test("The app drops a match at the limit: closed at the limit")
    func appLimit() {
        let store = Store()
        let (search, _) = Self.running(store)
        search.markCapReached()
        #expect(Self.only(store)?.ending == .stoppedAtResultLimit(page: 5))
    }

    @Test("The user stops the run on page 6: stopped there, pages 7 to 10 not reached")
    func userStop() async {
        let store = Store()
        let (search, _) = Self.running(store)
        await search.cancelSearch()
        let account = Self.only(store)
        #expect(account?.ending == .stopped(page: 5))
        #expect(account?.pages(for: .notReached) == [6, 7, 8, 9])
    }

    @Test("Replaced by a new run: the account is dropped, and none is kept")
    func superseded() {
        let store = Store()
        let (search, _) = Self.running(store)
        search.closeAccount(.dropped)
        #expect(store.order.isEmpty)
        #expect(search.lastAccount == nil)
    }

    @Test("The query cleared mid-run: stopped, kept in the store, and the session's last account cleared")
    func queryCleared() async {
        let store = Store()
        let (search, _) = Self.running(store)
        await search.cancelSearch()
        search.clearResults()
        #expect(Self.only(store)?.ending == .stopped(page: 5))
        #expect(search.lastAccount == nil)
    }

    @Test("A mode switch or the sheet's teardown mid-run: stopped, kept in the store")
    func modeSwitchAndTeardown() {
        for teardown in [false, true] {
            let store = Store()
            let (search, _) = Self.running(store)
            search.cancelSearchWithoutAwait()
            if teardown { search.clear() } else { search.clearResults() }
            #expect(Self.only(store)?.ending == .stopped(page: 5))
        }
    }

    @Test("Results cleared while the account is open: dropped")
    func clearedWhileOpen() {
        let store = Store()
        let (search, _) = Self.running(store)
        search.clearResults()
        #expect(store.order.isEmpty)
    }

    @Test("Apply mid-run, then the sheet closes: the record names the token, and the store holds how the run ended")
    func applyMidRunThenClose() throws {
        let store = Store()
        let (search, _) = Self.running(store)
        let record = try #require(search.appliedSearchRecord())
        #expect(record.account == nil, "an open account has no ending to record")
        let token = try #require(record.accountToken)
        search.cancelSearchWithoutAwait()
        search.clear()
        #expect(store.closed[token]?.ending == .stopped(page: 5))
    }

    @Test("Apply after the run closed: the record carries the closed account and its token")
    func applyAfterClose() throws {
        let store = Store()
        let (search, run) = Self.running(store)
        search.closeAccount(.completed, run: run)
        let record = try #require(search.appliedSearchRecord())
        #expect(record.account?.ending == .completed)
        #expect(record.accountToken == store.order.first)
    }

    @Test("A late report for the run just closed adds to its account; a report from another run is dropped")
    func lateReports() {
        let store = Store()
        let (search, run) = Self.running(store)
        search.closeAccount(.completed, run: run)
        search.recordCoverage(PageSearchCoverage(pageIndex: 7, route: .textLayer), run: run)
        search.recordCoverage(PageSearchCoverage(pageIndex: 8, route: .textLayer), run: run + 7)
        let account = Self.only(store)
        #expect(account?.pages(for: .noReport) == [5, 6, 8, 9])
    }

    @Test("A pattern the engine refuses at the start: no result is cleared, so the run's tail closes it completed with no page read")
    func refusedPattern() {
        let store = Store()
        let search = SearchState(defaults: makeScratchDefaults().0)
        search.accountClosedSink = { token, account in store.keep(account, token) }
        search.clearResults()
        let run = search.beginRun()
        search.beginAccount(run: run, pageCount: 3)
        search.regexError = "refused"
        search.closeAccount(.completed, run: run)
        #expect(Self.only(store)?.pages(for: .noReport) == [0, 1, 2])
    }

    @Test("Preparation failed or the pattern was invalid: no account opened, and a close does nothing")
    func noAccount() async {
        let store = Store()
        let search = SearchState(defaults: makeScratchDefaults().0)
        search.accountClosedSink = { token, account in store.keep(account, token) }
        search.closeAccount(.completed)
        await search.cancelSearch()
        search.cancelSearchWithoutAwait()
        #expect(store.order.isEmpty)
    }

    @Test("A match with no box reaches the run's account and the applied record, by page and text")
    func unboxedMatchReachesTheRecord() throws {
        let store = Store()
        let (search, run) = Self.running(store)
        search.appendResult(SearchResult.unboxed(pageIndex: 3, matchedText: "Delia Rourke", contextSnippet: "…",
                                                 source: .textLayer, term: "Delia"), run: run)
        search.appendResult(SearchResult(pageIndex: 2, normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.03),
                                         matchedText: "Delia", contextSnippet: "…", source: .textLayer, term: "Delia"), run: run)
        search.closeAccount(.completed, run: run)
        let record = try #require(search.appliedSearchRecord())
        #expect(record.account?.unboxedMatchTexts == [3: ["Delia Rourke"]])
    }

    @Test("The results line names the too-large pages of the applied searches' accounts and the latest run's")
    func resultsLineFromAccounts() {
        func scan(tooLarge page: Int, ending: SearchAccount.Ending) -> SearchAccount {
            var account = SearchAccount(pageCount: 10)
            for index in 0..<10 where index != page {
                account.record(PageSearchCoverage(pageIndex: index, route: .textLayer))
            }
            account.record(PageSearchCoverage(pageIndex: page, route: .ocrSkippedOversize))
            account.end(ending)
            return account
        }
        let first = UUID(), second = UUID()
        let applied = RedactionState()
        applied.recordSearchAccount(scan(tooLarge: 1, ending: .completed), token: first)
        applied.recordSearchAccount(scan(tooLarge: 3, ending: .stoppedAtResultLimit(page: 4)), token: second)
        #expect(applied.pagesTooLarge(applied: [first]) == [1, 3])
        #expect(applied.pagesTooLarge(applied: []) == [3], "the earlier Scan's pages only while its results are applied")
    }
}
