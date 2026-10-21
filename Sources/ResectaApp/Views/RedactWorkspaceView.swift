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

    var body: some View {
        navigationContainer
            // Fire the import-completion toasts when a new document is
            // loaded, for EVERY import path. The Home -> redact load
            // (openRedactWithDocument) runs its import in AppCoordinator AFTER
            // this view mounts, so the in-view post-import calls never covered
            // it — keying off the document swap covers all paths uniformly.
            .onChange(of: workspace.documentState.sourceDocument) { oldDocument, newDocument in
                if Self.isDocumentSwap(from: oldDocument, to: newDocument) {
                    checkImportToasts()
                }
            }
            // Drag and drop (iPad). The dropped file is read inside its
            // transfer (size on disk first, then the bytes), so an
            // oversized drop arrives as a refusal and never as 50 MB of
            // memory.
            .dropDestination(for: DroppedDocument.self) { items, _ in
                guard let dropped = items.first else { return false }
                // Resecta opens PDF files only: an image payload is refused
                // at the door with the unsupported-format message the Files
                // import shows. Returning true snaps the payload back, as
                // the gate below does on a rejection.
                if case .bytes(let data) = dropped.payload,
                   !ImportRouter.admitsDroppedPayload(data) {
                    enqueueImportRefusedNotPDFToast()
                    return true
                }
                // Reject drops while the pipeline is
                // active OR a detection review is open. A drop replaces an
                // open document with no confirmation, so it consults the
                // composed `canStartImport(with:)` gate directly — a stranded
                // triage sheet over a replacement document could stamp the prior
                // document's page-coordinate regions onto the new one. The drop
                // handler returns true on accept; on reject we still return true
                // so the system snaps the payload back rather than leaving it
                // dangling, and we surface the precise reason via toast.
                guard workspace.documentState.canStartImport(with: workspace.redactionState) else {
                    if workspace.documentState.canStartImport {
                        enqueueImportBlockedDuringTriageToast()
                    } else {
                        enqueueImportBlockedToast()
                    }
                    return true
                }
                // Phase admission has already passed by this point; the
                // import reads the bytes again before any parse.
                // Cancel any prior in-flight import
                // dispatch so a rapid double-drop doesn't race two
                // ImportService.importDocument calls.
                activeImportDispatch?.cancel()
                activeImportDispatch = Task {
                    switch dropped.payload {
                    case .bytes(let data):
                        let outcome = await ImportService.importDocument(
                            data: data, door: .drop,
                            documentState: workspace.documentState,
                            redactionState: workspace.redactionState
                        )
                        // A locked document waits for its password; the
                        // sheet presents over the failed state, the prior
                        // document intact beneath it.
                        if case .needsPassword(let hold) = outcome {
                            workspace.lockedImport = hold
                        }
                    case .refused(let failure):
                        // The door met the refusal before any byte was read
                        // (a file over the size cap); it reaches the failed
                        // screen the way a failed load does.
                        ImportService.refuse(failure, documentState: workspace.documentState)
                    }
                }
                return true
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
                    // Reset Detection History also
                    // wipes the live document's in-memory priors — inject
                    // explicitly (mirrors the settingsState line) so the
                    // sheet does not depend on inheriting the outer
                    // workspace environment.
                    .environment(workspace.redactionState)
                    .presentationDetents([.medium, .large])
            }
            // Environment injection — satisfies @Environment reads in
            // DocumentEditorView and all downstream views.
            .environment(workspace.documentState)
            .environment(workspace.redactionState)
            .environment(workspace.coordinator)
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
                        description: Text("Open a PDF to see pages here.")
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

    /// The import-completion toasts: the text-layer notice, and for a
    /// source that was encrypted, what the redacted copy will carry.
    private func checkImportToasts() {
        checkTextLayerToast()
        checkEncryptedSourceToast()
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

    /// Surface the rejection when a drop arrives while the pipeline owns
    /// in-flight state. Mechanism-description copy lives on
    /// `DocumentState.importBlockedDuringPipelineMessage` so unit tests
    /// can assert on the exact string without crossing the View boundary.
    private func enqueueImportBlockedToast() {
        toastManager.enqueue(
            DocumentState.importBlockedDuringPipelineMessage,
            severity: .warning
        )
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

    /// Surface the rejection when a drop arrives while a detection
    /// review (triage) is open for the current document. Mechanism-description
    /// copy lives on `DocumentState.importBlockedDuringTriageMessage` so unit
    /// tests can assert on the exact string without crossing the View boundary.
    private func enqueueImportBlockedDuringTriageToast() {
        toastManager.enqueue(
            DocumentState.importBlockedDuringTriageMessage,
            severity: .warning
        )
    }
}
