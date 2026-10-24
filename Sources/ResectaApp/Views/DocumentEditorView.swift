import SwiftUI
import UIKit
import StoreKit
import PDFKit
import RedactionEngine

// Phase body router — switches on documentState.phase inside a ZStack.
// Toolbar matrix — toolbar items driven by phaseKind.
// Replaces VerificationContainerView approach with full phase router.
// Export state + dialogs lifted here from VerificationResultsView.

struct DocumentEditorView: View {
    @Environment(DocumentState.self) var documentState
    @Environment(RedactionState.self) var redactionState
    @Environment(SettingsState.self) var settingsState
    @Environment(PipelineCoordinator.self) var coordinator
    @Environment(AppCoordinator.self) private var appCoordinator
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) var dynamicTypeSize
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(ToastQueueManager.self) var toastManager
    @Environment(\.requestReview) private var requestReview
    // KI-4: scene-phase observer fires the proactive purge re-run toast
    // on `.background → .active`. See `onScenePhaseChange(old:new:)`.
    // Capture/mirroring privacy shield. When `isShielded` is true
    // the phase-router body is replaced with `PrivacyShieldView` so the
    // canvas (.editing/.detecting/.redacting/.exporting) and verification
    // results (.verified) never reach a screen recorder or external display.
    @Environment(ScreenCaptureMonitor.self) private var captureMonitor

    // View-local tool state — purely UI, no cross-view observation needed.
    // Persistent — toggled only by explicit tap, Escape, or Done.
    @State var activeTool: DrawingTool? = nil

    /// iPhone "Select More" toolbar toggle. While on, a tap on a
    /// region toggles its membership in the selection instead of replacing
    /// the selection — iPhone parity for the iPad Shift+tap path. iPad
    /// Shift+tap continues to work whether the toggle is on or off.
    @State var isMultiSelectActive: Bool = false


    // Brief status flash state for .verifying → .verified transition
    @State private var showBriefStatus = false
    @State private var briefStatus: VerificationStatus?
    @State private var dismissTask: Task<Void, Never>?

    // Batch delete confirmation

    // Done confirmation for the verification results screen.
    // Lifted from VerificationActionBar when Done moved into the top-left
    // toolbar. The dialog gates only when drawn regions are present —
    // empty sessions close directly. Since the 1.1.0 Home swap the
    // editing-phase Home entry shares it (`handleHomeTap()`, gated by
    // `homeNeedsCloseConfirm`).
    @State var showDoneConfirmation = false

    /// The shared close dialog cannot present while the
    /// editor's `.sheet(item:)` slot is presenting — UIKit refuses a second
    /// presentation on the same host and SwiftUI tears the sheet down
    /// instead (no dialog; a staged review discarded with the sheet).
    /// `handleHomeTap()` therefore parks a presented sheet first and raises
    /// this flag; the slot's `onDismiss` presents the dialog once the sheet
    /// is actually down. A second Home tap during the park is absorbed.
    @State var homeCloseAwaitsSheetDismissal = false
    @State var settingsAwaitsSheetDismissal = false  // Settings opens once the parked sheet is down

    /// A search session parked for the close dialog, kept whole for Cancel
    /// (`restoreParkedSearchIfNeeded()`); Close drops it with the session.
    @State var parkedEditorSearch: SearchState?

    // Drives the bespoke share-risk confirm sheet shown when a
    // Share tap reaches handleExportTap while the report is FAIL/ATTENTION
    // (not yet overridden), SKIPPED (not yet acknowledged), or an
    // incomplete-WARN (digest-dependent layers skipped, not yet
    // acknowledged). One optional-enum slot replaces the former two
    // booleans — the three families are mutually exclusive by
    // overallStatus, so at most one case is ever non-nil, and the type
    // itself now says so rather than a convention across two Bools.
    @State private var shareRiskConfirmKind: ShareRiskConfirmKind?
    @State private var shareConcealedPages: [Int] = []   // ConcealingAnnotations.pages, read at the Share tap
    @State private var exportingReport: VerificationReport?   // the export in flight returns to it

    // iPad hover popover state

    // Search sheet detent for auto-minimize on result navigation
    @State var searchSheetDetent: PresentationDetent = .medium

    // Detection summary banner
    @State var detectionBanner: DetectionBannerModel?
    @State var dismissSummaryTask: Task<Void, Never>?

    /// Bindings to trigger import/settings from parent ContentView
    @Binding var showSettings: Bool

    enum DrawingTool {
        case rectangle
    }

    /// P1.3: single sheet slot for the editor. Precedence search >
    /// rationale is enforced by the binding's getter so two
    /// near-simultaneous transitions in the same runloop tick can't drop a
    /// sheet silently.
    private enum ActiveSheet: Identifiable {
        case search(SearchState)
        case rationale(UUID)

        var id: String {
            switch self {
            case .search(let state): return "search-\(state.id)"
            case .rationale(let regionID): return "rationale-\(regionID)"
            }
        }
    }

    /// Map a `DrawingTool` to the overlay's `ShapeTool`. `nil` is
    /// `.rectangle` (the overlay ignores `activeShapeTool` when
    /// `isDrawingMode == false`). Static so it is unit-testable.
    static func shapeTool(for tool: DrawingTool?) -> RedactionOverlayView.ShapeTool {
        switch tool {
        case .none, .some(.rectangle): return .rectangle
        }
    }

    // MARK: - Body (Phase Router)

    var body: some View {
        // ZStack with phase switch (FB91311311 workaround)
        ZStack {
            // When capture/mirroring is active, swap the phase
            // router for the opaque shield. Empty state has no document
            // content, but we shield it anyway — this is the simplest
            // way to keep the threat model uniform (no doc-chrome leakage
            // about whether a document is loaded) and matches the shield's
            // posture against partial redaction.
            if captureMonitor.isShielded {
                PrivacyShieldView()
                    .transition(.opacity)
            } else {
            switch documentState.phase {
            case .empty:
                // Phase 1 redesign: `.empty` no longer renders a hero —
                // it flashes Color.clear and bounces back to HomeView via
                // appCoordinator.returnHome(). One yield absorbs
                // the transient `.empty` during workspace bootstrap
                // (HomeView.openSampleDocument creates a workspace whose
                // initial phase is `.empty` for a frame before
                // ImportService.loadSampleDocument flips it to `.editing`).
                // The gate confirms we're still genuinely idle before
                // calling returnHome().
                Color.clear
                    .task {
                        await Task.yield()
                        guard Self.shouldAutoReturnHome(
                            phaseKind: documentState.phaseKind,
                            sourceDocument: documentState.sourceDocument
                        ) else { return }
                        appCoordinator.returnHome()
                    }
                    .transition(.opacity)

            case .importing:
                // Styled import card matching PipelineProgressCard visual.
                // Import is
                // now cancellable. The Cancel button routes through the same
                // `cancelActivePipeline` path the scene-phase observer uses
                // (see `ContentView.onChange(of: scenePhase)`); the import
                // task is stored on `documentState.activeImportTask` and the
                // detached per-page loops in `ImportService.validatePDFOffMainActor`
                // surrender on the next `Task.checkCancellation()` check.
                VStack(spacing: ResectaTokens.Spacing.sm) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Importing\u{2026}")
                        .font(.headline)
                    Button("Cancel", systemImage: "xmark.circle") {
                        documentState.cancelActivePipeline(redactionState: redactionState)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .accessibilityIdentifier("cancelImport")
                    .padding(.top, ResectaTokens.Spacing.sm)
                }
                .padding(ResectaTokens.Spacing.lg)
                .containerRelativeFrame(.horizontal) { length, _ in
                    // WP8: Adaptive width — wider on iPad landscape
                    if length > 700 { min(length * 0.5, 480) }
                    else { min(length * 0.85, 320) }
                }
                .background(.regularMaterial, in: RoundedRectangle(
                    cornerRadius: ResectaTokens.CornerRadius.sheet, style: .continuous))
                .transition(.opacity)

            case .editing, .detecting, .redacting, .exporting:
                // Shared PDFDocumentView mount — PipelineProgressCard overlay
                PDFDocumentView(
                    isDrawingMode: activeTool != nil,
                    activeShapeTool: Self.shapeTool(for: activeTool),
                    isMultiSelectActive: isMultiSelectActive
                )
                    .disabled(documentState.phaseKind != .editing)
                    .blur(radius: documentState.phaseKind != .editing ? 3 : 0,
                          opaque: false)
                    .overlay {
                        if documentState.phaseKind != .editing {
                            PipelineProgressCard(onCancelExport: exportFlow.cancelExport)
                                .transition(.opacity)
                        }
                    }
                    .overlay(alignment: .top) { topBannerSlot }
                    // (Note: the mid-verify background-resume
                    // banner that used to chain here was structurally
                    // unreachable — it gated on `.verified(report: .skipped)`,
                    // a phase whose router branch renders
                    // `VerificationResultsView`, never this overlay chain.
                    // The recovery CTA now lives on the results screen as the
                    // Run Verification card; see `handleRunVerificationTap`.)
                    .overlay(alignment: .bottom) { captionOverlay }

            case .verifying:
                // Full-screen replacement — verification is a distinct workflow phase
                // Folded the
                // hand-rolled reduceMotion ternary into the resolver —
                // identical behavior, one canonical seam.
                VerificationProgressView()
                    .transition(ResectaTokens.Anim.resolvedTransition(
                        standard: .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .opacity),
                        reduceMotion: reduceMotion))

            case .verified(let report):
                VerificationResultsView(
                    report: report,
                    canExport: exportFlow.canExport(report: report),
                    outputExists: exportFlow.outputFileExists,
                    isVerificationStale: redactionState.isVerificationStale,
                    previewAvailable: exportFlow.previewAvailable,
                    onExport: { exportFlow.handleExportTap(report: report) },
                    onRunVerification: { handleRunVerificationTap() },
                    deselectionSnapshot: redactionState.lastRunInputs?.deselection,
                    runFacts: VerificationResultsView.RunFacts.derive(
                        inputs: redactionState.lastRunInputs)
                )
                .transition(.opacity)

            case .failed(let error, let returnPhase):
                FailedStateView(error: error, returnPhase: returnPhase)
                    .transition(.opacity)
            }
            } // End of `else` branch on captureMonitor.isShielded
        }
        .animation(ResectaTokens.Anim.resolved(ResectaTokens.Anim.modeTransition, reduceMotion: reduceMotion),
                   value: documentState.phaseKind)
        // Also animate the shield in/out so the swap reads as a
        // deliberate transition rather than a flash.
        .animation(ResectaTokens.Anim.resolved(ResectaTokens.Anim.modeTransition, reduceMotion: reduceMotion),
                   value: captureMonitor.isShielded)
        // KI-4: Proactive purge re-run prompt. iOS can reclaim the pipeline's
        // temp output PDF while the app is backgrounded; when the user returns,
        // surface a `.warning` toast with a Re-run action rather than waiting
        // for them to tap Share and hit the `FailedStateView` Tier-2 path.
        // Gate on `.background → .active` (not `.inactive → .active`, which
        // also fires on app-switcher and control-center transits) and only
        // when the current phase still holds an output reference. See
        // `KNOWN_ISSUES.md` KI-4.
        .modifier(DocumentEditorScenePhaseHandler())
        // Consolidated phase change handler (was two separate .onChange)
        .onChange(of: documentState.phaseKind) { oldKind, newKind in
            // Brief status flash for .verifying → .verified transition
            if oldKind == .verifying, newKind == .verified,
               case .verified(let report) = documentState.phase {
                withAnimation(ResectaTokens.Anim.colorTransition) {
                    briefStatus = report.overallStatus
                    showBriefStatus = true
                }
                dismissTask?.cancel()
                dismissTask = Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    guard !Task.isCancelled else { return }
                    withAnimation(ResectaTokens.Anim.overlayDismiss) {
                        showBriefStatus = false
                        briefStatus = nil
                    }
                }
            }
        }
        // Brief status flash overlay
        .overlay {
            if showBriefStatus, let status = briefStatus {
                ZStack {
                    Color.black.opacity(ResectaTokens.Opacity.scrim)
                        .ignoresSafeArea()

                    VStack(spacing: ResectaTokens.Spacing.sm) {
                        Image(systemName: status.symbolName)
                            .font(.system(size: 48))
                            .foregroundStyle(status.color)
                            .symbolRenderingMode(.hierarchical)
                            .contentTransition(.symbolEffect(.replace))

                        Text(status.title)
                            .font(.title3.bold())
                    }
                    .padding(ResectaTokens.Spacing.lg)
                    .containerRelativeFrame(.horizontal) { length, _ in
                        min(length * 0.85, 320)
                    }
                    .background(.regularMaterial, in: RoundedRectangle(
                        cornerRadius: ResectaTokens.CornerRadius.sheet, style: .continuous))
                }
                .transition(.opacity)
            }
        }
        // P1.3: single `.sheet(item:)` slot for search / rationale.
        // Precedence search > rationale; the getter returns the
        // highest-precedence active source. The slot sits ABOVE the phase
        // switch, so a live session would ride over every phase;
        // The Apply seam keeps it out of the pipeline phases by tearing the
        // session down at the Apply seam (`runFullPipeline`), the one funnel
        // every run goes through, the purge re-run included.
        .sheet(item: Binding<ActiveSheet?>(
            get: {
                if let searchState = redactionState.activeSearch { return .search(searchState) }
                if let regionID = redactionState.pendingCanvasRationaleRequest {
                    return .rationale(regionID)
                }
                return nil
            },
            set: { newValue in
                if newValue == nil {
                    // Clear whichever source was driving the sheet. Order
                    // mirrors the getter's precedence so the active source
                    // is the one cleared.
                    //
                    // Deferral pattern: SwiftUI
                    // invokes this set: closure inside its own update/dismiss
                    // transaction. Mutating @Observable state here is re-entrant
                    // within an active update pass — the same class as the fixed
                    // `.sheet(isPresented:)` crash (activeSearch=nil fires a
                    // didSet that writes further state). Defer each write one runloop turn via
                    // `Task { @MainActor }`. The synchronous reads snapshot which
                    // arm to clear (the values are already committed inside the
                    // update pass); only the write is deferred. The in-Task
                    // re-check guard prevents a double-dismiss if a concurrent
                    // path cleared the state across the one-frame window (the
                    // get: closure above may re-query during it).
                    // A system dismissal (a swipe or a scrim tap) skips the
                    // sheet's own Dismiss, so the notice naming the dropped
                    // matches is read here, from the session about to go.
                    if let session = redactionState.activeSearch {
                        let notice = SearchAndRedactSheet.dismissClearedMessage(for: session)
                        Task { @MainActor in
                            guard redactionState.activeSearch != nil else { return }
                            if let notice { toastManager.enqueue(notice, severity: .info) }
                            redactionState.activeSearch = nil
                        }
                    } else if redactionState.pendingCanvasRationaleRequest != nil {
                        Task { @MainActor in
                            guard redactionState.pendingCanvasRationaleRequest != nil else { return }
                            redactionState.pendingCanvasRationaleRequest = nil
                        }
                    }
                }
            }
        ), onDismiss: {
            if settingsAwaitsSheetDismissal {  // parked for Settings: open it now
                settingsAwaitsSheetDismissal = false
                showSettings = true
            }
            // A sheet parked by `handleHomeTap()` hands off to the
            // close dialog here, once its presentation is actually down.
            guard homeCloseAwaitsSheetDismissal else { return }
            homeCloseAwaitsSheetDismissal = false
            showDoneConfirmation = true
        }) { sheet in
            switch sheet {
            case .search(let searchState):
                SearchAndRedactSheet(searchState: searchState, selectedDetent: $searchSheetDetent)
                    // Conditional dismiss: block swipe-dismiss once the USER has
                    // modified selections this session, so the Dismiss
                    // button's confirmation dialog can't be bypassed.
                    // An untouched sheet swipes away freely (one-tap
                    // dismiss rule).
                    .interactiveDismissDisabled(DocumentState.hasUnappliedSelections(redactionState))
                    // Compact float detent — a fixed hug for the
                    // glanceable handle (`CompactFloatDetent.swift`):
                    // title + the result-nav cluster. The PDF surfaces behind;
                    // every OTHER control lives at medium/large.
                    // Tap-on-row AND the chevron / ⌘G walk drop to
                    // compact; only the J/K keyboard path keeps
                    // the prior large → medium semantics so the list
                    // stays readable while a keyboard user steps.
                    .presentationDetents([.compactFloat, .medium, .large], selection: $searchSheetDetent)
                    // Hide the system drag indicator so the custom
                    // pulsing grabber inside `SearchAndRedactSheet` is the
                    // sole visual cue. Drag still works via the system
                    // gesture on the sheet's top area.
                    .presentationDragIndicator(.hidden)
                    // The compact float exists so the user
                    // can interact with the document beneath it, but
                    // without a background-interaction grant UIKit
                    // routed EVERY outside tap (canvas or toolbar) to
                    // sheet dismissal — silently destroying live scan
                    // results, with the sticky detent re-arming the
                    // trap on the next Scan. Interaction is enabled
                    // only up through the compact detent; medium/large
                    // keep the standard dimmed scrim.
                    .presentationBackgroundInteraction(.enabled(upThrough: .compactFloat))
                    // The `.presentationContentInteraction(.scrolls)` pin
                    // is RETIRED. The dead in-list drags were attributed
                    // to the custom compact float mixed into the
                    // detent set; the probe matrix corrected the
                    // mechanism — `.automatic` cooperation fails only
                    // while the sheet content carries either of two
                    // composition poisons: a NavigationStack wrapper, or
                    // a horizontal chip ScrollView sibling above the
                    // List. Both were removed, so the system default
                    // (.automatic) now arbitrates cooperatively: one
                    // continuous swipe scrolls the list AND grows or
                    // shrinks the sheet at content edges; the grabber
                    // path still resizes; compactFloat, the
                    // background-interaction grant, and the hidden
                    // indicator are all proven compatible. No explicit
                    // contentInteraction modifier — .automatic IS the
                    // arbitration of record.
            case .rationale(let regionID):
                if let rationale = redactionState.rationale(forRegionID: regionID) {
                    RegionRationaleSheet(
                        rationale: rationale,
                        onDismiss: {
                            redactionState.pendingCanvasRationaleRequest = nil
                        }
                    )
                }
            }
        }
        .modifier(EditorAnnouncementObservers(
            documentState: documentState, redactionState: redactionState,
            toastManager: toastManager, undoManager: undoManager))
        // Destructive-action confirmation symmetry for
        // the verification-results Done. Same pattern as the Redact /
        // Delete N Regions / Pre-Export / Override-FAIL dialogs. Copy is
        // mechanism-description — describes what Close does,
        // not an outcome promise. Pinned by
        // VerificationActionBarDoneConfirmationTests.testConfirmationCopyIsMechanismDescription.
        // Shared with the editing-phase Home entry (1.1.0 Home swap,
        // `handleHomeTap()`): title and buttons identical; only the
        // message switches on phase (`closeDialogMessage(phaseKind:)`).
        // Presented through `doneConfirmationPresented`: the
        // binding re-presents a review parked for this dialog when it
        // goes down without Close.
        .confirmationDialog(
            "Close this document?",
            isPresented: doneConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Close", role: .destructive) {
                performDoneCloseSession()
            }
            .accessibilityIdentifier("verificationActionBarDoneConfirm")
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(DocumentEditorView.closeDialogMessage(phaseKind: documentState.phaseKind))
        }
        // The bespoke share-risk confirm sheet (FAIL/ATTENTION,
        // SKIPPED, incomplete-WARN — see ShareRiskConfirmSheet for the
        // lifecycle commentary), extracted into ShareRiskConfirmPresentation.
        // Extraction keeps this body's modifier chain within the
        // type-checker's expression budget (an inline .sheet here pushed it
        // past, same reason the former two-.alert ShareConfirmAlerts was
        // extracted).
        .modifier(ShareRiskConfirmPresentation(
            kind: $shareRiskConfirmKind,
            documentState: documentState,
            deselectionSnapshot: redactionState.lastRunInputs?.deselection,
            beginExport: exportFlow.beginExport, concealedPages: shareConcealedPages
        ))
        .onDisappear {
            dismissSummaryTask?.cancel()
            dismissTask?.cancel()
            // The per-window UndoManager outlives this document; clear
            // its stack on close so stale registrations (and the prior
            // RedactionState they retain) don't bleed into the next document.
            Self.clearUndoStackOnClose(undoManager)
        }
        .onAppear {
            // Forward toast manager and undo manager to coordinator
            coordinator.toastManager = toastManager
            coordinator.undoManager = undoManager
        }
        // Keyboard shortcuts for editing, handled by one modifier
        .modifier(DocumentEditorKeyboard(activeTool: $activeTool, isMultiSelectActive: $isMultiSelectActive))
        .onChange(of: showSettings) { _, shown in if !shown { restoreParkedSearchIfNeeded() } }
        // Add to Selection turns off on a page with no regions (its row
        // unmounts there), through the one tool-and-toggle reset.
        .onChange(of: redactionState.regions[documentState.currentPageIndex]?.isEmpty ?? true) { _, empty in
            if empty, isMultiSelectActive { editorToolbar.resetCanvasTools() }
        }
        // Page navigation bar on iPhone only (editing
        // phase). Extracted to a small helper
        // property so the compact-float inset math stays out of this
        // long modifier chain — see the `.toolbar {}` note below on
        // this file's type-checker budget.
        .safeAreaInset(edge: .bottom) {
            pageNavigationBarInset
        }
        .toolbar { EditorToolbarContent(toolbar: editorToolbar) }
        .navigationTitle(documentTitle)
        .navigationBarTitleDisplayMode(.inline)
        // A different document replacing the open one turns the canvas
        // tools off (the same swap the workspace observes for the undo
        // stack and the toasts).
        .onChange(of: documentState.sourceDocument) { oldDocument, newDocument in
            if RedactWorkspaceView.isDocumentSwap(from: oldDocument, to: newDocument) {
                editorToolbar.resetCanvasTools()
            }
        }
    }

    /// The toolbar TYPE over this editor's state, bindings and actions.
    var editorToolbar: DocumentEditorToolbar {
        DocumentEditorToolbar(
            documentState: documentState, redactionState: redactionState,
            coordinator: coordinator, horizontalSizeClass: horizontalSizeClass,
            undoManager: undoManager,
            activeTool: $activeTool, isMultiSelectActive: $isMultiSelectActive,
            searchSheetDetent: $searchSheetDetent,
            documentOverride: documentOverride, redactButtonDisabled: redactButtonDisabled,
            redactButtonHint: redactButtonHint, handleHomeTap: handleHomeTap,
            homeButton: AnyView(homeButton), pipelineModePicker: AnyView(pipelineModePicker),
            openSettings: openSettings
        )
    }

    /// Phase 1 redesign: gate for the `.empty`-case auto-return-home.
    /// True only when the editor is truly idle on `.empty` with no source
    /// document — protects against the HomeView.openSampleDocument
    /// bootstrap window where the workspace mounts in `.empty` for a
    /// frame before `ImportService.loadSampleDocument` flips it to
    /// `.editing`. The `sourceDocument == nil` half also defends against
    /// a future bootstrap that mounts a document before flipping phase.
    static func shouldAutoReturnHome(
        phaseKind: DocumentState.PhaseKind,
        sourceDocument: PDFDocument?
    ) -> Bool {
        phaseKind == .empty && sourceDocument == nil
    }

    /// Page navigation bar on iPhone only (editing phase) — or the bare
    /// parked-canvas inset when the bar steps aside (a live result walk
    /// at the compact float) or never mounts (single-page documents).
    /// ONE model decides the branch and the inset (`ParkedChromeLayout`);
    /// each branch writes the toast clearance from the same value on
    /// appearance, because the bar coming or going IS the event both
    /// toast hosts wait on (the sheet writes it on its detent changes).
    @ViewBuilder
    private var pageNavigationBarInset: some View {
        let layout = parkedChromeLayout
        Group {
            if layout.showsPageBar {
                PageNavigationBar()
                    .padding(.bottom, layout.canvasBottomInset)
                    .onAppear { toastManager.bottomClearance = layout.toastClearance }
            } else {
                Color.clear
                    .frame(height: layout.canvasBottomInset)
                    .onAppear { toastManager.bottomClearance = layout.toastClearance }
            }
        }
        .animation(
            ResectaTokens.Anim.resolved(
                ResectaTokens.Anim.stateChange, reduceMotion: reduceMotion),
            value: layout.canvasBottomInset
        )
    }

    /// The bottom-chrome model for this editor's current state: the
    /// sheet slot, the detent binding, the published walk liveness, the
    /// document's page count and phase, the size class, and the hug the
    /// detent reports for the current type size.
    var parkedChromeLayout: ParkedChromeLayout {
        ParkedChromeLayout(
            sheetPresented: redactionState.activeSearch != nil,
            detent: searchSheetDetent,
            walkLive: redactionState.walkLive,
            pageCount: documentState.pageCount,
            sizeClass: horizontalSizeClass,
            phase: documentState.phaseKind,
            hugHeight: CompactFloatDetent.hug(for: dynamicTypeSize)
        )
    }

    // MARK: - Drawing-mode caption helpers

    /// Pure static behind the Rectangle button: on ENTRY
    /// the selection and the Add-to-Selection toggle are cleared; on exit
    /// nothing else changes.
    static func drawToolEntryEffects(
        entering: Bool
    ) -> (clearSelection: Bool, disableMultiSelect: Bool) {
        (clearSelection: entering, disableMultiSelect: entering)
    }

    /// Results-screen card: which pipeline the Run Verification
    /// card should drive. Verify-only re-runs the checks against the existing
    /// output; a stale or absent output needs the full pipeline (regions
    /// changed since the run, or the output is gone). Static so the routing
    /// is unit-testable without a SwiftUI host (mirrors `resumeAction`).
    enum RunVerificationRoute: Equatable { case verifyOnly, fullPipeline, blockedBySelections }

    static func runVerificationRoute(
        hasOutput: Bool, isVerificationStale: Bool, hasUnappliedSelections: Bool = false
    ) -> RunVerificationRoute {
        hasOutput && !isVerificationStale ? .verifyOnly : (hasUnappliedSelections ? .blockedBySelections : .fullPipeline)
    }

    /// Action for the Run Verification card on the skipped results screen.
    /// Routes per `runVerificationRoute`. The full-pipeline
    /// leg takes the purge re-run's preamble first: `runFullPipeline`'s start
    /// guard (`redactRefusal(with:)`) reads `.verified` as busy.
    private func handleRunVerificationTap() {
        switch Self.runVerificationRoute(
            hasOutput: redactionState.outputURL != nil,
            isVerificationStale: redactionState.isVerificationStale, hasUnappliedSelections: DocumentState.hasUnappliedSelections(redactionState)
        ) {
        case .verifyOnly:
            coordinator.runVerifyOnly()
        case .blockedBySelections:
            toastManager.enqueue(DocumentState.RedactRefusal.selectedMatches.hint, severity: .info)
        case .fullPipeline:
            Self.prepareForPurgeRerun(
                documentState: documentState,
                redactionState: redactionState
            )
            coordinator.runFullPipeline(documentOverride: documentOverride)
        }
    }


    /// 1.1.0 Home swap (replaces the former
    /// file-import entry): closes the open document and returns to HomeView. Rides the
    /// verification-screen Done teardown behind the shared "Close this
    /// document?" dialog when the session carries work (`handleHomeTap()`);
    /// the return itself is the existing `.empty` auto-return
    /// (`shouldAutoReturnHome`). iPhone only — the enclosing group is
    /// mounted for `.editing` + compact width. No tint of its own: the
    /// group's neutral tint is the pinned toolbar-tint contract.
    @ViewBuilder
    private var homeButton: some View {
        Button("Home", systemImage: "house") {
            handleHomeTap()
        }
        .accessibilityIdentifier("editorHomeButton")
    }

    // MARK: - Export

    /// The export flow (`DocumentEditorView+Export.swift`), built from this
    /// view's environment and its two share-confirm states.
    private var exportFlow: DocumentEditorExportFlow {
        DocumentEditorExportFlow(
            documentState: documentState,
            redactionState: redactionState,
            coordinator: coordinator,
            toastManager: toastManager,
            requestReview: requestReview,
            shareRiskConfirmKind: $shareRiskConfirmKind,
            shareConcealedPages: $shareConcealedPages,
            exportingReport: $exportingReport
        )
    }

    // MARK: - Close

    /// Clear the per-window `UndoManager` stack when the editor
    /// closes. SwiftUI injects one `UndoManager` per window (no `UIDocument`
    /// scoping), so registrations from a closed document otherwise survive into
    /// the next document opened in the same window: stale Undo/Redo button state
    /// and closures whose `registerUndo` target strongly retains the prior
    /// `RedactionState`. Static so the close-path clear is testable without a
    /// SwiftUI host.
    static func clearUndoStackOnClose(_ undoManager: UndoManager?) {
        undoManager?.removeAllActions()
    }

    // MARK: - Computed Properties

    private var documentTitle: String {
        documentState.sourceDocument != nil ? "Resecta" : ""
    }
}
