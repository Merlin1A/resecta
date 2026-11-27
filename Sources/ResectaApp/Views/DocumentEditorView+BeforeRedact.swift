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

    /// What the one sheet slot shows: the stop first, once no Search session
    /// holds the slot (a session up when the stop's case arrives is parked
    /// first, so its teardown never runs); then Search, in the phases that
    /// present it; then the canvas rationale.
    static func slotItem(stopUp: Bool, activeSearch: SearchState?, mayPresentSearch: Bool,
                         rationale: UUID?) -> ActiveSheet? {
        if stopUp, activeSearch == nil { return .beforeRedact }
        if let activeSearch, mayPresentSearch { return .search(activeSearch) }
        if let rationale { return .rationale(rationale) }
        return nil
    }

    /// The state half of an answer, as the answer's effects say, through the
    /// state part's own calls. Only Redact Anyway records the pages, and it
    /// does so before the run starts.
    static func applyStopAnswer(
        _ answer: BeforeYouRedactAnswer, documentState: DocumentState, redactionState: RedactionState,
        coordinator: PipelineCoordinator, documentOverride: PipelineMode?
    ) {
        let effects = BeforeYouRedactSheet.effects(of: answer)
        if effects.records, effects.entersRun {
            // One call records the pages and then enters the run.
            coordinator.answerPagesNotReadAndRun(documentOverride: documentOverride)
            return
        }
        if effects.clearsCase { coordinator.cancelRefusalAwaitingAnswer() }
        if effects.opensSearch, case .searchThesePages(let query) = answer {
            redactionState.activeSearch = SearchState.reRunSession(for: query)
        }
        if let page = effects.showsPage {
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

    /// The session the stop parked comes back when the slot is free: the stop
    /// down (the Search sheet taken down for the stop is dismissed while the
    /// stop is up), no Search up (the re-run's session holds it until it
    /// closes), and neither Home's dialog nor Settings waiting to take it.
    static func handOffRestores(stopParkedSearch: Bool, stopUp: Bool, searchUp: Bool,
                                homeWaits: Bool, settingsWaits: Bool) -> Bool {
        stopParkedSearch && !stopUp && !searchUp && !homeWaits && !settingsWaits
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
    /// Home's dialog parks it, so its teardown spares it. The session itself
    /// is parked: the slot's own park answers a stop that is up as Cancel.
    static func parkSearchForStop(stopUp: Bool, redactionState: RedactionState, document: UUID,
                                  parked: inout SearchState?, stopParked: inout Bool) {
        guard stopUp, parkSearchSession(redactionState, document: document, parked: &parked) else { return }
        stopParked = true
    }

    func parkSearchForStop() {
        Self.parkSearchForStop(stopUp: sheetSlotShowsStop, redactionState: redactionState,
                               document: documentState.sourceDocumentToken,
                               parked: &parkedEditorSearch, stopParked: &stopParkedSearch)
    }

    /// Whether the session the stop parked comes back now; when it does, the
    /// stop no longer holds it.
    static func handOffAfterStop(stopUp: Bool, redactionState: RedactionState, homeWaits: Bool,
                                 settingsWaits: Bool, stopParked: inout Bool) -> Bool {
        guard handOffRestores(stopParkedSearch: stopParked, stopUp: stopUp,
                              searchUp: redactionState.activeSearch != nil,
                              homeWaits: homeWaits, settingsWaits: settingsWaits) else { return false }
        stopParked = false
        return true
    }

    /// The stop went down without a run, or the re-run's session closed: the
    /// session the stop parked comes back when `handOffRestores` says so.
    func handOffAfterStop() {
        guard Self.handOffAfterStop(stopUp: sheetSlotShowsStop, redactionState: redactionState,
                                    homeWaits: homeCloseAwaitsSheetDismissal,
                                    settingsWaits: settingsAwaitsSheetDismissal,
                                    stopParked: &stopParkedSearch) else { return }
        restoreParkedSearchIfNeeded()
    }
}
