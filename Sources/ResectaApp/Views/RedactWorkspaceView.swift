import SwiftUI
import PDFKit
import RedactionEngine

// Redact workspace container — extracted from ContentView.
// Owns the navigation container, the drop door and its import state.
// Injects workspace-scoped state into the environment for downstream views.
// NavigationSplitView on iPad, NavigationStack on iPhone.
// The one import source inside the workspace is drag-and-drop; files are
// opened from Home.

struct RedactWorkspaceView: View {
    let workspace: RedactWorkspace
    @Environment(SettingsState.self) private var settingsState
    @Environment(ToastQueueManager.self) private var toastManager
    @Environment(AppCoordinator.self) private var appCoordinator
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    // The capture/mirroring privacy shield gates the iPad page-thumbnail
    // sidebar. Thumbnails are derived from page bitmaps, so they leak the
    // same content the canvas does and must be covered alongside the editor.
    @Environment(ScreenCaptureMonitor.self) private var captureMonitor

    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly

    /// Handle for the in-flight import dispatch. The drop door cancels
    /// the prior task before launching a new one. Without this, two drops
    /// in quick succession
    /// would race two ImportService.importDocument calls against the
    /// same `documentState.activeImportTask` slot — the later
    /// `activeImportTask = workTask` write inside ImportService stomps
    /// the earlier one, so the earlier task's cancellation hook is lost.
    /// Cancelling the prior dispatch at the view layer closes the gap.
    @State private var activeImportDispatch: Task<Void, Never>?

    // Settings sheet
    @State private var showSettings = false

    /// True while a password the sheet submitted is being tried.
    @State private var passwordSubmitInFlight = false

    /// A drop held for the replace dialog while the open document holds
    /// work; nil otherwise. Replace imports it, Cancel lets it go.
    @State private var heldDrop: HeldDrop?

    struct HeldDrop {
        let dropped: DroppedDocument
        let droppedCount: Int
    }

