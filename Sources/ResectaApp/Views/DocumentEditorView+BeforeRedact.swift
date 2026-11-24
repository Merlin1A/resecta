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
        case .searchThesePages, .cancel, .swipedDown:
            coordinator.cancelRefusalAwaitingAnswer()
        case .goToPage(let page):
            coordinator.cancelRefusalAwaitingAnswer()
            PageNavigationBar.showPage(page, documentState: documentState, redactionState: redactionState)
        }
    }

    /// The view half of an answer. A run or a new Search drops the session
    /// parked for the stop; the other answers leave it for the hand-off.
    func answerStop(_ answer: BeforeYouRedactAnswer) {
        let effects = BeforeYouRedactSheet.effects(of: answer)
        if effects.entersRun || effects.opensSearch, let parked = parkedEditorSearch, stopParkedSearch {
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

    /// The stop went down without a run: the session it parked comes back,
    /// unless Home's dialog or Settings is waiting to take the slot.
    func handOffAfterStop() {
        guard stopParkedSearch, !homeCloseAwaitsSheetDismissal, !settingsAwaitsSheetDismissal else { return }
        stopParkedSearch = false
        restoreParkedSearchIfNeeded()
    }
}
