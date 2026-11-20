import Foundation
import Testing
@testable import ResectaApp
@testable import RedactionEngine

// The stop at Redact as a refusal: its place in the one order, how it is
// shown, the answered set, and the hold: it is not returned until the
// stop's sheet is drawn.

@MainActor
@Suite("Redact stop: the refusal")
struct RedactStopRefusalTests {

    typealias Refusal = DocumentState.RedactRefusal

    @Test("The stop is not returned on this branch: the sheet that shows it is not drawn yet")
    func heldUntilTheSheetIsDrawn() {
        #expect(DocumentState.pagesNotReadReturned == false)
    }

    @Test("K7-T: selected matches waiting or not, against the pages to name: the stop only when pages are unanswered, never ahead of the selections")
    func table() {
        // The pages to name: none; small pictures only; some, not answered;
        // some, all answered; some answered and one new. Only the third and
        // fifth leave a page to name.
        let pagesToName = [false, false, true, false, true]
        var rows = 0
        for waiting in [false, true] {
            for (index, unanswered) in pagesToName.enumerated() {
                let refusal = DocumentState.refusal(unappliedSelections: waiting, hasRegions: true, canStart: true,
                                                    pagesNotRead: unanswered)
                let expected: Refusal? = waiting ? .selectedMatches : unanswered ? .pagesNotRead : nil
                #expect(refusal == expected, "row \(rows): waiting \(waiting), pages \(index)")
                rows += 1
            }
        }
        #expect(rows == 10)
    }

    @Test("K7-19: no regions, and a page not read: the notice, and no sheet; a run that cannot start comes first too")
    func noRegionsWins() {
        #expect(DocumentState.refusal(unappliedSelections: false, hasRegions: false, canStart: true, pagesNotRead: true) == .noRegions)
        #expect(DocumentState.refusal(unappliedSelections: false, hasRegions: true, canStart: false, pagesNotRead: true) == .busy)
    }

    @Test("The stop is a sheet that needs an answer, with no notice and no hint; the others stay notices")
    func presentation() {
        #expect(Refusal.pagesNotRead.presentation == .sheet)
        #expect(Refusal.pagesNotRead.message == nil && Refusal.pagesNotRead.hint.isEmpty)
        for refusal in [Refusal.selectedMatches, .noRegions, .busy] { #expect(refusal.presentation == .notice) }
    }

    @Test("Redact Anyway answers every page the stop names, by page and reason; the tap then runs")
    func answering() {
        let state = RedactionState()
        let token = UUID()
        state.recordSearchRunOpened(token: token, query: AppliedSearchQuery(kind: .text("Delia"), options: SearchOptions()))
        var account = SearchAccount(pageCount: 3)
        account.record(PageSearchCoverage(pageIndex: 0, route: .textLayer))
        account.record(PageSearchCoverage(pageIndex: 1, route: .textLayer))
        account.recordRecognitionOff(page: 2)
        account.end(.completed)
        state.recordSearchAccount(account, token: token)
        #expect(RedactStop.opens(runs: state.closedSearchRuns, answered: state.redactStopAnswered))
        state.answerRedactStop()
        #expect(state.redactStopAnswered == [RedactStop.Page(page: 2, reason: .line(.recognitionOff))])
        #expect(!RedactStop.opens(runs: state.closedSearchRuns, answered: state.redactStopAnswered))
    }
}
