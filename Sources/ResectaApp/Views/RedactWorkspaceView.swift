import SwiftUI
import PhotosUI
import PDFKit

// Phase 0: Redact workspace container — extracted from ContentView.
// Owns the navigation container, import handlers, and import-related state.
// Injects workspace-scoped state into the environment for downstream views.
// ARCH §5.2: NavigationSplitView (iPad) / NavigationStack (iPhone).
// UI_UX §5.1: Import sources (Files, Photos, drag-and-drop).

struct RedactWorkspaceView: View {
    let workspace: RedactWorkspace
    @Environment(SettingsState.self) private var settingsState
    @Environment(ToastQueueManager.self) private var toastManager
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    // SEC-3: Capture/mirroring privacy shield gates the iPad page-thumbnail
    // sidebar. Thumbnails are derived from page bitmaps, so they leak the
    // same content the canvas does and must be covered alongside the editor.
    @Environment(ScreenCaptureMonitor.self) private var captureMonitor

    // Import state (moved from ContentView)
    @State private var showFilePicker = false
    @State private var showPhotoPicker = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly

    /// RES-06 (Pkg N): handle for the in-flight import dispatch. Each
    /// dispatch site (drop, file picker, photo picker, pending-import
    /// after confirmation) cancels the prior task before launching a
    /// new one. Without this, a rapid double-input (e.g., two drops in
    /// quick succession, or the file picker re-firing on a held button)
    /// would race two ImportService.importDocument calls against the
    /// same `documentState.activeImportTask` slot — the later
    /// `activeImportTask = workTask` write inside ImportService stomps
    /// the earlier one, so the earlier task's cancellation hook is lost.
    /// Cancelling the prior dispatch at the view layer closes the gap.
    @State private var activeImportDispatch: Task<Void, Never>?

    // ARCH §7: Settings sheet
    @State private var showSettings = false

    // D12: Import-while-editing confirmation
    @State private var showImportWhileEditingConfirmation = false
    @State private var pendingImportURL: URL?
    @State private var pendingImportData: Data?