    var body: some View {
        navigationContainer
            // Fire the import-completion toasts when a new document is
            // loaded, for EVERY import path. The Home -> redact load
            // (openRedactWithDocument) runs its import in AppCoordinator AFTER
            // this view mounts, so the in-view post-import calls never covered
            // it — keying off the document swap covers all paths uniformly.
            .onChange(of: workspace.documentState.sourceDocument) { oldDocument, newDocument in
                if Self.isDocumentSwap(from: oldDocument, to: newDocument) {
                    workspace.coordinator.documentDidChange()
                    checkImportToasts()
                }
            }
            // Drag and drop. The dropped file is read inside its transfer
            // (size on disk first, then the bytes), so an oversized drop
            // arrives as a refusal and never as 50 MB of memory. Import
            // sources: Files, Photos (from Home), drag-and-drop.
            .dropDestination(for: DroppedDocument.self) { items, _ in
                guard let dropped = items.first else { return false }
                // The leading bytes decide: a PDF, a JPEG (FF D8 FF), a PNG
                // (89 PNG) or a HEIC/HEIF (an ISO BMFF still-image brand) is
                // admitted; any other image signature is refused at the door
                // with the unsupported-format message the Files import
                // shows. Returning true snaps the payload back, as the gate
                // below does on a rejection.
                if case .bytes(let data) = dropped.payload,
                   !ImportRouter.admitsDroppedPayload(data) {
                    enqueueImportRefusedNotPDFToast()
                    return true
                }
                // The handler returns true on accept and on reject alike,
                // so the system snaps a refused payload back rather than
                // leaving it dangling; a refusal says why in a toast.
                switch Self.dropAdmission(
                    documentState: workspace.documentState,
                    redactionState: workspace.redactionState,
                    door: appCoordinator.openedDoor
                ) {
                case .refuse(let message):
                    toastManager.enqueue(message, severity: .warning)
                case .confirmReplace:
                    heldDrop = HeldDrop(dropped: dropped, droppedCount: items.count)
                case .importNow:
                    startDropImport(dropped, droppedCount: items.count)
                }
                return true
            }
            // The replace dialog for a drop over an open document that
            // holds work: the replace dialog's words, the Close dialog's
            // sentence from its one home.
            .confirmationDialog(
                Self.dropReplaceTitle,
                isPresented: Binding(
                    get: { heldDrop != nil },
                    set: { if !$0 { heldDrop = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(Self.dropReplaceButton, role: .destructive) {
                    if let held = heldDrop {
                        startDropImport(held.dropped, droppedCount: held.droppedCount)
                    }
                    heldDrop = nil
                }
                Button("Cancel", role: .cancel) {
                    heldDrop = nil
                }
            } message: {
                Text(Self.dropReplaceMessage)
            }
            // The password sheet for a locked import, over the failed state
            // the refusal left. A swipe-dismiss is Cancel.
            .sheet(item: Binding(
                get: { workspace.lockedImport },
                set: { if $0 == nil { cancelLockedImport() } }
            )) { hold in
                ImportPasswordSheet(
                    hold: hold,
                    onSubmit: { submitPassword($0, for: hold) },
                    onCancel: cancelLockedImport,
                    isSubmitting: passwordSubmitInFlight
                )
            }
            // Settings sheet
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environment(settingsState)
                    .presentationDetents([.medium, .large])
            }
            // Environment injection — satisfies @Environment reads in
            // DocumentEditorView and all downstream views.
            .environment(workspace.documentState)
            .environment(workspace.redactionState)
            .environment(workspace.coordinator)
    }

    // MARK: - The drop door

    /// What the drop door does with an admitted drop.
    enum DropAdmission: Equatable {
        /// Import at once: no document open, or the open one holds no work.
        case importNow
        /// Hold the drop for the replace dialog: the open document holds work.
        case confirmReplace
        /// Refuse with the sentence: the import gate's, or the sheet's.
        case refuse(String)
    }

    /// The replace dialog's words — those of the replace dialog the
    /// workspace's removed file importer carried — and the Close dialog's
    /// sentence, read from its one home.
    static let dropReplaceTitle = "Replace the open document?"
    static let dropReplaceButton = "Replace"
    static var dropReplaceMessage: String {
        DocumentEditorView.closeDialogMessage(phaseKind: .editing)
    }

    /// A drop that owes the dialog while the editor's sheet is up: the
    /// dialog cannot present over the sheet, so the drop is refused with
    /// the import gate's sentence, naming the sheet's Dismiss.
    static let dropOverSheetMessage = DocumentState.importBlockedOnThisScreenMessage(wayBack: "Dismiss")

    /// Whether a drop owes the replace dialog: a document is open and it
    /// holds work by the Close dialog's own rule
    /// (`DocumentEditorView.homeNeedsCloseConfirm`) — drawn regions, or
    /// selected matches not yet applied.
    static func dropNeedsConfirm(documentState: DocumentState, redactionState: RedactionState) -> Bool {
        documentState.sourceDocument != nil
            && DocumentEditorView.homeNeedsCloseConfirm(
                hasDrawnRegions: redactionState.regions.values.contains { !$0.isEmpty },
                hasUnappliedSelections: DocumentState.hasUnappliedSelections(redactionState))
    }

    /// The drop door's one decision, after the payload's format check: the
    /// import gate refuses first (a run, the results or the error screen
    /// up); then work held asks — or, with the editor's sheet up, refuses —
    /// and anything else imports at once.
    static func dropAdmission(
        documentState: DocumentState, redactionState: RedactionState, door: ImportDoor?
    ) -> DropAdmission {
        if let refusal = documentState.importRefusalMessage(door: door) {
            return .refuse(refusal)
        }
        guard dropNeedsConfirm(documentState: documentState, redactionState: redactionState) else {
            return .importNow
        }
        return DocumentEditorView.sheetSlotIsPresenting(redactionState)
            ? .refuse(dropOverSheetMessage)
            : .confirmReplace
    }

    /// Start the drop's import, cancelling any prior in-flight dispatch so
    /// a rapid double drop does not race two imports for the one
    /// `activeImportTask` slot.
    private func startDropImport(_ dropped: DroppedDocument, droppedCount: Int) {
        activeImportDispatch?.cancel()
        if droppedCount > 1 {
            toastManager.enqueue(
                ImportService.dropOpenedFirstMessage(droppedCount: droppedCount), severity: .info)
        }
        let workspace = workspace
        activeImportDispatch = Task {
            await Self.importDrop(dropped, workspace: workspace)
        }
    }

    /// The drop's import. The phase admission has already passed; the
    /// import reads the bytes again before any parse.
    static func importDrop(_ dropped: DroppedDocument, workspace: RedactWorkspace) async {
        switch dropped.payload {
        case .bytes(let data):
            let outcome = await ImportService.importDocument(
                data: data, door: .drop,
                documentState: workspace.documentState,
                redactionState: workspace.redactionState
            )
            // A locked document waits for its password; the sheet
            // presents over the failed state, the prior document intact
            // beneath it.
            if case .needsPassword(let hold) = outcome {
                workspace.lockedImport = hold
            }
        case .refused(let failure):
            // The door met the refusal before any byte was read (a file
            // over the size cap); it reaches the failed screen the way a
            // failed load does.
            ImportService.refuse(failure, documentState: workspace.documentState)
        }
    }

    // MARK: - Navigation Container

    @ViewBuilder
    private var navigationContainer: some View {
        if horizontalSizeClass == .regular {
            // iPad: NavigationSplitView with page thumbnail sidebar
            NavigationSplitView(columnVisibility: $columnVisibility) {
                // Cover the thumbnail strip with the same opaque shield
                // as the canvas while capture/mirroring is active.
                if captureMonitor.isShielded {
                    PrivacyShieldView()
                } else if workspace.documentState.sourceDocument != nil {
                    PageThumbnailList()
                } else {
                    ContentUnavailableView(
                        "No Document",
                        systemImage: "doc",
                        description: Text("Open a PDF or an image to see pages here.")
                    )
                }
            } detail: {
                detailContent
            }
        } else {
            // iPhone: NavigationStack — sidebar is iPad-only
            NavigationStack {
                detailContent
            }
        }
    }

    // MARK: - Detail Content

    /// DocumentEditorView handles all phases via its phase router.
    @ViewBuilder
    private var detailContent: some View {
        DocumentEditorView(
            showSettings: $showSettings
        )
    }

    // MARK: - Toast Helpers

    /// A new document replaced the one shown, or arrived in an empty
    /// workspace. Its one writer is `ImportService.apply`, so this holds
    /// once per completed import: a cancelled or failed import, and a
    /// pipeline returning to the editor, leave the document as it was.
    /// Static so the rule is testable without a SwiftUI host.
    static func isDocumentSwap(from oldDocument: PDFDocument?, to newDocument: PDFDocument?) -> Bool {
        newDocument != nil && newDocument !== oldDocument
    }

    /// The import-completion toasts: the text-layer notice, for a source
    /// that was encrypted what the redacted copy will carry, and for an
    /// image import how its pages are read.
    private func checkImportToasts() {
        checkTextLayerToast()
        checkEncryptedSourceToast()
        checkImageSourceToast()
    }

    /// The notice for an image import, once per import, never for a PDF:
    /// the pages are read by text recognition and codes are not decoded.
    /// Static so the string is pinned.
    static func imageSourceToast(facts: ImportFacts.Summary) -> String? {
        guard case .images = facts.origin else { return nil }
        return "Image pages are read with on-device text recognition. Barcodes and QR codes are not read."
    }

    private func checkImageSourceToast() {
        guard workspace.documentState.phaseKind == .editing,
              let message = Self.imageSourceToast(facts: workspace.documentState.sourceFacts) else { return }
        toastManager.enqueue(message, severity: .info)
    }

    /// Notify user when text layer detected after import.
    private func checkTextLayerToast() {
        if workspace.documentState.hasAnyTextLayer,
           workspace.documentState.phaseKind == .editing {
            toastManager.enqueue(
                ToastItem(message: "Text layer detected \u{2014} Scan and Search can match text in this document.",
                          severity: .info)
            )
        }
    }

    /// The copy for an encrypted source at import: the restrictions line
    /// when the owner withheld a permission, else the plain line; nil when
    /// the source was not encrypted. Static so the strings are pinned.
    static func encryptedSourceToast(facts: ImportFacts.Summary) -> String? {
        guard facts.wasEncrypted else { return nil }
        return facts.hadRestrictions
            ? "This PDF carries usage restrictions set with an owner password. The redacted copy is built without a password and without those restrictions."
            : "This PDF was password-protected. The redacted copy is built without a password."
    }

    private func checkEncryptedSourceToast() {
        guard workspace.documentState.phaseKind == .editing,
              let message = Self.encryptedSourceToast(facts: workspace.documentState.sourceFacts) else { return }
        toastManager.enqueue(message, severity: .warning)
    }

    // MARK: - The locked import

    /// Try the typed password: the held bytes go back through the import
    /// with it; the outcome updates or releases the hold.
    private func submitPassword(_ password: String, for hold: LockedImportHold) {
        guard !passwordSubmitInFlight else { return }
        passwordSubmitInFlight = true
        activeImportDispatch?.cancel()
        activeImportDispatch = Task {
            defer { passwordSubmitInFlight = false }
            // The import starts from the phase Cancel would return to (the
            // failed state admits no import directly); the editor's
            // empty-phase return to Home waits out the transition, and the
            // import's own `.importing` lands first.
            if workspace.documentState.phaseKind == .failed {
                workspace.documentState.transition(to: ImportPasswordFlow.cancelPhase(returnPhase: hold.returnPhase))
            }
            let outcome = await ImportService.importDocument(
                data: hold.bytes, suggestedType: hold.declaredType, door: hold.door,
                password: password,
                documentState: workspace.documentState,
                redactionState: workspace.redactionState
            )
            var phaseError: PipelineError?
            if case .failed(let error, _) = workspace.documentState.phase { phaseError = error }
            switch ImportPasswordFlow.step(after: outcome, phaseError: phaseError, hold: hold) {
            case .opened, .refusedForAnotherReason:
                workspace.lockedImport = nil
            case .wrongPassword(let next), .cannotOpen(let next):
                workspace.lockedImport = next
            }
        }
    }

    /// Cancel, the swipe and the terminal OK: release the hold, then the
    /// transition the failed card's own action would make.
    private func cancelLockedImport() {
        guard let hold = workspace.lockedImport else { return }
        workspace.lockedImport = nil
        if workspace.documentState.phaseKind == .failed {
            workspace.documentState.transition(to: ImportPasswordFlow.cancelPhase(returnPhase: hold.returnPhase))
        }
    }

    /// Surface the refusal when a dropped payload is not a PDF (an image,
    /// refused at the drop door). The copy is the unsupported-format
    /// message, held on `DocumentState.importRefusedNotPDFMessage`.
    private func enqueueImportRefusedNotPDFToast() {
        toastManager.enqueue(
            DocumentState.importRefusedNotPDFMessage,
            severity: .warning
        )
    }
}
