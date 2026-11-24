import SwiftUI
import RedactionEngine

// Parking the editor's sheet behind another presentation, moved out of
// `DocumentEditorView+Home.swift` and generalised: the Home close dialog
// and Settings both take the search sheet down without dropping its
// session, keep the session whole in `parkedEditorSearch`, and bring it
// back when they close without ending it. The hub stores the parked
// session and the two hand-off flags (an extension adds no storage).

extension DocumentEditorView {

    /// Pure gate for re-presenting a parked search session after the close
    /// dialog went down without Close: the slot idle, the session editing,
    /// and the same document still open (a drop behind the dialog replaces
    /// it; the old session's results would name the wrong pages).
    static func homeCloseShouldRestoreSearch(
        sheetPresented: Bool, phaseKind: DocumentState.PhaseKind, sameDocument: Bool
    ) -> Bool {
        !sheetPresented && phaseKind == .editing && sameDocument
    }

    /// The sheet slot presents a Search session only while the document is
    /// being edited, imported, or shows its failed screen. Every other phase
    /// is a run, its results, a share, or no document, and Search does not
    /// stand over any of them. A new phase has to be decided here.
    static func sheetSlotMayPresentSearch(in phase: DocumentState.PhaseKind) -> Bool {
        switch phase {
        case .editing, .importing, .failed:
            return true
        case .empty, .detecting, .redacting, .verifying, .verified, .exporting:
            return false
        }
    }

    /// A Search session that is present in a phase the slot does not
    /// present it in has to come down.
    static func searchMustComeDown(sessionPresent: Bool, phase: DocumentState.PhaseKind) -> Bool {
        sessionPresent && !sheetSlotMayPresentSearch(in: phase)
    }

    /// Takes the Search session down when it is present outside the slot's
    /// phases, so a session set over a run or its results is neither shown
    /// nor left behind for the editor.
    static func takeDownSearchOutsideItsPhases(
        phase: DocumentState.PhaseKind, redactionState: RedactionState
    ) {
        guard searchMustComeDown(sessionPresent: redactionState.activeSearch != nil, phase: phase) else {
            return
        }
        redactionState.dismissActiveSearch()
    }

    /// Mirrors the `.sheet(item:)` getter: the slot is presenting whenever
    /// either source is live, or the stop at Redact is up.
    var editorSheetIsPresented: Bool {
        Self.editorSlotIsPresenting(documentState: documentState, redactionState: redactionState)
    }

    /// The editor's presenting flag as a pure read: the stop at Redact first,
    /// then the slot's two sources.
    static func editorSlotIsPresenting(documentState: DocumentState, redactionState: RedactionState) -> Bool {
        sheetSlotShowsStop(stopAwaitsAnswer: stopAwaitsAnswer(documentState), phaseKind: documentState.phaseKind)
            || sheetSlotIsPresenting(redactionState)
    }

    /// The slot's rule, readable outside the editor (the workspace's drop
    /// door asks it before presenting its own dialog).
    static func sheetSlotIsPresenting(_ redactionState: RedactionState) -> Bool {
        redactionState.activeSearch != nil
            || redactionState.pendingCanvasRationaleRequest != nil
    }

    /// Take the presenting sheet down without touching the work behind it.
    /// Only `activeSearch` is cleared — the search session is kept whole
    /// in `parkedEditorSearch`, its
    /// results and selections intact, flagged so the sheet's teardown
    /// spares it; a rationale sheet is simply dropped.
    func parkEditorSheet() {
        if sheetSlotShowsStop {
            // The stop goes as a Cancel; a Search it parked is left to the
            // restore of whatever parks the slot now.
            stopParkedSearch = false
            Self.applyStopAnswer(.cancel, documentState: documentState, redactionState: redactionState,
                                 coordinator: coordinator, documentOverride: documentOverride)
        } else if let search = redactionState.activeSearch {
            search.parkedForHomeClose = true
            search.parkedDocument = documentState.sourceDocumentToken
            parkedEditorSearch = search
            redactionState.activeSearch = nil
        } else if redactionState.pendingCanvasRationaleRequest != nil {
            redactionState.pendingCanvasRationaleRequest = nil
        }
    }

    /// Re-present a search session parked for the dialog when it went down
    /// without Close: the same `SearchState` back in the sheet slot. Nothing
    /// when Close already tore the session down (it drops the parked
    /// session) or the slot is busy.
    func restoreParkedSearchIfNeeded() {
        guard let parked = parkedEditorSearch else { return }
        parkedEditorSearch = nil
        parked.parkedForHomeClose = false
        guard Self.homeCloseShouldRestoreSearch(
            sheetPresented: editorSheetIsPresented, phaseKind: documentState.phaseKind,
            sameDocument: parked.parkedDocument == documentState.sourceDocumentToken
        ) else {
            // The slot busy, the session over, or the document replaced
            // behind the dialog: the parked session goes down, as Close
            // takes it down.
            parked.cancelSearchWithoutAwait()
            return
        }
        // Settings may have reset the stored filters while it was parked.
        parked.reloadFilterShape()
        redactionState.activeSearch = parked
    }

    /// The toolbar's Settings: with the sheet slot presenting, park it and
    /// open Settings once it is down (the slot's `onDismiss`); otherwise
    /// open Settings at once. Settings closing restores the session.
    func openSettings() {
        if editorSheetIsPresented {
            settingsAwaitsSheetDismissal = true
            parkEditorSheet()
        } else {
            showSettings = true
        }
    }
}
