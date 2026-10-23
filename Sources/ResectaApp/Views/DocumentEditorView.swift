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
    @Environment(SettingsState.self) private var settingsState
    @Environment(PipelineCoordinator.self) var coordinator
    @Environment(AppCoordinator.self) private var appCoordinator
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
    @State private var activeTool: DrawingTool? = nil

    /// iPhone "Select More" toolbar toggle. While on, a tap on a
    /// region toggles its membership in the selection instead of replacing
    /// the selection — iPhone parity for the iPad Shift+tap path. iPad
    /// Shift+tap continues to work whether the toggle is on or off.
    @State private var isMultiSelectActive: Bool = false


    // Brief status flash state for .verifying → .verified transition
    @State private var showBriefStatus = false
    @State private var briefStatus: VerificationStatus?
    @State private var dismissTask: Task<Void, Never>?

    // Batch delete confirmation
    @State private var showBatchDeleteConfirmation = false

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

    // iPad hover popover state
    @State private var showHoverPopover = false
    @State private var hoveredMetadata: RegionMetadata?

    // Search sheet detent for auto-minimize on result navigation
    @State var searchSheetDetent: PresentationDetent = .medium

    // Detection summary banner
    @State var detectionBanner: DetectionBannerModel?
    @State var dismissSummaryTask: Task<Void, Never>?
    // WP4a: Auto-dismiss timer for background resume banner
    @State var dismissBannerTask: Task<Void, Never>?

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

    /// Effective pipeline mode: per-document override or global setting.
    private var effectivePipelineMode: PipelineMode {
        documentOverride ?? settingsState.pipelineMode
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
                            PipelineProgressCard()
                                .transition(.opacity)
                        }
                    }
                    // Detection summary banner (all run outcomes,
                    // not just success — zero/failed previously left no
                    // persistent record).
                    .overlay(alignment: .top) {
                        detectionBannerOverlay
                    }
                    // InlineWarningBanner for background resume
                    // (cancel-from-detecting / cancel-from-redacting path).
                    .overlay(alignment: .top) {
                        resumeBannerOverlay
                    }
                    // Import annotation notice: the imported source
                    // carries annotations or filled form fields, which the
                    // on-screen view draws but the export raster (built
                    // from the page content stream) does not include.
                    // Persistent until the user dismisses it; yields to
                    // the two banners above via the visibility predicate
                    // rather than stacking.
                    .overlay(alignment: .top) {
                        let annotationCount = ImportAnnotationNoticeBanner.noticeWorthyCount(
                            documentState.sourceAnnotationFindings)
                        if ImportAnnotationNoticeBanner.isVisible(
                            phaseKind: documentState.phaseKind,
                            annotationTypeCount: annotationCount,
                            filledFormFieldCount: documentState.sourceFilledFormFieldCount,
                            dismissed: documentState.annotationNoticeDismissed,
                            pausedBannerActive: documentState.wasPausedByBackground,
                            detectionBannerActive: detectionBanner != nil
                        ) {
                            ImportAnnotationNoticeBanner(
                                annotationCount: annotationCount,
                                filledFormFieldCount: documentState.sourceFilledFormFieldCount
                            ) {
                                withAnimation(ResectaTokens.Anim.overlayDismiss) {
                                    documentState.annotationNoticeDismissed = true
                                }
                            }
                            // Routed through the resolver so Reduce
                            // Motion swaps the slide for an opacity-only
                            // crossfade.
                            .transition(ResectaTokens.Anim.resolvedTransition(
                                standard: .move(edge: .top).combined(with: .opacity),
                                reduceMotion: reduceMotion))
                            .padding(.top, ResectaTokens.Spacing.toolbarClearance)
                        }
                    }
                    // (Note: the mid-verify background-resume
                    // banner that used to chain here was structurally
                    // unreachable — it gated on `.verified(report: .skipped)`,
                    // a phase whose router branch renders
                    // `VerificationResultsView`, never this overlay chain.
                    // The recovery CTA now lives on the results screen as the
                    // Run Verification card; see `handleRunVerificationTap`.)
                    // Drawing-mode caption — subtle
                    // banner names the active gesture for the rectangle
                    // tool.
                    .overlay(alignment: .bottom) {
                        if DocumentEditorView.drawingModeCaptionShouldShow(
                            activeTool: activeTool,
                            phaseKind: documentState.phaseKind
                        ),
                           let caption = DocumentEditorView.activeDrawingCaption(
                            activeTool: activeTool
                           ) {
                            HStack(spacing: ResectaTokens.Spacing.md) {
                                Text(caption)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                                .padding(.horizontal, ResectaTokens.Spacing.md)
                                .padding(.vertical, ResectaTokens.Spacing.xs)
                                .background(.regularMaterial, in: Capsule())
                                .padding(.bottom, ResectaTokens.Spacing.lg + parkedChromeLayout.hintCapsuleLift)
                                .accessibilityElement(children: .contain)
                                .accessibilityLabel(
                                    DocumentEditorView.captionAccessibilityLabel(
                                        activeTool: activeTool
                                    )
                                )
                                .transition(.opacity)
                        }
                    }

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
        // iPad hover popover — observe hoveredRegionID on RedactionState
        // VoiceOver announcement on selection count change
        .onChange(of: redactionState.selectedRegionIDs.count) { oldCount, newCount in
            guard UIAccessibility.isVoiceOverRunning,
                  documentState.phaseKind == .editing else { return }
            let announcement: String
            switch newCount {
            case 0:  announcement = "Selection cleared"
            case 1:  announcement = "1 region selected"
            default: announcement = "\(newCount) regions selected"
            }
            AccessibilityNotification.Announcement(announcement).post()
        }
        .onChange(of: redactionState.hoveredRegionID) { _, newID in
            if let id = newID, let metadata = redactionState.regionMetadata[id] {
                hoveredMetadata = metadata
                showHoverPopover = true
            } else {
                showHoverPopover = false
            }
        }
        // [R-20]: manual-draw nearby-PII nudge observer. The
        // post-add hook on `RedactionState.addRegion` sets
        // `pendingManualDrawNudge` after a `.manual` region commits
        // adjacent (≤ 50 pt normalized) to an unapplied high-confidence
        // PII match. We enqueue a non-modal info toast with an "Add"
        // action that calls `acceptManualDrawNudge(_:undoManager:)`
        // with the nudge captured by value — closure-capture so the
        // accept path survives the suppression mark
        // below clearing the pending field. The
        // `markManualDrawNudgeSuppressed()` call gates further toasts
        // for the current search session; the suppression
        // resets on any `activeSearch` transition + on `clearAll()` +
        // on `clearForNewDocument()`.
        .onChange(of: redactionState.pendingManualDrawNudge?.id) { _, _ in
            guard let nudge = redactionState.pendingManualDrawNudge else { return }
            let capturedNudge = nudge
            toastManager.enqueue(
                "1 match nearby. Add to selection?",
                severity: .info,
                actionLabel: "Add",
                actionHandler: { [weak redactionState, weak undoManager] in
                    guard let state = redactionState else { return }
                    state.acceptManualDrawNudge(capturedNudge, undoManager: undoManager)
                }
            )
            redactionState.markManualDrawNudgeSuppressed()
        }
        .popover(isPresented: $showHoverPopover, attachmentAnchor: .point(.center)) {
            if let metadata = hoveredMetadata {
                // Pass the region's forward-rationale, if any, into
                // the popover so the "View rationale" disclosure renders.
                let rationale = redactionState.hoveredRegionID.flatMap {
                    redactionState.rationale(forRegionID: $0)
                }
                RegionInfoPopover(metadata: metadata, rationale: rationale)
                    .frame(minWidth: 160, idealWidth: 200, maxWidth: 260)
                    .presentationCompactAdaptation(.popover)
            }
        }
        // Batch delete confirmation (mechanism-description language)
        // Dialog-grammar normalization — sentence-case
        // question title, bare-verb destructive button.
        .confirmationDialog(
            DocumentEditorView.batchDeleteDialogTitle(
                regionCount: redactionState.selectedRegionIDs.count),
            isPresented: $showBatchDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                deleteSelectedRegions()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            // Page-span line names how many pages the deletion
            // spans so the user can reckon scope before confirming.
            Text(DocumentEditorView.batchDeleteDialogMessage(
                regionCount: redactionState.selectedRegionIDs.count,
                pageCount: DocumentEditorView.selectedPageCount(
                    selectedIDs: redactionState.selectedRegionIDs,
                    pageLookup: redactionState.pageIndex(for:)
                )
            ))
        }
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
            dismissBannerTask?.cancel()
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
        .modifier(DocumentEditorKeyboard(activeTool: $activeTool))
        // Page navigation bar on iPhone only (editing
        // phase). Extracted to a small helper
        // property so the compact-float inset math stays out of this
        // long modifier chain — see the `.toolbar {}` note below on
        // this file's type-checker budget.
        .safeAreaInset(edge: .bottom) {
            pageNavigationBarInset
        }
        // Phase-switched toolbar
        // The neutral group tint (routine actions
        // render via the primary/foreground tone) is applied INSIDE
        // each item-list computed property below, not chained onto the
        // `ToolbarItemGroup(...)` here — chaining an extra modifier
        // directly inside this result-builder closure pushed the
        // compiler's whole-expression type-check over its time budget
        // (`DocumentEditorView.swift` is already a large `body`).
        // Isolating the tint inside each already-separate `@ViewBuilder`
        // property keeps this closure's own shape unchanged.
        .toolbar {
            // Leading items
            ToolbarItemGroup(placement: .topBarLeading) {
                editorToolbar.leadingToolbarItems
            }

            // Trailing items. The Redact button is the ONE designated
            // emphasis action and carries its own explicit brand tint
            // (see `trailingToolbarItems`); `.tint(.red)` (delete) and
            // the multi-select toggle's active-teal-or-nil pairing are
            // untouched per-element overrides.
            ToolbarItemGroup(placement: .topBarTrailing) {
                editorToolbar.trailingToolbarItems
            }

            // Editing secondary actions (iPhone overflow menu)
            // Undo/redo moved to trailing toolbar for visibility
            if documentState.phaseKind == .editing, horizontalSizeClass == .compact {
                ToolbarItemGroup(placement: .secondaryAction) {
                    editorToolbar.secondaryActionToolbarItems
                }
            }
        }
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
    private var editorToolbar: DocumentEditorToolbar {
        DocumentEditorToolbar(
            documentState: documentState, redactionState: redactionState,
            coordinator: coordinator, horizontalSizeClass: horizontalSizeClass,
            undoManager: undoManager,
            activeTool: $activeTool, isMultiSelectActive: $isMultiSelectActive,
            showBatchDeleteConfirmation: $showBatchDeleteConfirmation, showSettings: $showSettings,
            documentOverride: documentOverride, redactButtonDisabled: redactButtonDisabled,
            redactButtonHint: redactButtonHint, handleHomeTap: handleHomeTap,
            homeButton: AnyView(homeButton), pipelineModePicker: AnyView(pipelineModePicker),
            deleteSelectedRegions: deleteSelectedRegions
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
    private var parkedChromeLayout: ParkedChromeLayout {
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

    private func deleteSelectedRegions() {
        redactionState.deleteSelected(undoManager: undoManager)
    }

    // MARK: - Batch delete dialog page-span helpers

    /// Page count spanned by a selection set. Looks each ID up via the
    /// caller-provided closure so the helper is testable without a full
    /// RedactionState.
    static func selectedPageCount(
        selectedIDs: Set<UUID>,
        pageLookup: (UUID) -> Int?
    ) -> Int {
        Set(selectedIDs.compactMap(pageLookup)).count
    }

    /// Message body for the batch-delete confirmation dialog. Names the
    /// page-span so the user reckons scope before confirming. Singulars
    /// switch to "region" / "page" so the count grammar reads naturally.
    static func batchDeleteDialogMessage(
        regionCount: Int,
        pageCount: Int
    ) -> String {
        let regionLabel = regionCount == 1 ? "region" : "regions"
        let pageLabel = pageCount == 1 ? "page" : "pages"
        return "Deleting \(regionCount) \(regionLabel) across "
            + "\(pageCount) \(pageLabel).\n"
            + "This removes the selected redaction regions. Use Undo to restore them."
    }

    /// Dialog-grammar normalization — sentence-case
    /// question title, singular-aware. The destructive button is now
    /// bare "Delete" (dominant grammar for this dialog family); the
    /// title alone carries the count.
    static func batchDeleteDialogTitle(regionCount: Int) -> String {
        regionCount == 1 ? "Delete 1 region?" : "Delete \(regionCount) regions?"
    }

    // MARK: - Drawing-mode caption helpers

    /// Caption text shown while the rectangle drawing tool is active.
    /// Mechanism description: names the active gesture so the user knows
    /// what shape the touch will produce.
    static let drawingModeCaption = "Drawing — tap and drag"

    /// Caption is visible only when (a) a captioned drawing tool is
    /// active (the rectangle) AND (b) the document is
    /// in the editing phase. Other phases blur the canvas underneath
    /// their own progress UI, so the caption would be stale.
    /// Pure static behind the Rectangle button: on ENTRY
    /// the selection and the Add-to-Selection toggle are cleared; on exit
    /// nothing else changes.
    static func drawToolEntryEffects(
        entering: Bool
    ) -> (clearSelection: Bool, disableMultiSelect: Bool) {
        (clearSelection: entering, disableMultiSelect: entering)
    }

    static func drawingModeCaptionShouldShow(
        activeTool: DrawingTool?,
        phaseKind: DocumentState.PhaseKind
    ) -> Bool {
        guard phaseKind == .editing else { return false }
        return activeTool == .rectangle
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
    /// Clears the background-pause flag (the ContentView scene handler sets
    /// it on the verified-arm cancel; nothing else consumes it for the
    /// skipped case) and routes per `runVerificationRoute`. The full-pipeline
    /// leg takes the purge re-run's preamble first: `runFullPipeline`'s start
    /// guard (`redactRefusal(with:)`) reads `.verified` as busy.
    private func handleRunVerificationTap() {
        dismissBannerTask?.cancel()
        documentState.wasPausedByBackground = false
        documentState.pausedFromPhase = nil
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

    /// Pick the caption string for whichever drawing tool is
    /// active, so the `.overlay` block and the accessibility label read
    /// the same string. Returns nil when no captioned tool is active.
    static func activeDrawingCaption(
        activeTool: DrawingTool?
    ) -> String? {
        switch activeTool {
        case .rectangle: return drawingModeCaption
        default: return nil
        }
    }

    /// VoiceOver label for the bottom hint capsule. Mirrors the
    /// visible caption so sighted and VoiceOver users hear the same
    /// mechanism description.
    static func captionAccessibilityLabel(
        activeTool: DrawingTool?
    ) -> String {
        guard let caption = activeDrawingCaption(
            activeTool: activeTool
        ) else {
            return ""
        }
        return caption
    }

    // Pipeline mode picker (per-document override)
    @ViewBuilder
    private var pipelineModePicker: some View {
        Menu {
            Picker("Redaction Mode", selection: Binding(
                get: { effectivePipelineMode },
                set: { documentOverride = $0 }
            )) {
                Label { Text("Secure Rasterization") } icon: { PipelineMode.secureRasterization.glyph }
                    .tag(PipelineMode.secureRasterization)
                Label { Text("Searchable Redaction") } icon: { PipelineMode.searchableRedaction.glyph }
                    .tag(PipelineMode.searchableRedaction)
            }
        } label: {
            // Verb-object menu label (was the bare noun "Mode").
            Label { Text("Switch Mode") } icon: { effectivePipelineMode.glyph }
        }
        .disabled(documentState.phaseKind != .editing)
        .accessibilityIdentifier("pipelineMode")
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
            shareConcealedPages: $shareConcealedPages
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
