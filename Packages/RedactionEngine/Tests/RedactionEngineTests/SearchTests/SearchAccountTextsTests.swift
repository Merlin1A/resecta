import Testing
@testable import RedactionEngine

// What the account keeps per searched text: a run's texts share every page
// fact but one, a pattern running out of time, so the account keeps which
// text ran out on which page. It also keeps, per page, the texts of matches
// that could not be given a box, for the stop at Redact.

@Suite("Search account: what it keeps per searched text")
struct SearchAccountTextsTests {

    @Test("Two texts of one run that differ only by a timeout are told apart")
    func twoTextsDifferOnlyByATimeout() {
        var account = SearchAccount(pageCount: 3)
        for page in 0..<3 { account.record(PageSearchCoverage(pageIndex: page, route: .textLayer)) }
        account.recordPatternTimedOut(page: 1, text: "[0-9]{3}-[0-9]{4}")
        account.end(.completed)
        #expect(account.pages(for: .patternTimedOut) == [1])
        #expect(account.patternTimedOutTexts == [1: ["[0-9]{3}-[0-9]{4}"]])
        #expect(account.patternTimedOutTexts[1]?.contains("Delia") == false, "the other text read page 2 in full")
    }

    @Test("The same text timing out twice on a page is kept once; two texts on one page are both kept")
    func timeoutsPerPage() {
        var account = SearchAccount(pageCount: 1)
        account.recordPatternTimedOut(page: 0, text: "a+")
        account.recordPatternTimedOut(page: 0, text: "a+")
        account.recordPatternTimedOut(page: 0, text: "b+")
        #expect(account.patternTimedOutTexts == [0: ["a+", "b+"]])
    }

    @Test("Matches with no box are kept by page and text, and change no page's state")
    func unboxedMatches() {
        var account = SearchAccount(pageCount: 2)
        for page in 0..<2 { account.record(PageSearchCoverage(pageIndex: page, route: .textLayer)) }
        account.recordUnboxedMatch(page: 1, text: "Delia Rourke")
        account.recordUnboxedMatch(page: 1, text: "Delia Rourke")
        account.end(.completed)
        #expect(account.unboxedMatchTexts == [1: ["Delia Rourke"]])
        #expect(account.plainNoMatchAllowed)
        #expect(account.pagesThatStopRedact.isEmpty, "the stop does not open for a match with no box alone")
    }
}
