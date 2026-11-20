import Foundation
import Testing
@testable import RedactionEngine
@testable import ResectaApp

// The statement's rules beyond the table: a worse account never gives a
// better statement (K2-M), a run that did not complete never makes a
// no-match statement, and the paper's named cases. Pages in names are
// one-based; indices are zero-based.

@Suite("Search statement: the rules and the named cases")
struct SearchStatementRuleTests {

    typealias Facts = AccountOfWhatWasRead.Facts

    static func account(_ pages: [Facts], _ ending: SearchAccount.Ending = .completed) -> SearchAccount {
        var account = SearchAccount(pageCount: pages.count)
        for (page, facts) in pages.enumerated() { account.record(facts, forPage: page) }
        account.end(ending)
        return account
    }

    static func empty(_ account: SearchAccount, hidden: Int = 0) -> SearchStatement.Statement {
        SearchStatement.statement(mode: .text, hasResults: false, account: account, hiddenCount: hidden)
    }

    /// Read from its own text or blank, then by recognition or another app's
    /// text, then partly read, then not read: a larger rank is worse.
    static func rank(_ state: AccountOfWhatWasRead.State) -> Int {
        switch state {
        case .readFromOwnText, .readBlank: 0
        case .readByRecognition, .readThroughAnotherAppsText: 1
        default: state.kind == .partlyRead ? 2 : 3
        }
    }

    static func named(_ statement: SearchStatement.Statement, quiet account: SearchAccount) -> Set<Int> {
        var pages = Set(statement.lines.flatMap { $0.pages + ($0.stopPage.map { [$0] } ?? []) })
        if statement.quietCount != nil { pages.formUnion(account.quietPages) }
        return pages
    }

    static func strength(_ headline: SearchStatement.Headline?) -> Int {
        switch headline {
        case .plain: 2
        case .lead, .qualified: 1
        default: 0
        }
    }

    @Test("K2-M: a worse account of the same document and ending never gives a better statement above an empty list")
    func worseNeverBetter() {
        let facts: [Facts] = [[.ownText], [.recognised], [.ownText, .smallPictures], [.ownText, .patternTimedOut],
                              [.recognitionOff], []]
        var pairs = 0
        for pageCount in 1...4 {
            let ending: SearchAccount.Ending = pageCount > 1 ? .stopped(page: 1) : .completed
            for end in [SearchAccount.Ending.completed, ending] {
                var documents: [[Facts]] = [[]]
                for _ in 0..<pageCount { documents = documents.flatMap { doc in facts.map { doc + [$0] } } }
                let accounts = documents.map { Self.account($0, end) }
                let ranks = accounts.map { $0.account.states.map(Self.rank) }
                let statements = accounts.map { Self.empty($0) }
                let named = accounts.indices.map { Self.named(statements[$0], quiet: accounts[$0]) }
                let qualified = accounts.map { Set($0.qualifiedPages) }
                var broken: [String] = []
                for i in accounts.indices {
                    for j in accounts.indices where zip(ranks[i], ranks[j]).allSatisfy({ $0 <= $1 }) {
                        pairs += 1
                        let kept = qualified[i].isSubset(of: qualified[j].union(named[j]))
                        let lines = named[i].isSubset(of: named[j])
                        let weaker = Self.strength(statements[j].headline) <= Self.strength(statements[i].headline)
                        if !(kept && lines && weaker), broken.count < 5 { broken.append("\(documents[i]) then \(documents[j]) \(end)") }
                    }
                }
                #expect(broken.isEmpty, "\(broken)")
            }
        }
        #expect(pairs > 0)
    }

    @Test("A run that did not complete never shows the plain, lead or qualified headline")
    func stoppedRunMakesNoNoMatch() {
        let facts: [Facts] = [[.ownText], [.recognised], [.ownText, .smallPictures], [.recognitionOff], []]
        for a in facts { for b in facts { for c in facts {
            for end in [SearchAccount.Ending.stopped(page: 1), .stoppedAtResultLimit(page: 1)] {
                switch Self.empty(Self.account([a, b, c], end)).headline {
                case .stopped, .stoppedWithRecognition: break
                default: Issue.record("a no-match statement for \([a, b, c]) \(end)")
                }
            }
        } } }
    }

    @Test("K2-01: page 4's recognition failed and nothing matched: the lead, and the recognition count leaves page 4 out")
    func k201() {
        var pages = [Facts](repeating: [.ownText], count: 10)
        pages[3] = [.recognitionFailed]; pages[6] = [.recognised]
        let statement = Self.empty(Self.account(pages))
        #expect(statement.headline == .qualified(1))
        #expect(statement.lines == [SearchStatement.Line(reason: .recognitionFailed, pages: [3])])
    }

