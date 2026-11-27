import Foundation
import Testing
@testable import RedactionEngine
@testable import ResectaApp

// The pages the stop at Redact names, from the document's closed runs and
// the answered set. Pages are
// zero-based here; the names of the cases count pages from one.

@Suite("Redact stop: the pages it names")
struct RedactStopTests {

    typealias Facts = AccountOfWhatWasRead.Facts

    static func account(_ pages: [Facts], _ ending: SearchAccount.Ending = .completed,
                        recognitionOff: Set<Int> = []) -> SearchAccount {
        var account = SearchAccount(pageCount: pages.count)
        for (page, facts) in pages.enumerated() { account.record(facts, forPage: page) }
        for page in recognitionOff { account.recordRecognitionOff(page: page) }
        account.end(ending)
        return account
    }

    static func text(_ text: String, _ options: SearchOptions = SearchOptions()) -> AppliedSearchQuery {
        AppliedSearchQuery(kind: .text(text), options: options)
    }

    static func unit(_ text: String, _ options: SearchOptions = SearchOptions()) -> RedactStopUnit {
        RedactStopUnit(kind: .text, text: text, options: options)
    }

    /// `count` pages, typed except `scanned`, which recognition did not read.
    static func recognitionOffRun(count: Int, scanned: Set<Int>) -> SearchAccount {
        account((0..<count).map { scanned.contains($0) ? [] : [.ownText] }, recognitionOff: scanned)
    }

    static func off(_ pages: some Sequence<Int>) -> Set<RedactStop.Page> {
        Set(pages.map { RedactStop.Page(page: $0, reason: .line(.recognitionOff)) })
    }

    @Test("Every page that stops Redact is named, and no other: four pages, eight kinds of page, three endings")
    func namesExactlyWhatStops() {
        let facts: [Facts] = [[.ownText], [.ownText, .patternTimedOut], [.ownText, .smallPictures], [.recognitionOff],
                              [], [.recognised], [.ownText, .picturesRequired], [.emptyReadWithInk]]
        var documents: [[Facts]] = [[]]
        for _ in 0..<4 { documents = documents.flatMap { doc in facts.map { doc + [$0] } } }
        var broken: [String] = []
        for document in documents {
            for ending in [SearchAccount.Ending.completed, .stopped(page: 1), .stoppedAtResultLimit(page: 1)] {
                let account = Self.account(document, ending)
                if Set(RedactStop.unreadPages(of: account).map(\.page)) != Set(account.pagesThatStopRedact), broken.count < 5 {
                    broken.append("\(document) \(ending)")
                }
            }
        }
        #expect(broken.isEmpty, "\(broken)")
    }

    @Test("One search, recognition off on 12 scanned pages: the stop names the 12")
    func recognitionOffNamed() {
        let runs: [RedactStop.Run] = [(Self.text("Delia"), Self.recognitionOffRun(count: 20, scanned: Set(0..<12)))]
        #expect(RedactStop.pagesToName(runs: runs, answered: []) == [Self.unit("Delia"): Self.off(0..<12)])
    }

    @Test("The same after Redact Anyway: the tap runs")
    func afterRedactAnyway() {
        let runs: [RedactStop.Run] = [(Self.text("Delia"), Self.recognitionOffRun(count: 20, scanned: Set(0..<12)))]
        #expect(!RedactStop.stops(runs: runs, answered: Self.off(0..<12)))
    }

    @Test("A search that found nothing, recognition failed on 3 pages: the stop names the 3")
    func recognitionFailedNamed() {
        var pages = [Facts](repeating: [.ownText], count: 10)
        for page in [2, 5, 7] { pages[page] = [.recognitionFailed] }
        let named = RedactStop.pagesToName(runs: [(Self.text("Delia"), Self.account(pages))], answered: [])
        #expect(named[Self.unit("Delia")] == Set([2, 5, 7].map { RedactStop.Page(page: $0, reason: .line(.recognitionFailed)) }))
    }

    @Test("Every page read, small pictures on 38: the tap runs")
    func smallPicturesRun() {
        let runs: [RedactStop.Run] = [(Self.text("Delia"), Self.account([Facts](repeating: [.ownText, .smallPictures], count: 38)))]
        #expect(!RedactStop.stops(runs: runs, answered: []))
    }

    @Test("Pages 3 to 9 answered; a second search leaves page 12 unread too: the stop names page 12 only")
    func answeredThenNewPage() {
        let first = Self.recognitionOffRun(count: 14, scanned: Set(2...8))
        let second = Self.recognitionOffRun(count: 14, scanned: Set(2...8).union([11]))
        let named = RedactStop.pagesToName(runs: [(Self.text("Delia"), first), (Self.text("Rourke"), second)],
                                           answered: Self.off(2...8))
        #expect(named == [Self.unit("Rourke"): Self.off([11])])
    }

    @Test("The same search run again with recognition on reads the pages: the tap runs")
    func rerunReads() {
        let first = Self.recognitionOffRun(count: 6, scanned: [1, 4])
        let again = Self.account([[.ownText], [.recognised], [.ownText], [.ownText], [.recognised], [.ownText]])
        #expect(!RedactStop.stops(runs: [(Self.text("Delia"), first), (Self.text("Delia"), again)], answered: []))
    }

