import SwiftUI
import RedactionEngine

// The stop at Redact in the editor's one sheet slot: when it shows, what
// each answer does, and the Search session it parks while it is up.

extension DocumentEditorView {

    /// The one line that decides the stop is up: its case awaits an answer
    /// and the document is being edited. The slot's getter asks it first;
    /// the editor's presenting flag, the park and the drop door read it.
    static func sheetSlotShowsStop(stopAwaitsAnswer: Bool, phaseKind: DocumentState.PhaseKind) -> Bool {
        stopAwaitsAnswer && phaseKind == .editing
    }

    /// The stop's case is the refusal awaiting an answer.
    static func stopAwaitsAnswer(_ documentState: DocumentState) -> Bool {
        if case .pagesNotRead = documentState.redactRefusalAwaitingAnswer { return true }
        return false
    }

    var sheetSlotShowsStop: Bool {
        Self.sheetSlotShowsStop(stopAwaitsAnswer: Self.stopAwaitsAnswer(documentState),
                                phaseKind: documentState.phaseKind)
    }

    /// The state half of an answer, through the state part's own calls. Only
    /// Redact Anyway records the pages, and it does so before the run starts.
    static func applyStopAnswer(
        _ answer: BeforeYouRedactAnswer, documentState: DocumentState, redactionState: RedactionState,
        coordinator: PipelineCoordinator, documentOverride: PipelineMode?
    ) {
        switch answer {
        case .redactAnyway:
            coordinator.answerPagesNotReadAndRun(documentOverride: documentOverride)
        case .searchThesePages(let query):
            coordinator.cancelRefusalAwaitingAnswer()
            redactionState.activeSearch = SearchState.reRunSession(for: query)
        case .cancel, .swipedDown:
            coordinator.cancelRefusalAwaitingAnswer()
        case .goToPage(let page):
            coordinator.cancelRefusalAwaitingAnswer()
            PageNavigationBar.showPage(page, documentState: documentState, redactionState: redactionState)
        }
    }

    /// Only a run drops the Search session parked for the stop. Search These
    /// Pages keeps it: the session parked is the user's own, with its terms
    /// and any results not yet applied, and it comes back once the re-run's
    /// session is down.
    static func stopAnswerDropsParkedSearch(_ answer: BeforeYouRedactAnswer) -> Bool {
        BeforeYouRedactSheet.effects(of: answer).entersRun
    }

    /// The session the stop parked comes back when the slot is free: no
    /// Search up (the re-run's session holds it until it closes), and neither
    /// Home's dialog nor Settings waiting to take it.
    static func handOffRestores(stopParkedSearch: Bool, searchUp: Bool,
                                homeWaits: Bool, settingsWaits: Bool) -> Bool {
        stopParkedSearch && !searchUp && !homeWaits && !settingsWaits
    }

    /// The view half of an answer; see `stopAnswerDropsParkedSearch`.
    func answerStop(_ answer: BeforeYouRedactAnswer) {
        if Self.stopAnswerDropsParkedSearch(answer), let parked = parkedEditorSearch, stopParkedSearch {
            stopParkedSearch = false
            parkedEditorSearch = nil
            parked.parkedForHomeClose = false
            parked.cancelSearchWithoutAwait()
        }
        Self.applyStopAnswer(answer, documentState: documentState, redactionState: redactionState,
                             coordinator: coordinator, documentOverride: documentOverride)
    }

    /// A Search session up when the stop's case arrives is parked whole, as
    /// Home's dialog parks it, so its teardown spares it.
    func parkSearchForStop() {
        guard sheetSlotShowsStop, redactionState.activeSearch != nil else { return }
        parkEditorSheet()
        stopParkedSearch = true
    }

    /// The stop went down without a run, or the re-run's session closed: the
    /// session the stop parked comes back when `handOffRestores` says so.
    func handOffAfterStop() {
        guard Self.handOffRestores(stopParkedSearch: stopParkedSearch, searchUp: redactionState.activeSearch != nil,
                                   homeWaits: homeCloseAwaitsSheetDismissal,
                                   settingsWaits: settingsAwaitsSheetDismissal) else { return }
        stopParkedSearch = false
        restoreParkedSearchIfNeeded()
    }
}
