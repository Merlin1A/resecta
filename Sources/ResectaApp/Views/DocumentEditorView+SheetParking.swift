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

    /// Mirrors the `.sheet(item:)` getter: the slot is presenting whenever
    /// either source is live.
    var editorSheetIsPresented: Bool {
        Self.sheetSlotIsPresenting(redactionState)
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
        if let search = redactionState.activeSearch {
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
