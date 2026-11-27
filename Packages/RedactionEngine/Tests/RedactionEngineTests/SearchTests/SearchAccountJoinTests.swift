import Testing
@testable import RedactionEngine

// One text's account from its run, and one text's runs joined for the stop
// at Redact. A page any run read stays read; no later run makes a page worse
// than the latest run alone left it; a page the latest run gave nothing
// stays as the latest left it. Pages are zero-based; names one-based.

@Suite("Search account: one text's account, and its runs joined")
struct SearchAccountJoinTests {

    typealias Facts = AccountOfWhatWasRead.Facts

    static func account(_ pages: [Facts], _ ending: SearchAccount.Ending = .completed) -> SearchAccount {
        var account = SearchAccount(pageCount: pages.count)
        for (page, facts) in pages.enumerated() { account.record(facts, forPage: page) }
        account.end(ending)
        return account
    }

    static func isRead(_ account: SearchAccount, _ page: Int) -> Bool {
        account.account.state(ofPage: page).kind == .read
    }

    // MARK: - One text's account

    @Test("A text that never ran out of time: the run's account apart from the timeout fact")
    func forTextThatNeverTimedOut() {
        var run = Self.account([[.ownText], [.ownText]])
        run.recordPatternTimedOut(page: 1, text: "[0-9]{9}")
        run.recordUnboxedMatch(page: 0, text: "Delia Rourke")
        var expected = Self.account([[.ownText], [.ownText]])
        expected.recordUnboxedMatch(page: 0, text: "Delia Rourke")
        #expect(run.forText("Delia") == expected)
        #expect(run.pages(for: .patternTimedOut) == [1])
    }

    @Test("The text that ran out of time keeps its pages, and only its own")
    func forTextThatTimedOut() {
        var run = Self.account([[.ownText], [.ownText], [.ownText]])
        run.recordPatternTimedOut(page: 1, text: "a+")
        run.recordPatternTimedOut(page: 2, text: "b+")
        let a = run.forText("a+")
        #expect(a.pages(for: .patternTimedOut) == [1])
        #expect(a.patternTimedOutTexts == [1: ["a+"]])
    }

    // MARK: - The join over every pair of four-page runs

    @Test("Four pages, every pair of runs: what any run read stays read, and the join stops Redact on no page the latest run alone would not")
    func joinOverEveryPair() {
        let facts: [Facts] = [[.ownText], [.ownText, .patternTimedOut], [.recognitionOff], []]
        var documents: [[Facts]] = [[]]
        for _ in 0..<4 { documents = documents.flatMap { doc in facts.map { doc + [$0] } } }
        let runs = documents.flatMap { [Self.account($0), Self.account($0, .stopped(page: 1))] }
        let stops = runs.map { Set($0.pagesThatStopRedact) }
        let read = runs.map { run in Set((0..<4).filter { Self.isRead(run, $0) }) }
        var broken: [String] = []
        var pairs = 0
        for i in runs.indices {
            for j in runs.indices {
                pairs += 1
                guard let joined = SearchAccount.joined([runs[i], runs[j]]) else { broken.append("nil"); continue }
                let joinedStops = Set(joined.pagesThatStopRedact)
                let everRead = read[i].union(read[j])
                let ok = joinedStops.isSubset(of: stops[j])
                    && everRead.allSatisfy { Self.isRead(joined, $0) }
                    && joinedStops.isDisjoint(with: everRead)
                if !ok, broken.count < 5 { broken.append("\(runs[i].account.facts) \(runs[i].ending) then \(runs[j].account.facts) \(runs[j].ending)") }
            }
        }
        #expect(pairs == 512 * 512)
        #expect(broken.isEmpty, "\(broken)")
    }

    @Test("One run joined alone gives that run's states")
    func joinOfOne() {
        let run = Self.account([[.ownText], [.ownText, .patternTimedOut], [], []], .stopped(page: 1))
        #expect(SearchAccount.joined([run])?.account.states == run.account.states)
        #expect(SearchAccount.joined([]) == nil)
    }

    @Test("A page the latest run gave nothing stays unread, though an earlier run stopped on it with its own text")
    func latestGaveNothing() {
        let earlier = Self.account([[.ownText], [.ownText], []], .stopped(page: 1))
        let latest = Self.account([[.ownText], [], []], .stopped(page: 0))
        let joined = SearchAccount.joined([earlier, latest])
        #expect(joined?.pagesThatStopRedact == [1, 2])
    }

    // MARK: - The paper's rows, at the engine

    /// Two texts read the typed pages with recognition off; the shared re-run
    /// with recognition on reaches the result limit on `limitPage`.
    static func k727(pageCount: Int, scanned: Set<Int>, limitPage: Int) -> SearchAccount? {
        let first = account((0..<pageCount).map { scanned.contains($0) ? [.recognitionOff] : [.ownText] })
        let rerun = account((0..<pageCount).map { page -> Facts in
            page > limitPage ? [] : scanned.contains(page) ? [.recognised] : [.ownText]
        }, .stoppedAtResultLimit(page: limitPage))
        return SearchAccount.joined([first, rerun])
    }

    @Test("K7-27: nine pages, 3, 5 and 9 scanned; the limit on page 5: page 5 in part, page 9 not reached, 6 to 8 not named, no recognition-off group")
    func k727() throws {
        let joined = try #require(Self.k727(pageCount: 9, scanned: [2, 4, 8], limitPage: 4))
        #expect(joined.stopPage == 4)
        #expect(joined.pages(for: .notReached) == [8])
        #expect(joined.pages(for: .recognitionOff).isEmpty)
        #expect(joined.pagesThatStopRedact == [4, 8])
    }

    @Test("K7-35: twelve pages, 3, 5, 9 and 12 scanned: pages 9 and 12 not reached, as a list of two")
    func k735() throws {
        let joined = try #require(Self.k727(pageCount: 12, scanned: [2, 4, 8, 11], limitPage: 4))
        #expect(joined.stopPage == 4)
        #expect(joined.pages(for: .notReached) == [8, 11])
    }

    @Test("K7-33: a search read every page, then ran again and was stopped on page 2: nothing stops Redact")
    func k733() {
        let complete = Self.account([[.ownText], [.ownText], [.ownText], [.ownText]])
        let stopped = Self.account([[.ownText], [.ownText], [], []], .stopped(page: 1))
        let joined = SearchAccount.joined([complete, stopped])
        #expect(joined?.pagesThatStopRedact == [])
        #expect(joined?.stopPage == nil)
    }

    @Test("K7-36: a search completed on a typed document, then stopped at the limit on page 4: nothing is named")
    func k736() {
        let complete = Self.account([Facts](repeating: [.ownText], count: 6))
        let limited = Self.account([[.ownText], [.ownText], [.ownText], [.ownText], [], []], .stoppedAtResultLimit(page: 3))
        let joined = SearchAccount.joined([complete, limited])
        #expect(joined?.pagesThatStopRedact == [])
        #expect(joined?.stopPage == nil)
        #expect(joined?.pages(for: .notReached) == [])
    }

    @Test("Matches with no box are every run's")
    func unboxedJoined() {
        var first = Self.account([[.ownText]])
        first.recordUnboxedMatch(page: 0, text: "A")
        var second = Self.account([[.ownText]])
        second.recordUnboxedMatch(page: 0, text: "B")
        #expect(SearchAccount.joined([first, second])?.unboxedMatchTexts == [0: ["A", "B"]])
    }
}
