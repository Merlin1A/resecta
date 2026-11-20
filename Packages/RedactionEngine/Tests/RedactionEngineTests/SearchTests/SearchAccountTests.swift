import Foundation
import Testing
@testable import RedactionEngine

// The public face of the account: the lines it gives agree with the
// internal summary for every three-page document built from the facts a
// page can carry, under each ending. Page numbers in names are one-based.
@Suite("Search account: the public face")
struct SearchAccountTests {

    typealias Facts = AccountOfWhatWasRead.Facts

    /// The fact sets a page can carry, from the searcher's reports and the app's two signals.
    static let pageFacts: [Facts] = [
        [], [.ownText], [.ownText, .anotherAppsLayer], [.recognised], [.emptyReadWithInk], [.emptyReadBlank],
        [.ownText, .picturesRequired], [.ownText, .smallPictures], [.ownText, .picturesRequired, .recognitionOff],
        [.recognitionOff], [.recognitionFailed], [.tooLarge], [.unopenable], [.ownText, .patternTimedOut],
        [.ownText, .picturesRequired, .tooLarge],
    ]
    static let endings: [SearchAccount.Ending] = [.completed, .stoppedAtResultLimit(page: 1), .stopped(page: 2)]

    static func account(_ pages: [Facts], _ ending: SearchAccount.Ending) -> SearchAccount {
        var account = SearchAccount(pageCount: pages.count)
        for (page, facts) in pages.enumerated() { account.record(facts, forPage: page) }
        account.end(ending)
        return account
    }

    @Test("The lines stand in sentence 7's order, with the five picture causes together")
    func order() {
        #expect(SearchAccount.LineReason.order == [
            .couldNotBeOpened, .recognitionFailed, .recognitionFoundNoText, .tooLarge, .recognitionOff,
            .picturesNotRead(.recognitionFailed), .picturesNotRead(.recognitionFoundNoText),
            .picturesNotRead(.tooLarge), .picturesNotRead(.recognitionOff), .picturesNotRead(.notReported),
            .patternTimedOut, .notReached, .noReport,
        ])
    }

    @Test("Every page that stops Redact is in a line or is the stop page, and no line names another page")
    func linesCoverWhatStopsRedact() {
        var documents = 0
        for a in Self.pageFacts { for b in Self.pageFacts { for c in Self.pageFacts { for ending in Self.endings {
            let account = Self.account([a, b, c], ending)
            let summary = account.account.summary
            var named = Set<Int>()
            for reason in SearchAccount.LineReason.order { named.formUnion(account.pages(for: reason)) }
            let stopping = Set(account.pagesThatStopRedact)
            let stop = account.stopPage.map { Set([$0]) } ?? []
            #expect(named.isSubset(of: stopping), "\(a) \(b) \(c) \(ending)")
            #expect(stopping.subtracting(named).isSubset(of: stop), "\(a) \(b) \(c) \(ending)")
            let causes = SearchAccount.PictureCause.allCases.map { account.pages(for: .picturesNotRead($0)) }
            let pictured = causes.flatMap { $0 }
            #expect(pictured.count == Set(pictured).count, "a page is given one cause: \(a) \(b) \(c)")
            #expect(account.qualifiedPages == summary.qualifiedPages)
            #expect(account.quietPages == summary.quietPages)
            #expect(account.plainNoMatchAllowed == summary.plainNoMatchAllowed)
            #expect(account.ending == ending)
            documents += 1
        } } } }
        #expect(documents == 15 * 15 * 15 * 3)
    }

    @Test("A typed page with a large picture and recognition off gives one line: pictures not read, recognition off")
    func onePictureCause() {
        let account = Self.account([[.ownText], [.ownText, .picturesRequired, .recognitionOff]], .completed)
        #expect(account.pages(for: .picturesNotRead(.recognitionOff)) == [1])
        #expect(account.pages(for: .picturesNotRead(.notReported)) == [])
    }

    @Test("Pictures that had to be read, with no cause reported, are their own line and stop Redact")
    func notReported() {
        let account = Self.account([[.ownText, .picturesRequired]], .completed)
        #expect(account.pages(for: .picturesNotRead(.notReported)) == [0])
        #expect(account.pagesThatStopRedact == [0])
    }

    @Test("A page no report reached in a completed run is the no-report line, after not reached")
    func noReport() {
        let account = Self.account([[.ownText], []], .completed)
        #expect(account.pages(for: .noReport) == [1])
        #expect(SearchAccount.LineReason.order.last == .noReport)
    }

    @Test("Not reached is the pages after the stop page; the stop page is given apart")
    func notReached() {
        let account = Self.account([[.ownText], [.ownText], [], []], .stopped(page: 1))
        #expect(account.stopPage == 1)
        #expect(account.pages(for: .notReached) == [2, 3])
    }

    @Test("Two accounts with the same reports and ending are equal and hash alike")
    func hashable() {
        let one = Self.account([[.ownText], [.recognised]], .stopped(page: 1))
        let two = Self.account([[.ownText], [.recognised]], .stopped(page: 1))
        #expect(one == two)
        #expect(Set([one, two]).count == 1)
        #expect(one != Self.account([[.ownText], [.recognised]], .completed))
    }
}