    @Test("K2-02: page 7 too large and nothing matched: the too-large line, and never the plain headline")
    func k202() {
        var pages = [Facts](repeating: [.ownText], count: 10)
        pages[6] = [.tooLarge]
        let statement = Self.empty(Self.account(pages))
        #expect(statement.headline == .lead)
        #expect(statement.lines == [SearchStatement.Line(reason: .tooLarge, pages: [6])])
    }

    @Test("K2-03: recognition off on three scanned pages: one line naming the three")
    func k203() {
        var pages = [Facts](repeating: [.ownText], count: 10)
        for page in [1, 4, 8] { pages[page] = [] }
        var account = SearchAccount(pageCount: 10)
        for (page, facts) in pages.enumerated() { account.record(facts, forPage: page) }
        for page in [1, 4, 8] { account.recordRecognitionOff(page: page) }
        account.end(.completed)
        #expect(Self.empty(account).lines == [SearchStatement.Line(reason: .recognitionOff, pages: [1, 4, 8])])
    }

    @Test("K2-04: a typed search stopped on page 6 with results: no headline, and page 6 searched in part with 7 to 10 not reached")
    func k204() {
        var pages = [Facts](repeating: [.ownText], count: 10)
        for page in 6...9 { pages[page] = [] }
        let statement = SearchStatement.statement(
            mode: .text, hasResults: true, account: Self.account(pages, .stopped(page: 5)), hiddenCount: 0)
        #expect(statement.headline == nil)
        #expect(statement.lines == [SearchStatement.Line(reason: .notReached, pages: [6, 7, 8, 9], stopPage: 5)])
    }

    @Test("K2-05 and K2-06: hidden results are counted, ticked or not")
    func k205() {
        let account = Self.account([[.ownText]])
        #expect(SearchStatement.statement(mode: .text, hasResults: true, account: account, hiddenCount: 4).hiddenCount == 4)
        #expect(SearchStatement.statement(mode: .text, hasResults: true, account: account, hiddenCount: 10).hiddenCount == 10)
        #expect(SearchStatement.statement(mode: .text, hasResults: true, account: account, hiddenCount: 0).hiddenCount == nil)
    }

    @Test("K2-07: 38 typed pages with small pictures and nothing matched: the lead, one quiet line of 38, nothing else")
    func k207() {
        let statement = Self.empty(Self.account([Facts](repeating: [.ownText, .smallPictures], count: 38)))
        #expect(statement.headline == .lead)
        #expect(statement.lines.isEmpty)
        #expect(statement.quietCount == 38)
    }

    @Test("K2-09: a page with ink and no recognised line is its own line")
    func k209() {
        let statement = Self.empty(Self.account([[.ownText], [.emptyReadWithInk]]))
        #expect(statement.lines == [SearchStatement.Line(reason: .recognitionFoundNoText, pages: [1])])
    }

    @Test("K2-10: 29 scanned pages read by recognition and one typed page with a logo: qualified 29 and the quiet line")
    func k210() {
        let statement = Self.empty(Self.account([Facts](repeating: [.recognised], count: 29) + [[.ownText, .smallPictures]]))
        #expect(statement.headline == .qualified(29))
        #expect(statement.lines.isEmpty)
        #expect(statement.quietCount == 1)
    }

    @Test("No report: a page no report reached in a completed run is its own line, after not reached and before the quiet line")
    func noReport() {
        let statement = Self.empty(Self.account([[.ownText, .smallPictures], [], [.ownText]]))
        #expect(statement.lines == [SearchStatement.Line(reason: .noReport, pages: [1])])
        #expect(statement.quietCount == 1)
        #expect(statement.headline == .lead)
    }

    @Test("Not reported: pictures that had to be read with no cause given are a picture line of their own, and stop Redact")
    func notReported() {
        let account = Self.account([[.ownText, .picturesRequired]])
        #expect(Self.empty(account).lines == [SearchStatement.Line(reason: .picturesNotRead(.notReported), pages: [0])])
        #expect(account.pagesThatStopRedact == [0])
    }

    @Test("A run stopped on its last page still gives the not-reached line, with none counted")
    func stoppedOnTheLastPage() {
        let statement = Self.empty(Self.account([[.ownText], [.ownText]], .stopped(page: 1)))
        #expect(statement.lines == [SearchStatement.Line(reason: .notReached, pages: [], stopPage: 1)])
        #expect(statement.lines.first?.count == 0)
    }
}