    @Test("The result limit on page 8 of 200: page 8 searched in part, pages 9 to 200 not reached")
    func resultLimit() {
        let pages: [Facts] = (0..<200).map { $0 <= 7 ? [.ownText] : [] }
        let named = RedactStop.pagesToName(runs: [(Self.text("Delia"), Self.account(pages, .stoppedAtResultLimit(page: 7)))], answered: [])
        let expected = Set([RedactStop.Page(page: 7, reason: .searchedInPart)])
            .union((8..<200).map { RedactStop.Page(page: $0, reason: .line(.notReached)) })
        #expect(named[Self.unit("Delia")] == expected)
    }

    @Test("A page with ink and no recognised line: named")
    func inkNoLine() {
        let named = RedactStop.pagesToName(runs: [(Self.text("Delia"), Self.account([[.ownText], [.emptyReadWithInk]]))], answered: [])
        #expect(named[Self.unit("Delia")] == [RedactStop.Page(page: 1, reason: .line(.recognitionFoundNoText))])
    }

    @Test("A blank scanned page read by recognition runs; with recognition off it stops")
    func blankScannedPage() {
        #expect(!RedactStop.stops(runs: [(Self.text("Delia"), Self.account([[.ownText], [.emptyReadBlank]]))], answered: []))
        #expect(RedactStop.stops(runs: [(Self.text("Delia"), Self.recognitionOffRun(count: 2, scanned: [1]))], answered: []))
    }

    @Test("A search whose results were all declined still counts: the stop opens")
    func declinedStillCounts() {
        // The log holds every run, applied or not; nothing here asks what was applied.
        #expect(RedactStop.stops(runs: [(Self.text("Delia"), Self.recognitionOffRun(count: 3, scanned: [2]))], answered: []))
    }

    @Test("Runs replaced while typing kept no account; the one that completed read every page: the tap runs")
    func replacedWhileTyping() {
        // The replaced runs are not in the log's closed runs (SearchRunLogTests); only the last is.
        #expect(!RedactStop.stops(runs: [(Self.text("Delia"), Self.account([[.ownText], [.ownText]]))], answered: []))
    }

    @Test("After Redact Anyway for pages 3 to 9, a second search leaves the same pages unread for the same reason: the tap runs")
    func sameReasonAnswered() {
        let runs: [RedactStop.Run] = [(Self.text("Delia"), Self.recognitionOffRun(count: 10, scanned: Set(2...8))),
                                      (Self.text("Rourke"), Self.recognitionOffRun(count: 10, scanned: Set(2...8)))]
        #expect(!RedactStop.stops(runs: runs, answered: Self.off(2...8)))
    }

    @Test("Whole Word off, then on, both with recognition off; the Whole Word off unit run again with recognition on: the tap runs")
    func wholeWordOffRerun() {
        let loose = SearchOptions(wholeWord: false), strict = SearchOptions(wholeWord: true)
        let unread = Self.recognitionOffRun(count: 10, scanned: [2, 4, 8])
        let read = Self.account((0..<10).map { [2, 4, 8].contains($0) ? [.recognised] : [.ownText] })
        let runs: [RedactStop.Run] = [(Self.text("Hartwell", loose), unread), (Self.text("Hartwell", strict), unread),
                                      (Self.text("Hartwell", loose), read)]
        #expect(!RedactStop.stops(runs: runs, answered: []))
    }

    @Test("As with Whole Word off, then on, but the Whole Word on unit is run again: the Whole Word off unit is still named")
    func wholeWordOnRerun() {
        let loose = SearchOptions(wholeWord: false), strict = SearchOptions(wholeWord: true)
        let unread = Self.recognitionOffRun(count: 10, scanned: [2, 4, 8])
        let read = Self.account((0..<10).map { [2, 4, 8].contains($0) ? [.recognised] : [.ownText] })
        let runs: [RedactStop.Run] = [(Self.text("Hartwell", loose), unread), (Self.text("Hartwell", strict), unread),
                                      (Self.text("Hartwell", strict), read)]
        #expect(RedactStop.pagesToName(runs: runs, answered: []) == [Self.unit("Hartwell", loose): Self.off([2, 4, 8])])
    }

    @Test("A search read every page, then ran again and stopped, or reached the limit: the tap runs")
    func readThenStopped() {
        let complete = Self.account([Facts](repeating: [.ownText], count: 6))
        let stopped = Self.account([[.ownText], [.ownText], [], [], [], []], .stopped(page: 1))
        let limited = Self.account([[.ownText], [.ownText], [.ownText], [.ownText], [], []], .stoppedAtResultLimit(page: 3))
        #expect(!RedactStop.stops(runs: [(Self.text("Delia"), complete), (Self.text("Delia"), stopped)], answered: []))
        #expect(!RedactStop.stops(runs: [(Self.text("Delia"), complete), (Self.text("Delia"), limited)], answered: []))
    }

    @Test("A Scan's account is taken whole: a term that ran out of time stops Redact")
    func scanTakenWhole() {
        var scan = Self.account([[.ownText], [.ownText]])
        scan.recordPatternTimedOut(page: 1, text: "[A-Z]{2}[0-9]{6}")
        let runs: [RedactStop.Run] = [(AppliedSearchQuery(kind: .piiScan(categories: []), options: SearchOptions()), scan)]
        #expect(RedactStop.stops(runs: runs, answered: []))
    }
}

extension RedactStop {
    /// For the tests: the stop opens at the Redact tap when it names a page.
    static func stops(runs: [Run], answered: Set<Page>) -> Bool {
        !namedPages(runs: runs, answered: answered).isEmpty
    }
}