    var body: some View {
        navigationContainer
            // UI_UX §5.1: File importer
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.pdf, .image],
                allowsMultipleSelection: false
            ) { result in
                handleFileImportResult(result)
            }
            // UI_UX §5.1: Photos picker
            .photosPicker(
                isPresented: $showPhotoPicker,
                selection: $selectedPhoto,
                matching: .images,
                photoLibrary: .shared()
            )
            .onChange(of: selectedPhoto) { _, newValue in
                handlePhotoSelection(newValue)
            }
            // Fire the text-layer toast on import completion for EVERY
            // import path. The Home -> redact load (openRedactWithDocument) runs
            // its import in AppCoordinator AFTER this view mounts, so the in-view
            // post-import calls never covered it — keying off the
            // .importing -> .editing transition covers all paths uniformly.
            .onChange(of: workspace.documentState.phaseKind) { oldPhase, newPhase in
                if Self.shouldCheckTextLayerOnImportCompletion(from: oldPhase, to: newPhase) {
                    checkTextLayerToast()
                }
            }
            // ARCH §5.6: Drag and drop (iPad)
            .dropDestination(for: Data.self) { items, _ in
                guard let data = items.first else { return false }
                // Reject drops while the pipeline is
                // active OR a detection review is open. The drag-drop path is
                // the sole importer that bypasses the D12 import-while-editing
                // confirmation the file/photo pickers stage, so it consults the
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
                // Pkg G.1 / TRUST-import-drop-image-deadcode: sniff magic
                // bytes BEFORE dispatch. The previous hardcoded
                // `suggestedType: "pdf"` forced every drop through the
                // PDF branch, making the image branch dead code on this
                // entry point. Phase admission (Pkg D) has already passed
                // by this point; only the routing label is being chosen.
                let suggestedType = ImportService.detectPayloadKind(from: data).suggestedType
                // RES-06 (Pkg N): cancel any prior in-flight import
                // dispatch so a rapid double-drop doesn't race two
                // ImportService.importDocument calls.
                activeImportDispatch?.cancel()
                activeImportDispatch = Task {
                    // SEC-8 override #4: paranoid mode enables the
                    // LivePhotoAuxStripper hook on the import path.
                    await ImportService.importDocument(
                        data: data, suggestedType: suggestedType,
                        documentState: workspace.documentState,
                        redactionState: workspace.redactionState,
                        stripAuxData: settingsState.paranoidMode
                    )
                }
                return true
            }
            // ARCH §7: Settings sheet
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environment(settingsState)
                    // Reset Detection History also
                    // wipes the live document's in-memory priors — inject
                    // explicitly (mirrors the settingsState line) so the
                    // sheet does not depend on inheriting the outer
                    // workspace environment.
                    .environment(workspace.redactionState)
                    .presentationDetents([.medium, .large]) // §A4g
            }
            // D12: Import-while-editing confirmation dialog
            .confirmationDialog(
                "You have a document open",
                isPresented: $showImportWhileEditingConfirmation,
                titleVisibility: .visible
            ) {
                Button("Import New", role: .destructive) {
                    performPendingImport()
                }
                Button("Cancel", role: .cancel) {
                    pendingImportURL = nil
                    pendingImportData = nil
                }
            } message: {
                Text("Importing a new file will replace the current document. Your unsaved changes will be lost.")
            }
            // Environment injection — satisfies @Environment reads in
            // DocumentEditorView and all downstream views.
            .environment(workspace.documentState)
            .environment(workspace.redactionState)
            .environment(workspace.coordinator)
    }

    // MARK: - Navigation Container (UI_UX §10)

    @ViewBuilder
    private var navigationContainer: some View {
        if horizontalSizeClass == .regular {
            // iPad: NavigationSplitView with page thumbnail sidebar
            NavigationSplitView(columnVisibility: $columnVisibility) {
                // SEC-3: cover the thumbnail strip with the same opaque
                // shield as the canvas while capture/mirroring is active.
                if captureMonitor.isShielded {
                    PrivacyShieldView()
                } else if workspace.documentState.sourceDocument != nil {
                    PageThumbnailList()
                } else {
                    ContentUnavailableView(
                        "No Document",
                        systemImage: "doc",
                        description: Text("Open a PDF or image to see pages here.")
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

    /// §A2: DocumentEditorView handles all phases via its phase router.
    @ViewBuilder
    private var detailContent: some View {
        DocumentEditorView(
            showFilePicker: $showFilePicker,
            showPhotoPicker: $showPhotoPicker,
            showSettings: $showSettings
        )
    }

    // MARK: - Import Handlers

    private func handleFileImportResult(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            // Pkg D / STATE-1: file-importer cannot stage a new
            // document while the pipeline holds in-flight state.
            guard workspace.documentState.canStartImport else {
                enqueueImportBlockedToast()
                return
            }
            // D12: Confirm if a document is already open
            if workspace.documentState.sourceDocument != nil {
                pendingImportURL = url
                showImportWhileEditingConfirmation = true
            } else {
                // RES-06 (Pkg N): cancel any prior in-flight import
                // dispatch — see `activeImportDispatch` doc-comment.
                activeImportDispatch?.cancel()
                activeImportDispatch = Task {
                    // SEC-8 override #4: paranoid mode enables the
                    // LivePhotoAuxStripper hook on the import path.
                    await ImportService.importDocument(
                        from: url,
                        documentState: workspace.documentState,
                        redactionState: workspace.redactionState,
                        stripAuxData: settingsState.paranoidMode
                    )
                }
            }
        case .failure:
            // User cancelled or system error — no action needed
            break
        }
    }

    private func handlePhotoSelection(_ item: PhotosPickerItem?) {
        guard let item else { return }
        // Pkg D / STATE-1: photos picker cannot stage a new document
        // while the pipeline holds in-flight state.
        guard workspace.documentState.canStartImport else {
            enqueueImportBlockedToast()
            selectedPhoto = nil
            return
        }
        // RES-06 (Pkg N): cancel any prior in-flight import dispatch —
        // see `activeImportDispatch` doc-comment.
        activeImportDispatch?.cancel()
        activeImportDispatch = Task {
            // Pkg C / ERR-04 + UX-import-photoselection-silent-nil: the
            // prior `try? await item.loadTransferable(...)` swallowed both
            // throws and nil (e.g., iCloud-not-downloaded photo, transferable
            // decode error). The `if let` then fell through with no
            // user-visible signal — indistinguishable from a UI bug. Per
            // S2 §L.4 the preferred routing is the existing Tier 2
            // `FailedStateView` via `.importError(.corrupt)`, so the user
            // lands on the same recovery surface as a corrupt-PDF import.
            let loaded: Data?
            do {
                loaded = try await item.loadTransferable(type: Data.self)
            } catch { // LegalPhrases:safe (Swift keyword)
                loaded = nil
            }
            guard let data = loaded else {
                workspace.documentState.transition(to: .importing)
                workspace.documentState.transition(to: .failed(
                    error: .importError(.corrupt),
                    returnPhase: .empty
                ))
                return
            }
            // D12: Confirm if a document is already open
            if workspace.documentState.sourceDocument != nil {
                pendingImportData = data
                showImportWhileEditingConfirmation = true
            } else {
                // SEC-8 override #4: paranoid mode enables the
                // LivePhotoAuxStripper hook on the import path.
                await ImportService.importDocument(
                    data: data, suggestedType: "image",
                    documentState: workspace.documentState,
                    redactionState: workspace.redactionState,
                    stripAuxData: settingsState.paranoidMode
                )
            }
        }
        // Reset selection so the same photo can be re-selected
        selectedPhoto = nil
    }

    /// D12: Execute the pending import after user confirms replacement.
    private func performPendingImport() {
        // RES-06 (Pkg N): cancel any prior in-flight import dispatch —
        // see `activeImportDispatch` doc-comment.
        activeImportDispatch?.cancel()
        activeImportDispatch = Task {
            if let url = pendingImportURL {
                pendingImportURL = nil
                // SEC-8 override #4: paranoid mode enables the
                // LivePhotoAuxStripper hook on the import path.
                await ImportService.importDocument(
                    from: url,
                    documentState: workspace.documentState,
                    redactionState: workspace.redactionState,
                    stripAuxData: settingsState.paranoidMode
                )
            } else if let data = pendingImportData {
                pendingImportData = nil
                // SEC-8 override #4: paranoid mode enables the
                // LivePhotoAuxStripper hook on the import path.
                await ImportService.importDocument(
                    data: data, suggestedType: "image",
                    documentState: workspace.documentState,
                    redactionState: workspace.redactionState,
                    stripAuxData: settingsState.paranoidMode
                )
            }
        }
    }

    // MARK: - Toast Helpers

    /// The text-layer toast fires once per import — on the import-
    /// completion transition (.importing -> .editing). This is the single signal
    /// for every import path, including the Home -> redact load whose import runs
    /// in `AppCoordinator.openRedactWithDocument` AFTER this view mounts (so the
    /// in-view post-import calls never ran for it — the original gap). Pipeline
    /// returns to .editing (from .detecting/.redacting/.verifying/.verified) and
    /// import failures (.importing -> .failed) do not re-fire it. Static so the
    /// transition rule is testable without a SwiftUI host.
    static func shouldCheckTextLayerOnImportCompletion(
        from oldPhase: DocumentState.PhaseKind,
        to newPhase: DocumentState.PhaseKind
    ) -> Bool {
        oldPhase == .importing && newPhase == .editing
    }

    /// §5.2: Notify user when text layer detected after import.
    private func checkTextLayerToast() {
        if workspace.documentState.hasAnyTextLayer,
           workspace.documentState.phaseKind == .editing {
            toastManager.enqueue(
                ToastItem(message: "Text layer detected \u{2014} searchable redaction available for this document",
                          severity: .info)
            )
        }
    }

    /// Pkg D / STATE-1: surface the rejection when a drop, file picker,
    /// or photos picker invocation arrives while the pipeline owns
    /// in-flight state. Mechanism-description copy lives on
    /// `DocumentState.importBlockedDuringPipelineMessage` so unit tests
    /// can assert on the exact string without crossing the View boundary.
    private func enqueueImportBlockedToast() {
        toastManager.enqueue(
            DocumentState.importBlockedDuringPipelineMessage,
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
