import Testing
@testable import RedactionEngine

// Each searcher report gives one fact (AccountOfWhatWasRead.Facts.init):
// a report the searcher makes for a page too large for recognition is the
// too-large fact, never a page read by recognition; one for a page that
// could not be opened is the could-not-open fact.

@Suite("Account of what was read: each report gives its fact")
struct AccountReportToFactTests {

    typealias Facts = AccountOfWhatWasRead.Facts

    @Test("Each route gives its one fact, and no other")
    func eachRoute() {
        let cases: [(PageSearchCoverage.Route, Facts)] = [
            (.ocr, .recognised),
            (.ocrSkippedOversize, .tooLarge),
            (.ocrUnavailable, .recognitionFailed),
            (.unopenable, .unopenable),
        ]
        for (route, fact) in cases {
            #expect(Facts(PageSearchCoverage(pageIndex: 0, route: route)) == fact, "\(route)")
        }
        #expect(Facts(PageSearchCoverage(pageIndex: 0, route: .textLayer)) == .ownText)
    }

    @Test("A page too large for recognition, folded into a one-page account, is not read: too large")
    func tooLargeFolds() {
        var summary = SearchAccount(pageCount: 1)
        summary.record(PageSearchCoverage(pageIndex: 0, route: .ocrSkippedOversize))
        #expect(summary.pages(for: .tooLarge) == [0])
        #expect(summary.qualifiedPages.isEmpty)
    }

    @Test("A page that could not be opened, folded into a one-page account, is not read: could not be opened")
    func unopenableFolds() {
        var summary = SearchAccount(pageCount: 1)
        summary.record(PageSearchCoverage(pageIndex: 0, route: .unopenable))
        #expect(summary.pages(for: .couldNotBeOpened) == [0])
    }
}
