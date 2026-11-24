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

    /// A page the stop names, for the cases that need one.
    static let somePages: Set<RedactStop.Page> = [RedactStop.Page(page: 2, reason: .line(.recognitionOff))]

    /// A state with one closed Text run over 3 pages: pages 0 and 1 read
    /// from their own text, page 2 with recognition off.
    static func stateWithOneRun(_ state: RedactionState = RedactionState()) -> RedactionState {
        let token = UUID()
        state.recordSearchRunOpened(token: token, query: AppliedSearchQuery(kind: .text("Delia"), options: SearchOptions()))
        var account = SearchAccount(pageCount: 3)
        account.record(PageSearchCoverage(pageIndex: 0, route: .textLayer))
        account.record(PageSearchCoverage(pageIndex: 1, route: .textLayer))
        account.recordRecognitionOff(page: 2)
        account.end(.completed)
        state.recordSearchAccount(account, token: token)
        return state
    }

    @Test("The stop is not returned on this branch: the sheet that shows it is not drawn yet")
    func heldUntilTheSheetIsDrawn() {
        #expect(DocumentState.pagesNotReadReturned == false)
    }

    @Test("Under the hold, a box and a page not read refuse nothing: the tap runs as today")
    func heldRefusesNothing() {
        let coordinator = makeLoadedCoordinator()
        let state = Self.stateWithOneRun(coordinator.redactionState)
        state.regions[0] = [RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), source: .manual)]
        #expect(RedactStop.opens(runs: state.closedSearchRuns, answered: state.redactStopAnswered))
        #expect(coordinator.documentState.redactRefusal(with: state) == nil)
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
                                                    pagesToName: unanswered ? Self.somePages : [])
                let expected: Refusal? = waiting ? .selectedMatches : unanswered ? .pagesNotRead(Self.somePages) : nil
                #expect(refusal == expected, "row \(rows): waiting \(waiting), pages \(index)")
                rows += 1
            }
        }
        #expect(rows == 10)
    }

    @Test("K7-19: no regions, and a page not read: the notice, and no sheet; a run that cannot start comes first too")
    func noRegionsWins() {
        #expect(DocumentState.refusal(unappliedSelections: false, hasRegions: false, canStart: true, pagesToName: Self.somePages) == .noRegions)
        #expect(DocumentState.refusal(unappliedSelections: false, hasRegions: true, canStart: false, pagesToName: Self.somePages) == .busy)
    }

    @Test("The stop is a sheet that needs an answer, with no notice and no hint; the others stay notices")
    func presentation() {
        let stop = Refusal.pagesNotRead(Self.somePages)
        #expect(stop.presentation == .sheet)
        #expect(stop.message == nil && stop.hint.isEmpty)
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
        state.answerRedactStop(RedactStop.namedPages(runs: state.closedSearchRuns, answered: state.redactStopAnswered))
        #expect(state.redactStopAnswered == [RedactStop.Page(page: 2, reason: .line(.recognitionOff))])
        #expect(!RedactStop.opens(runs: state.closedSearchRuns, answered: state.redactStopAnswered))
    }

    @Test("Redact Anyway answers the pages the sheet named, and not a page that became unread after it was shown")
    func answersWhatWasShown() {
        let state = Self.stateWithOneRun()
        let shown = RedactStop.namedPages(runs: state.closedSearchRuns, answered: state.redactStopAnswered)
        #expect(shown == Self.somePages)
        // A second run closes while the sheet is up, leaving page 1 unread.
        let token = UUID()
        state.recordSearchRunOpened(token: token, query: AppliedSearchQuery(kind: .text("Moss"), options: SearchOptions()))
        var account = SearchAccount(pageCount: 3)
        account.record(PageSearchCoverage(pageIndex: 0, route: .textLayer))
        account.recordRecognitionOff(page: 1)
        account.record(PageSearchCoverage(pageIndex: 2, route: .textLayer))
        account.end(.completed)
        state.recordSearchAccount(account, token: token)
        state.answerRedactStop(shown)
        #expect(state.redactStopAnswered == Self.somePages)
        #expect(RedactStop.namedPages(runs: state.closedSearchRuns, answered: state.redactStopAnswered)
            == [RedactStop.Page(page: 1, reason: .line(.recognitionOff))])
    }

    @Test("Answers last while the document is open, and are cleared when it closes or another opens")
    func answersLastWhileOpen() {
        for close in [{ (state: RedactionState) in state.clearAll() }, { (state: RedactionState) in state.clearForNewDocument() }] {
            let state = Self.stateWithOneRun()
            state.answerRedactStop(Self.somePages)
            #expect(!RedactStop.opens(runs: state.closedSearchRuns, answered: state.redactStopAnswered))
            #expect(state.redactStopAnswered == Self.somePages)
            close(state)
            #expect(state.redactStopAnswered.isEmpty)
        }
    }
}
