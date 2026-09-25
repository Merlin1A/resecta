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
    @Environment(\.scenePhase) private var scenePhase
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

    // Per-document pipeline mode override (nil = use global setting)
    @State var documentOverride: PipelineMode?

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

    /// True while a parked sheet carried the staged Scan review.
    /// The review itself stays in `redactionState.pendingTriage` (only the
    /// sheet goes down, not the work); backing out of the dialog
    /// re-presents it through the review bridge
    /// (`restoreParkedReviewIfNeeded()`), Close tears it down with the
    /// session. A parked plain search session is not restored — its
    /// results are transient and the sheet clears them on disappearance,
    /// the same outcome as its own Dismiss.
    @State var homeCloseParkedReview = false

    // Drives the bespoke share-risk confirm sheet shown when a
    // Share tap reaches handleExportTap while the report is FAIL/ATTENTION
    // (not yet overridden), SKIPPED (not yet acknowledged), or an
    // incomplete-WARN (digest-dependent layers skipped, not yet
    // acknowledged). One optional-enum slot replaces the former two
    // booleans — the three families are mutually exclusive by
    // overallStatus, so at most one case is ever non-nil, and the type
    // itself now says so rather than a convention across two Bools.
    @State private var shareRiskConfirmKind: ShareRiskConfirmKind?

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
    @Binding var showFilePicker: Bool
    @Binding var showPhotoPicker: Bool
    @Binding var showSettings: Bool

    enum DrawingTool {
        case rectangle
        /// Tap-to-vertex polygon. Double-tap closes the loop and
        /// commits via `coordinator?.addRegion(_:page:undoManager:)`.
        case polygon
        /// Continuous-touch freeform stroke. On touch-up, the raw
        /// touch path is simplified via Douglas-Peucker to ≤ 32 vertices
        /// (tolerance 2 pt × 1/zoomScale) before commit.
        case freeform
    }

    /// V1.0 ships rectangle + tap-to-redact only; the polygon and freeform
    /// draw-tool toolbar entries are gated off behind this flag. Flip it to
    /// `true` to re-enable their UI — the drawing engine, canvas overlay,
    /// gesture state machine, and their full test suites are intentionally
    /// preserved and stay compiled and green, so revival is a one-line flip.
    private static let advancedDrawToolsEnabled = false

    /// P1.3: single sheet slot for the editor. Precedence search >
    /// rationale is enforced by the binding's getter so two
    /// near-simultaneous transitions in the same runloop tick can't drop a
    /// sheet silently. The former `.triage` case is absorbed: staged
    /// detection findings present INSIDE the search sheet's Scan
    /// interface (`ScanReviewSection`), and the `pendingTriage`
    /// observer below opens/switches that one sheet for every producer.
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
        case .some(.polygon): return .polygon
        case .some(.freeform): return .freeform
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
                // appCoordinator.returnHome(). The 150ms debounce absorbs
                // the transient `.empty` during workspace bootstrap
                // (HomeView.openSampleDocument creates a workspace whose
                // initial phase is `.empty` for a frame before
                // ImportService.loadSampleDocument flips it to `.editing`).
                // The gate confirms we're still genuinely idle before
                // calling returnHome().
                Color.clear
                    .task {
                        try? await Task.sleep(for: .milliseconds(150))
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
                    isMultiSelectActive: isMultiSelectActive,
                    snapToTextEnabled: settingsState.snapToTextEnabled
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
                    // tool, and for the polygon tool also surfaces the
                    // in-progress vertex count and Cancel / Close polygon
                    // buttons.
                    .overlay(alignment: .bottom) {
                        if DocumentEditorView.drawingModeCaptionShouldShow(
                            activeTool: activeTool,
                            phaseKind: documentState.phaseKind
                        ),
                           let caption = DocumentEditorView.activeDrawingCaption(
                            activeTool: activeTool,
                            polygonVertexCount: redactionState
                                .inProgressPolygonVertexCount
                           ) {
                            HStack(spacing: ResectaTokens.Spacing.md) {
                                Text(caption)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                if activeTool == .polygon,
                                   redactionState.inProgressPolygonVertexCount >= 1 {
                                    Button("Cancel") {
                                        coordinator.cancelInProgressPolygon()
                                    }
                                    .font(.caption.weight(.medium))
                                    .accessibilityIdentifier("cancelPolygonButton")
                                    if redactionState.inProgressPolygonVertexCount >= 3 {
                                        Button("Close polygon") {
                                            coordinator.commitInProgressPolygon()
                                        }
                                        .font(.caption.weight(.medium))
                                        .accessibilityIdentifier("closePolygonButton")
                                    }
                                }
                            }
                                .padding(.horizontal, ResectaTokens.Spacing.md)
                                .padding(.vertical, ResectaTokens.Spacing.xs)
                                .background(.regularMaterial, in: Capsule())
                                .padding(.bottom, ResectaTokens.Spacing.lg + parkedChromeLayout.hintCapsuleLift)
                                .accessibilityElement(children: .contain)
                                .accessibilityLabel(
                                    DocumentEditorView.captionAccessibilityLabel(
                                        activeTool: activeTool,
                                        polygonVertexCount: redactionState
                                            .inProgressPolygonVertexCount
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
                    canExport: canExport(report: report),
                    outputExists: outputFileExists,
                    isVerificationStale: redactionState.isVerificationStale,
                    previewAvailable: previewAvailable,
                    onExport: { handleExportTap(report: report) },
                    onRunVerification: { handleRunVerificationTap() },
                    deselectionSnapshot: redactionState.lastRunDeselection,
                    onReviewDeselections: reviewDeselectionsHandler,
                    runFacts: VerificationResultsView.RunFacts.derive(
                        lastDetectionRun: redactionState.lastDetectionRun,
                        hasAppliedRegions: redactionState.hasEffectiveRegions)
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
        .onChange(of: scenePhase) { oldPhase, newPhase in
            handleScenePhaseChange(old: oldPhase, new: newPhase)
        }
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
        // highest-precedence active source. Staged
        // detections ride the search case — the `pendingTriage`
        // observer below keeps `activeSearch` populated while
        // detections are pending. The slot sits ABOVE the phase
        // switch, so a live session would ride over every phase;
        // The Apply seam keeps it out of the pipeline phases by tearing the
        // session down at the Apply seam (`runFullPipeline`)
        // and on the purge re-run (`prepareForPurgeRerun`).
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
                    // `.sheet(isPresented:)` crash (dismissTriage()
                    // clears two properties; activeSearch=nil fires a didSet that
                    // writes two more). Defer each write one runloop turn via
                    // `Task { @MainActor }`. The synchronous reads snapshot which
                    // arm to clear (the values are already committed inside the
                    // update pass); only the write is deferred. The in-Task
                    // re-check guard prevents a double-dismiss if a concurrent
                    // path cleared the state across the one-frame window (the
                    // get: closure above may re-query during it).
                    if redactionState.activeSearch != nil {
                        Task { @MainActor in
                            guard redactionState.activeSearch != nil else { return }
                            redactionState.activeSearch = nil
                            // A system-initiated dismissal (swipe /
                            // programmatic) with staged findings pending
                            // discards the review — same semantics as
                            // the sheet's own Dismiss. Without this the
                            // findings would strand: the sheet is gone
                            // but the pending set keeps the Scan/Search
                            // entry points disabled.
                            if redactionState.pendingTriage != nil {
                                redactionState.dismissTriage()
                            }
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
                    // dismiss rule). An unreviewed magic-wand
                    // preselect also blocks the swipe now — a
                    // never-reviewed auto-selected set no longer drops
                    // silently.
                    .interactiveDismissDisabled(searchState.requiresDismissConfirmation)
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
        // Absorbed-review presentation bridge: whenever staged detections
        // arrive (pipeline staging, banner Review, the DEBUG seed hook),
        // surface them in the ONE sheet's Scan interface. Observation
        // here is presentation-only — the same job the retired
        // `.triage` sheet-getter arm did — and never triggers a run
        // (the auto-run flag stays unarmed). `initial: true` covers a
        // producer that wrote before this view mounted.
        .onChange(of: redactionState.pendingTriage != nil, initial: true) { _, hasPending in
            guard hasPending else { return }
            presentReviewInScanInterface()
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
        // Magic-wand "Select all instances" observer. The canvas
        // long-press menu sets `pendingMagicWandRequest` carrying the
        // escaped term; here we open (or re-use) the search sheet with
        // a pre-filled exact-match query so the engine runs the same
        // text-search path with word-boundary semantics. The pre-fill
        // is symmetric with the existing search-sheet API surface —
        // `SearchState.queryText` + `SearchState.options.exactMatch`
        // is the canonical entry point.
        .onChange(of: redactionState.pendingMagicWandRequest) { _, _ in
            guard let request = redactionState.pendingMagicWandRequest
            else { return }
            applyMagicWandRequest(request)
            redactionState.pendingMagicWandRequest = nil
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
            deselectionSnapshot: redactionState.lastRunDeselection,
            beginExport: beginExport
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
        // Keyboard shortcuts for editing — handled via single onKeyPress to reduce body complexity
        .onKeyPress(phases: .down, action: handleKeyPress)
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
                leadingToolbarItems
            }

            // Trailing items. The Redact button is the ONE designated
            // emphasis action and carries its own explicit brand tint
            // (see `trailingToolbarItems`); `.tint(.red)` (delete) and
            // the multi-select toggle's active-teal-or-nil pairing are
            // untouched per-element overrides.
            ToolbarItemGroup(placement: .topBarTrailing) {
                trailingToolbarItems
            }

            // Editing secondary actions (iPhone overflow menu)
            // Undo/redo moved to trailing toolbar for visibility
            if documentState.phaseKind == .editing, horizontalSizeClass == .compact {
                ToolbarItemGroup(placement: .secondaryAction) {
                    secondaryActionToolbarItems
                }
            }
        }
        .navigationTitle(documentTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Toolbar Leading Items

    /// Routine actions render neutral — the group's
    /// ambient tint is `.primary`, applied here (inside the property,
    /// not at the `.toolbar {}` call site — see the comment above). Per-
    /// element overrides (the draw tools' `.tint(active ? BrandTeal.tint
    /// : nil)`) still win: `nil` now inherits this neutral instead of
    /// the root's brand teal, so only the ACTIVE tool stays teal.
    @ViewBuilder
    private var leadingToolbarItems: some View {
        Group {
        switch documentState.phaseKind {
        case .editing:
            // Drawing tools.
            // iPhone nav-bar overflow: keep a CONSTANT-width glyph per draw tool
            // and signal "active" via .tint only. A wider active glyph (the former
            // rectangle.dashed.badge.checkmark / scribble.variable) grows the leading
            // ToolbarItemGroup past the bar width and collapses the whole group into the
            // system "…" overflow menu. Polygon keeps hexagon/hexagon.fill — fill variants
            // share advance width, so that selected cue is width-safe.
            Button("Rectangle", systemImage: "rectangle.dashed") {
                // Draw wins: entering the tool drops the
                // selection and the Add-to-Selection toggle so the next
                // drag draws instead of resizing or marquee-selecting.
                let entering = activeTool != .rectangle
                activeTool = entering ? .rectangle : nil
                let effects = DocumentEditorView.drawToolEntryEffects(entering: entering)
                if effects.clearSelection { redactionState.selectedRegionIDs = [] }
                if effects.disableMultiSelect { isMultiSelectActive = false }
            }
            .tint(activeTool == .rectangle ? ResectaTokens.BrandTeal.tint : nil)
            .accessibilityIdentifier("drawTool")
            .accessibilityValue(activeTool == .rectangle
                                ? "Drawing mode active" : "Tap to enter drawing mode")

            // V1.0: the polygon + freeform draw tools are gated off for
            // launch; see `advancedDrawToolsEnabled`. The engine, overlay,
            // and tests are preserved, and the downstream hint-capsule /
            // Escape branches stay inert because `activeTool` can no longer
            // become `.polygon` / `.freeform` while the buttons are hidden.
            if Self.advancedDrawToolsEnabled {
                // Polygon tool — tap-to-vertex. Close
                // the loop by tapping the first vertex (a ring appears
                // around it once count ≥ 3) or by tapping "Close polygon"
                // in the bottom hint capsule. "Cancel" in the same capsule
                // discards the in-progress vertex list; Escape does the
                // same.
                Button("Polygon", systemImage: activeTool == .polygon
                       ? "hexagon.fill"
                       : "hexagon") {
                    activeTool = activeTool == .polygon ? nil : .polygon
                }
                .tint(activeTool == .polygon ? ResectaTokens.BrandTeal.tint : nil)
                .accessibilityIdentifier("polygonTool")
                .accessibilityValue(activeTool == .polygon
                                    ? "Polygon drawing mode active"
                                    : "Tap to enter polygon drawing mode")

                // Freeform tool — continuous-touch path simplified to
                // ≤ 32 vertices on touch-up.
                Button("Freeform", systemImage: "scribble") {
                    activeTool = activeTool == .freeform ? nil : .freeform
                }
                .tint(activeTool == .freeform ? ResectaTokens.BrandTeal.tint : nil)
                .accessibilityIdentifier("freeformTool")
                .accessibilityValue(activeTool == .freeform
                                    ? "Freeform drawing mode active"
                                    : "Tap to enter freeform drawing mode")
            }

            // Two peer entry points into the one search-and-scan sheet
            // (two interfaces over one chassis). Both open the same
            // sheet pre-switched to the tapped interface; they replace
            // the former Auto-Detect menu + Search & Redact button.
            //
            // [Scan] keeps the one-tap contract: the tap arms a
            // one-shot auto-run flag the sheet consumes on appear, so
            // one tap opens the sheet AND runs a full scan with no
            // second confirm. The run is trigger-driven from there
            // (chips / options configure the NEXT run).
            Button("Scan", systemImage: "doc.viewfinder") {
                let state = SearchState()
                state.searchModeType = .piiScan
                state.pendingAutoRunScan = true
                redactionState.activeSearch = state
            }
            // `pendingTriage != nil` normally implies the sheet is
            // already up (the review bridge presents it); the explicit
            // clause is a belt so a fresh auto-run can never arm while
            // staged detections await review.
            .disabled(documentState.phaseKind != .editing
                      || redactionState.pendingTriage != nil
                      || redactionState.activeSearch != nil)
            // Identifier is PLUMBING and carries over from the
            // Auto-Detect entry this button renames — UI tests anchor
            // on it, and it is deliberately not the display string.
            .accessibilityIdentifier("autoDetect")

            // [Search] opens the literal-search interface. A fresh
            // SearchState defaults to `.text` — the Search side.
            Button("Search", systemImage: "magnifyingglass") {
                redactionState.activeSearch = SearchState()
            }
            .disabled(documentState.phaseKind != .editing
                      || redactionState.pendingTriage != nil
                      || redactionState.activeSearch != nil)
            .keyboardShortcut("f", modifiers: .command)
            .accessibilityIdentifier("searchRedact")
        case .verified:
            // Home lives top-left on the verification results screen
            // (the former Done label/glyph became Home — the same
            // `house` glyph as the editor's overflow entry). The action is
            // the Done teardown, lifted from VerificationActionBar when the
            // bottom bar was removed; the confirmation dialog (pinned
            // by VerificationActionBarDoneConfirmationTests)
            // still gates sessions that carry drawn regions. Identifier
            // kept (plumbing). Routed through
            // `handleHomeTap()` so a sheet that is somehow still presented
            // on this screen takes the park-then-dialog route
            // instead of the refused second presentation (a staged review
            // cannot be pending after an Apply, so the confirm gate
            // resolves to `hasDrawnRegions` here as before).
            Button("Home", systemImage: "house") {
                handleHomeTap()
            }
            .accessibilityIdentifier("verificationDoneButton")
        default:
            EmptyView()
        }
        }
        .tint(.primary)
    }

    // MARK: - Toolbar Trailing Items

    /// Same neutral-group rule as `leadingToolbarItems`
    /// above.
    @ViewBuilder
    private var trailingToolbarItems: some View {
        Group {
        switch documentState.phaseKind {
        case .editing:
            // Undo/redo always visible (both iPhone and iPad)
            undoRedoButtons

            // iPad: additional edit actions visible in toolbar
            if horizontalSizeClass == .regular {
                selectionMenu
                selectMoreToggle
                deleteButton
                batchOpsMenu
                pipelineModePicker
            }

            // Redact button — always visible. This is the ONE
            // designated emphasis action in this toolbar — explicit
            // brand tint so it stands out against the neutral group.
            Button("Redact", systemImage: "scissors") {
                coordinator.runFullPipeline(documentOverride: documentOverride)
            }
            .tint(ResectaTokens.BrandTeal.tint)
            // Gate on the full pipeline-start predicate
            // (phase + triage + active task) in addition to the existing
            // effective-regions check. `keyboardShortcut` on a Button
            // inherits the `.disabled` modifier, so Cmd-Shift-R is
            // covered without a separate guard.
            .disabled(!redactionState.hasEffectiveRegions
                      || !documentState.canStartPipeline(with: redactionState))
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .accessibilityIdentifier("redactButton")
            .accessibilityHint(redactionState.hasEffectiveRegions
                               ? "" : "Draw regions or apply Scan or Search results first")

            settingsButton

        case .detecting, .redacting:
            // Single cancel button
            Button("Stop Processing", systemImage: "stop.circle") {
                documentState.cancelActivePipeline(redactionState: redactionState)
            }
            .accessibilityIdentifier("stopProcessing")
            .accessibilityHint("Stops processing. Your document is preserved.")

        case .verifying:
            // Single cancel button
            Button("Stop Verification", systemImage: "stop.circle") {
                documentState.cancelActivePipeline(redactionState: redactionState)
            }
            .accessibilityIdentifier("stopProcessing")
            .accessibilityHint("Stops processing. Your document is preserved.")

        default:
            // .verified, .failed — settings gear only.
            // `.empty` flashes Color.clear and auto-returns home
            // (Phase 1 redesign) — this trailing branch is unreachable
            // for that phase but kept as a defense-in-depth fallback
            // during the 150ms debounce window.
            settingsButton
        }
        }
        .tint(.primary)
    }

    @ViewBuilder
    private var settingsButton: some View {
        Button("Settings", systemImage: "gearshape") {
            showSettings = true
        }
        .accessibilityIdentifier("settings-button")
    }

    /// iPhone overflow menu — same neutral-group rule.
    /// Extracted to its own property (mirrors `leadingToolbarItems` /
    /// `trailingToolbarItems`) so the tint is isolated from the
    /// `.toolbar {}` result-builder closure.
    @ViewBuilder
    private var secondaryActionToolbarItems: some View {
        Group {
            homeButton
            selectionMenu
            selectMoreToggle
            deleteButton
            batchOpsMenu
            pipelineModePicker
        }
        .tint(.primary)
    }

    // MARK: - Toolbar Components

    @ViewBuilder
    private var undoRedoButtons: some View {
        Button("Undo", systemImage: "arrow.uturn.backward") {
            undoManager?.undo()
        }
        .disabled(!(undoManager?.canUndo ?? false))
        .keyboardShortcut("z", modifiers: .command)

        Button("Redo", systemImage: "arrow.uturn.forward") {
            undoManager?.redo()
        }
        .disabled(!(undoManager?.canRedo ?? false))
        .keyboardShortcut("z", modifiers: [.command, .shift])
    }

    @ViewBuilder
    private var deleteButton: some View {
        let count = redactionState.selectedRegionIDs.count
        if count > 0 {
            Button(deleteButtonLabel, systemImage: "trash") {
                // Batch delete confirmation for multi-selection
                if count > 1 {
                    showBatchDeleteConfirmation = true
                } else {
                    deleteSelectedRegions()
                }
            }
            .tint(.red)
            .keyboardShortcut(.delete, modifiers: [])
        }
    }

    // "More" menu that bundles batch operations on the active
    // selection. Visible only when `selectedRegionIDs.isEmpty == false`,
    // gated by `batchOpsMenuShouldShow(selectedCount:)`. "Delete Selected"
    // routes through the existing `showBatchDeleteConfirmation` dialog
    // so the page-span message applies to this entry too.
    @ViewBuilder
    private var batchOpsMenu: some View {
        let selectedCount = redactionState.selectedRegionIDs.count
        if DocumentEditorView.batchOpsMenuShouldShow(selectedCount: selectedCount) {
            let page = documentState.currentPageIndex
            let pageRegions = redactionState.regions[page] ?? []
            Menu {
                Button("Select All on Page", systemImage: "checkmark.circle") {
                    redactionState.selectedRegionIDs = Set(pageRegions.map(\.id))
                }
                .disabled(selectedCount == pageRegions.count)
                Button("Deselect", systemImage: "xmark.circle") {
                    redactionState.selectedRegionIDs = []
                }
                Button(role: .destructive) {
                    showBatchDeleteConfirmation = true
                } label: {
                    Label("Delete Selected", systemImage: "trash")
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .accessibilityIdentifier("canvasBatchOpsMenu")
        }
    }

    /// Visibility predicate. The "More" menu surfaces only when at
    /// least one region is selected. Pure function so the gate is testable
    /// without a SwiftUI host.
    static func batchOpsMenuShouldShow(selectedCount: Int) -> Bool {
        selectedCount > 0
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

    // "Select More" toolbar toggle. While on, a tap on a region
    // adds to selection rather than replacing it — iPhone parity for
    // the iPad Shift+tap path. Visible only when the current page has
    // regions to select. Count surfaces in the label so the user sees
    // the running selection size without opening a separate badge.
    @ViewBuilder
    private var selectMoreToggle: some View {
        let page = documentState.currentPageIndex
        let pageRegionCount = redactionState.regions[page]?.count ?? 0
        let selectedCount = redactionState.selectedRegionIDs.count
        if pageRegionCount > 0 {
            Button {
                isMultiSelectActive.toggle()
                // Mutual exclusion with the Rectangle tool:
                // whichever was activated last wins.
                if isMultiSelectActive { activeTool = nil }
            } label: {
                Label(
                    RedactionOverlayView.selectMoreToggleLabel(selectedCount: selectedCount),
                    systemImage: isMultiSelectActive
                        ? "checkmark.square.fill"
                        : "checkmark.square"
                )
            }
            .tint(isMultiSelectActive ? ResectaTokens.BrandTeal.tint : nil)
            .accessibilityIdentifier("selectMoreToggle")
            .accessibilityValue(isMultiSelectActive
                                ? "On. Tapping a region adds it to the selection."
                                : "Off. Tapping a region replaces the selection.")
        }
    }

    // Select All / Deselect All menu — touch-accessible on both platforms
    @ViewBuilder
    private var selectionMenu: some View {
        let page = documentState.currentPageIndex
        let pageRegionCount = redactionState.regions[page]?.count ?? 0
        let selectedCount = redactionState.selectedRegionIDs.count
        if pageRegionCount > 0 {
            Menu {
                Button("Select All on Page", systemImage: "checkmark.circle") {
                    redactionState.selectedRegionIDs = Set(
                        (redactionState.regions[page] ?? []).map(\.id))
                }
                .disabled(selectedCount == pageRegionCount)
                if selectedCount > 0 {
                    Button("Deselect All", systemImage: "xmark.circle") {
                        redactionState.selectedRegionIDs = []
                    }
                }
            } label: {
                // Verb-object menu label (was the bare noun
                // "Selection").
                // The off state is a none-selected STATE
                // indicator, not an action icon — plain "circle"
                // instead of the unfilled checkmark glyph.
                Label("Select Regions", systemImage: selectedCount > 0
                      ? "checkmark.circle.fill" : "circle")
            }
        }
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

    private var deleteButtonLabel: String {
        let count = redactionState.selectedRegionIDs.count
        return count > 1 ? "Delete \(count) Regions" : "Delete Region"
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

    /// Caption text shown while the polygon tool is
    /// active, keyed on the in-progress vertex count. Three buckets
    /// match the close-mechanism floors:
    ///   - count 0   → invite first vertex
    ///   - count 1-2 → name the 3-vertex close floor
    ///   - count ≥ 3 → name the tap-on-first-vertex close action
    /// Returns nil when the active tool is not the polygon — the caption
    /// overlay then routes through the rectangle caption (or hides).
    static func polygonCaption(
        activeTool: DrawingTool?,
        vertexCount: Int
    ) -> String? {
        guard activeTool == .polygon else { return nil }
        switch vertexCount {
        case 0: return "Tap to add vertices."
        case 1, 2: return "Tap to add vertices. Need 3 to close."
        default: return "Tap the first vertex to close."
        }
    }

    /// Caption is visible only when (a) a captioned drawing tool is
    /// active (rectangle or polygon) AND (b) the document is
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
        return activeTool == .rectangle || activeTool == .polygon
    }

    /// Results-screen card: which pipeline the Run Verification
    /// card should drive. Verify-only re-runs the checks against the existing
    /// output; a stale or absent output needs the full pipeline (regions
    /// changed since the run, or the output is gone). Static so the routing
    /// is unit-testable without a SwiftUI host (mirrors `resumeAction`).
    enum RunVerificationRoute: Equatable { case verifyOnly, fullPipeline }

    static func runVerificationRoute(
        hasOutput: Bool, isVerificationStale: Bool
    ) -> RunVerificationRoute {
        hasOutput && !isVerificationStale ? .verifyOnly : .fullPipeline
    }

    /// Action for the Run Verification card on the skipped results screen.
    /// Clears the background-pause flag (the ContentView scene handler sets
    /// it on the verified-arm cancel; nothing else consumes it for the
    /// skipped case) and routes per `runVerificationRoute`. The full-pipeline
    /// leg round-trips the phase through `.editing` first — `runFullPipeline`
    /// guards `canStartPipeline`, which rejects `.verified` (the KI-4
    /// purge re-run precedent).
    private func handleRunVerificationTap() {
        dismissBannerTask?.cancel()
        documentState.wasPausedByBackground = false
        documentState.pausedFromPhase = nil
        switch Self.runVerificationRoute(
            hasOutput: redactionState.outputURL != nil,
            isVerificationStale: redactionState.isVerificationStale
        ) {
        case .verifyOnly:
            coordinator.runVerifyOnly()
        case .fullPipeline:
            Self.prepareForPurgeRerun(
                documentState: documentState,
                redactionState: redactionState
            )
            coordinator.runFullPipeline(documentOverride: documentOverride)
        }
    }

    /// Pick the caption string for whichever drawing tool is
    /// active. Centralises the rectangle / polygon branch so the
    /// `.overlay` block and the accessibility label read the same
    /// string. Returns nil when no captioned tool is active.
    static func activeDrawingCaption(
        activeTool: DrawingTool?,
        polygonVertexCount: Int
    ) -> String? {
        switch activeTool {
        case .rectangle: return drawingModeCaption
        case .polygon: return polygonCaption(activeTool: activeTool,
                                             vertexCount: polygonVertexCount)
        default: return nil
        }
    }

    /// VoiceOver label for the bottom hint capsule. Mirrors the
    /// visible caption so sighted and VoiceOver users hear the same
    /// mechanism description, with the polygon Cancel / Close buttons
    /// named when present (the buttons carry their own labels via
    /// `accessibilityElement(children: .contain)`, but the container
    /// label gives the listener orientation before they dive in).
    static func captionAccessibilityLabel(
        activeTool: DrawingTool?,
        polygonVertexCount: Int
    ) -> String {
        guard let caption = activeDrawingCaption(
            activeTool: activeTool,
            polygonVertexCount: polygonVertexCount
        ) else {
            return ""
        }
        guard activeTool == .polygon, polygonVertexCount >= 1 else {
            return caption
        }
        if polygonVertexCount >= 3 {
            return caption + " Cancel and Close polygon buttons available."
        }
        return caption + " Cancel button available."
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

    // MARK: - Magic Wand

    /// Open / re-use the SearchAndRedactSheet with the magic-wand
    /// term pre-filled and `exactMatch` engaged. Reuses
    /// the search-origin apply — do not
    /// introduce a new apply method. If a search session is already
    /// active we mutate it in place; otherwise a fresh `SearchState` is
    /// created via the existing `redactionState.activeSearch = ...`
    /// path that drives the `.sheet(isPresented:)` binding.
    fileprivate func applyMagicWandRequest(_ request: MagicWandSearchRequest) {
        let state = redactionState.activeSearch ?? SearchState()
        // Programmatic transition, same contract as saved-search recall:
        // armed only when the mode actually changes so the hub's
        // `.onChange` neither re-clears the session it is about to
        // repopulate nor mis-attributes the clear to a mode-picker tap
        // the user never made. (A fresh `SearchState` starts in `.text`,
        // so the flag stays false on the new-session path.)
        state.isProgrammaticModeChange = state.searchModeType != .text
        state.searchModeType = .text
        // Clear synchronously: the programmatic transition above makes
        // the mode-switch `.onChange` preserve results (the recall
        // contract), but the magic wand REPLACES the session — without
        // this, the old session's verdict renders against the new query
        // until the debounce fires. Post-clear the interim empty state
        // reads "Not run yet", which is honest.
        state.clearResults()
        state.options.exactMatch = true
        // Auto-select every match so the user can apply with one
        // tap. Flag is consumed by `SearchState.appendResult` for every
        // result the engine streams in; `triggerSearch` resets it after
        // kickoff so a later non-magic-wand search in the same sheet
        // session returns to the default selection shape.
        state.preselectIncomingResults = true
        state.queryText = request.escapedTerm
        if redactionState.activeSearch == nil {
            redactionState.activeSearch = state
        }
    }

    // MARK: - Export (lifted from VerificationResultsView)

    // Defense-in-depth export gate. Lifted from
    // VerificationActionBar so the bar and the Phase 2 action card share
    // one source of truth.
    private func canExport(report: VerificationReport) -> Bool {
        // FAIL override / "Option B": a standing FAIL no longer disables
        // the Share card — it stays enabled (red-tinted via
        // VerificationResultsView.shouldTintShareRed(report:)) and routes through the
        // one-time "Share Anyway" confirm in handleExportTap. Enablement now
        // depends only on a fresh, valid output existing on disk. (`report` is
        // retained in the signature so the call site and gate seam stay stable.)
        guard let url = redactionState.outputURL,
              FileManager.default.fileExists(atPath: url.path),
              !redactionState.isVerificationStale
        else { return false }
        return true
    }

    /// A redacted output file exists on disk — one of the two facts behind
    /// `canExport`, threaded into VerificationResultsView separately so the
    /// disabled Share card's caption (`shareDisabledReason`) can name the
    /// actual cause.
    private var outputFileExists: Bool {
        guard let url = redactionState.outputURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Preview availability for VerificationResultsView: a redacted output file
    /// exists on disk. Deliberately NOT folded into `canExport` (which also
    /// requires !isVerificationStale for the *Share* affordance) — Preview is a
    /// read-only view of whatever output exists, and RedactedPreviewView
    /// re-validates the URL itself (RedactedPreviewView.swift:35-36), so a stale
    /// or absent URL degrades to ContentUnavailableView rather than crashing.
    private var previewAvailable: Bool { outputFileExists }

    private func handleExportTap(report: VerificationReport) {
        // FAIL override / "Option B": a standing FAIL/ATTENTION verdict
        // (not yet overridden) routes the Share tap through the bespoke
        // share-risk confirm sheet before any export. WARN/INFO/PASS (and an
        // already-overridden FAIL/ATTENTION) fall straight through to the
        // share sheet.
        if Self.shareNeedsFailConfirm(
            report: report,
            acknowledged: documentState.failShareAcknowledged
        ) {
            shareRiskConfirmKind = .failOrAttention(report)
            return
        }
        // Skipped-share confirm: an unacknowledged SKIPPED report routes
        // through the same sheet — the user is sharing an output whose
        // redaction was never verified. Mutually exclusive with the FAIL
        // branch by overallStatus.
        if Self.shareNeedsSkippedConfirm(
            report: report,
            acknowledged: documentState.skippedShareAcknowledged
        ) {
            shareRiskConfirmKind = .skipped(report)
            return
        }
        // Incomplete-WARN confirm — a WARN whose digest-dependent layers
        // were skipped, or whose layers include a could-not-verify WARN,
        // not yet acknowledged. Mutually exclusive with both branches above
        // by overallStatus.
        if Self.shareNeedsIncompleteWarnConfirm(
            report: report,
            acknowledged: documentState.incompleteWarnShareAcknowledged
        ) {
            shareRiskConfirmKind = .incompleteWarn(report)
            return
        }
        beginExport(report: report)
    }

    // MARK: - Post-share acknowledgment + re-arm

    /// Toast enqueued when the share sheet reports the document was
    /// actually sent (`completed == true`) — confirms the app's own action
    /// (handing the file to the share sheet) went through, without naming
    /// which destination the user chose. Never enqueued on cancel — see
    /// `handleShareSheetCompletion`.
    static let sharedAcknowledgmentToast = "Shared."

    /// The share sheet's `completionWithItemsHandler`
    /// routes through this pure static so the re-arm / announce /
    /// record-export decision is unit-testable without
    /// `UIActivityViewController`. `completed == false` means the user
    /// backed out of the sheet without sending — the share-risk confirms
    /// are spent only for a send that actually happened, so a cancelled
    /// attempt re-arms all three (`DocumentState.rearmShareRiskConfirms()`)
    /// for the next Share tap on the same report. `completed ==
    /// true` announces the share and then records it — the
    /// `successfulExportCount` bump / App Store review-request check,
    /// unchanged from the prior inline body — leaving the confirms spent
    /// for this report; a fresh report re-arms via `transition(to:)`'s
    /// reset instead of this function.
    static func handleShareSheetCompletion(
        completed: Bool,
        documentState: DocumentState,
        announceShared: () -> Void,
        recordSuccessfulExport: () -> Void
    ) {
        guard completed else {
            documentState.rearmShareRiskConfirms()
            return
        }
        announceShared()
        recordSuccessfulExport()
    }

    // DateFormatter is expensive to create; reuse a static instance.
    private static let exportFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    private func beginExport(report: VerificationReport) {
        guard let outputURL = redactionState.outputURL,
              FileManager.default.fileExists(atPath: outputURL.path)
        else {
            // KI-4: File purged while backgrounded
            redactionState.outputURL = nil
            documentState.transition(to: .failed(
                error: .exportError(.filePurged),
                returnPhase: .editing
            ))
            return
        }

        documentState.transition(to: .exporting)

        // Timestamped filename, no original name (could be sensitive)
        let exportName = "redacted_\(Self.exportFormatter.string(from: Date())).pdf"
        // Place the share-export copy inside the per-session
        // backup-excluded subdirectory so the user-facing filename surfaces
        // in the share sheet from the same protected location as the
        // pipeline output.
        let exportURL: URL
        do {
            exportURL = try coordinator.tempExportDirectory.childURL(named: exportName)
        } catch { // LegalPhrases:safe
            documentState.transition(to: .failed(
                error: .exportError(.writeFailed),
                returnPhase: .verified(report: report)
            ))
            return
        }

        do {
            try FileManager.default.copyItem(at: outputURL, to: exportURL)
        } catch {
            documentState.transition(to: .failed(
                error: .exportError(.writeFailed),
                returnPhase: .verified(report: report)
            ))
            return
        }

        // Apply `.complete` protection to the export copy. The
        // session is still live (user is sharing now). Best-effort —
        // failures are non-fatal but logged via the system trace if any.
        try? TempFileHardening.applyProtection(exportURL, level: .complete)

        let activityVC = UIActivityViewController(
            activityItems: [exportURL],
            applicationActivities: nil
        )

        // Capture report for return transition
        let currentReport = report
        activityVC.completionWithItemsHandler = { _, completed, _, _ in
            try? FileManager.default.removeItem(at: exportURL)
            documentState.transition(to: .verified(report: currentReport))
            // Order matters: the transition above restores the
            // captured report onto `.verified` FIRST, then re-arm/announce
            // reads or mutates that live phase.
            DocumentEditorView.handleShareSheetCompletion(
                completed: completed,
                documentState: documentState,
                announceShared: {
                    toastManager.enqueue(
                        DocumentEditorView.sharedAcknowledgmentToast,
                        severity: .success)
                },
                recordSuccessfulExport: {
                    settingsState.successfulExportCount += 1
                    if settingsState.successfulExportCount == 3 {
                        Task { @MainActor in requestReview() }
                    }
                }
            )
        }

        // `connectedScenes` is an unordered Set; `.first as? UIWindowScene`
        // can resolve to a non-foreground scene whose `keyWindow` is nil,
        // in which case the share sheet never presents and the editor is
        // stranded on `.exporting` (the PipelineProgressCard overlay).
        // Use the same foreground-active filter as the audit/verification-
        // report share paths.
        guard let topVC = MatchExportService.topViewController() else {
            try? FileManager.default.removeItem(at: exportURL)
            documentState.transition(to: .verified(report: currentReport))
            // The share sheet never presented, so no send
            // happened — re-arm exactly as a cancelled share would.
            DocumentEditorView.handleShareSheetCompletion(
                completed: false,
                documentState: documentState,
                announceShared: {},
                recordSuccessfulExport: {}
            )
            toastManager.enqueue(
                "Unable to present the share sheet right now.",
                severity: .warning
            )
            return
        }
        activityVC.popoverPresentationController?.sourceView = topVC.view
        topVC.present(activityVC, animated: true)
    }

    // MARK: - KI-4 Scene-phase observer

    /// Toast copy for the KI-4 proactive purge re-run prompt. Mechanism-
    /// description: names what
    /// iOS did (reclaimed the temp file) and what the user can do (Re-run).
    static let purgeRerunToastMessage =
        "Pipeline output was reclaimed by iOS while the app was in the background. Tap Re-run to regenerate."

    /// Pure gate predicate for the KI-4 purge re-run toast. Returns `true`
    /// only when (a) the transition is `.background → .active`, (b) the
    /// editor is on `.verified(report)`, and (c) the output file is missing.
    /// Other transitions (`.inactive → .active` from the app switcher,
    /// `.background → .inactive` mid-resume, transitions into any non-
    /// verified phase) all return false. Static so the gate is testable
    /// without a SwiftUI host.
    static func shouldShowPurgeRerunToast(
        oldPhase: ScenePhase,
        newPhase: ScenePhase,
        documentPhase: DocumentState.Phase,
        outputFileExists: Bool
    ) -> Bool {
        guard oldPhase == .background, newPhase == .active else { return false }
        guard case .verified = documentPhase else { return false }
        return !outputFileExists
    }

    /// State preamble for the purge re-run action, extracted as a
    /// static so the transition is testable without a SwiftUI host (mirrors
    /// `shouldShowPurgeRerunToast`). The purge toast fires only from `.verified`,
    /// but `runFullPipeline` guards `canStartPipeline(with:)` which requires
    /// `.editing` — without this round-trip the "Re-run" button silently no-ops
    /// and strands the user (the output is gone and Share is disabled). The
    /// `verified -> editing` transition is legal.
    /// activeSearch is torn down first: the Search & Redact
    /// sheet mutates `redactionState.regions` and is incompatible with the
    /// `.redacting` / `.verifying` phases the re-run enters.
    @MainActor
    static func prepareForPurgeRerun(
        documentState: DocumentState,
        redactionState: RedactionState
    ) {
        redactionState.dismissActiveSearch()
        documentState.transition(to: .editing)
    }

    // MARK: - Deselection review routing

    /// The deselection row's Review affordance is offered only while the
    /// search session the counts came from is still alive — the
    /// `.sheet(item:)` slot re-presents a live `activeSearch` the moment
    /// the phase returns to `.editing`, so routing works by construction.
    /// A torn-down session (the sheet's close buttons nil `activeSearch`)
    /// has no coverage panel left to reopen; re-creating a fresh
    /// `SearchState` would mount an empty panel that contradicts the
    /// recorded counts. Static so the gate is unit-testable without a
    /// SwiftUI host.
    static func deselectionReviewAvailable(hasLiveSearchSession: Bool) -> Bool {
        hasLiveSearchSession
    }

    /// Detent the Review route raises the search sheet to. `.compactFloat`
    /// shows only the title-only handle — the coverage panel
    /// mounts topmost in `SearchResultsSection`, which `.medium` reveals.
    static let deselectionReviewDetent: PresentationDetent = .medium

    /// State preamble for the deselection-review route: the row lives on
    /// the verification-results screen (`.verified`), the coverage panel
    /// inside the search sheet, which only presents over the editor. The
    /// `verified -> editing` transition is the same legal round-trip the
    /// KI-4 purge re-run uses (`prepareForPurgeRerun`) — Keep Editing's
    /// behavior, minus that path's search teardown, since the live session
    /// IS the destination here. Static so the transition is testable
    /// without a SwiftUI host.
    @MainActor
    static func prepareForDeselectionReview(documentState: DocumentState) {
        documentState.transition(to: .editing)
    }

    /// Review handler threaded into `VerificationResultsView`. Nil when
    /// the search session is gone, which hides the affordance entirely.
    private var reviewDeselectionsHandler: (() -> Void)? {
        // The button's a11y label promises the scan coverage panel,
        // which is hidden for 1.0 — pass nil so only the Review affordance
        // disappears; the deselection row text itself stays.
        guard SearchState.searchAuditSurfacesEnabled else { return nil }
        guard Self.deselectionReviewAvailable(
            hasLiveSearchSession: redactionState.activeSearch != nil
        ) else { return nil }
        return { handleReviewDeselectionsTap() }
    }

    /// Raise the sheet detent BEFORE the phase transition: the search
    /// sheet re-presents as a side effect of `.editing` re-mounting the
    /// editor under the `.sheet(item:)` slot, and the presentation reads
    /// the detent selection binding as it comes up.
    private func handleReviewDeselectionsTap() {
        searchSheetDetent = Self.deselectionReviewDetent
        Self.prepareForDeselectionReview(documentState: documentState)
    }

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

    /// Fire the KI-4 purge re-run toast when the user returns to the
    /// foreground after iOS reclaimed the pipeline's temp output PDF.
    /// Defense-in-depth: the `canExport` Share-button disable + the
    /// `FailedStateView` Re-open Document Tier-2 surface remain in place.
    private func handleScenePhaseChange(old: ScenePhase, new: ScenePhase) {
        let outputPath = redactionState.outputURL?.path ?? ""
        let exists = FileManager.default.fileExists(atPath: outputPath)
        guard Self.shouldShowPurgeRerunToast(
            oldPhase: old,
            newPhase: new,
            documentPhase: documentState.phase,
            outputFileExists: exists
        ) else { return }
        let override = documentOverride
        toastManager.enqueue(
            Self.purgeRerunToastMessage,
            severity: .warning,
            actionLabel: "Re-run",
            actionHandler: {
                // Deferral pattern: ToastView's button
                // action calls this actionHandler() and then
                // `toastManager.dismiss(item)` — whose `withAnimation {
                // activeToasts.removeAll }` — synchronously in the same tap.
                // Mutating published state (the activeSearch teardown's
                // two-property didSet, the phase transition) inside that
                // animation transaction is the same re-entrancy class. Defer the
                // state preamble + pipeline kick-off one runloop turn so they
                // land after the dismiss animation; both are MainActor-isolated.
                Task { @MainActor in
                    // Tear down the search sheet and
                    // round-trip `verified -> editing` so runFullPipeline's
                    // canStartPipeline guard passes — the toast fires only from
                    // `.verified`, where the guard would otherwise reject and
                    // strand the user (gone output, disabled Share).
                    Self.prepareForPurgeRerun(
                        documentState: documentState,
                        redactionState: redactionState
                    )
                    coordinator.runFullPipeline(documentOverride: override)
                }
            }
        )
    }

    // MARK: - Keyboard Shortcuts

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        // Keyboard-shortcut entry point honors the
        // phase gate. The `phaseKind == .editing` guard mirrors the
        // `canStartPipeline` / `canMutateRegions` discipline so a
        // mid-pipeline arrow / Escape / Cmd-A press cannot mutate
        // `redactionState.regions` while `.detecting / .redacting /
        // .verifying` owns it. Every key-handler delegate
        // (handleEscapeKey, handleSelectAllKey, nudgeSelection)
        // re-asserts the same guard for defense-in-depth. Spot-check
        // passed — no behavioral change needed.
        guard documentState.phaseKind == .editing else { return .ignored }

        switch press.key {
        case .escape:
            return handleEscapeKey()
        case .upArrow:
            return nudgeSelection(dx: 0, dy: -nudgeDelta.dy)
        case .downArrow:
            return nudgeSelection(dx: 0, dy: nudgeDelta.dy)
        case .leftArrow:
            return nudgeSelection(dx: -nudgeDelta.dx, dy: 0)
        case .rightArrow:
            return nudgeSelection(dx: nudgeDelta.dx, dy: 0)
        default:
            if press.characters == "a", press.modifiers.contains(.command) {
                return handleSelectAllKey()
            }
            return .ignored
        }
    }

    private func handleEscapeKey() -> KeyPress.Result {
        guard documentState.phaseKind == .editing else { return .ignored }
        if !redactionState.selectedRegionIDs.isEmpty {
            redactionState.selectedRegionIDs = []
            return .handled
        }
        // With the polygon tool active and at least
        // one vertex laid, Escape discards the in-progress vertex list
        // without dropping the tool itself — matches the Cancel button
        // in the bottom hint capsule. Must precede the `activeTool !=
        // nil` branch below, which would otherwise swallow the polygon
        // case and switch tools to nil.
        if activeTool == .polygon,
           redactionState.inProgressPolygonVertexCount > 0 {
            coordinator.cancelInProgressPolygon()
            return .handled
        }
        if activeTool != nil {
            activeTool = nil
            return .handled
        }
        return .ignored
    }

    private func handleSelectAllKey() -> KeyPress.Result {
        guard documentState.phaseKind == .editing else { return .ignored }
        let page = documentState.currentPageIndex
        guard let pageRegions = redactionState.regions[page], !pageRegions.isEmpty else { return .ignored }
        redactionState.selectedRegionIDs = Set(pageRegions.map(\.id))
        return .handled
    }

    // MARK: - Keyboard Nudge

    /// Nudge amount in normalized coordinates: ONE PDF point on the
    /// current page, i.e. 1/pageWidth × 1/pageHeight from
    /// the page's crop box; the pre-1.1.0 0.0025 stands in when no page
    /// geometry is available.
    static let nudgeFallback: CGFloat = 0.0025

    static func nudgeDelta(pageSize: CGSize?) -> (dx: CGFloat, dy: CGFloat) {
        guard let size = pageSize, size.width > 0, size.height > 0 else {
            return (dx: nudgeFallback, dy: nudgeFallback)
        }
        return (dx: 1 / size.width, dy: 1 / size.height)
    }

    private var nudgeDelta: (dx: CGFloat, dy: CGFloat) {
        let page = documentState.currentPageIndex
        let size = documentState.sourceDocument?.page(at: page)?.bounds(for: .cropBox).size
        return DocumentEditorView.nudgeDelta(pageSize: size)
    }

    private func nudgeSelection(dx: CGFloat, dy: CGFloat) -> KeyPress.Result {
        guard documentState.phaseKind == .editing,
              !redactionState.selectedRegionIDs.isEmpty else { return .ignored }
        let page = documentState.currentPageIndex
        let moves: [(id: UUID, newRect: CGRect)] = redactionState.selectedRegionIDs.compactMap { id in
            guard let regions = redactionState.regions[page],
                  let region = regions.first(where: { $0.id == id }) else { return nil }
            var rect = region.normalizedRect
            rect.origin.x += dx
            // PDF Y is bottom-left, so up arrow (negative dy in screen) = positive in PDF
            rect.origin.y -= dy
            // Clamp to 0–1
            rect.origin.x = max(0, min(rect.origin.x, 1 - rect.width))
            rect.origin.y = max(0, min(rect.origin.y, 1 - rect.height))
            return (id: id, newRect: rect)
        }
        guard !moves.isEmpty else { return .ignored }
        if moves.count == 1 {
            redactionState.moveRegion(moves[0].id, page: page,
                                      newRect: moves[0].newRect, undoManager: undoManager)
        } else {
            redactionState.moveRegions(moves, page: page, undoManager: undoManager)
        }
        return .handled
    }

    // MARK: - Computed Properties

    private var documentTitle: String {
        documentState.sourceDocument != nil ? "Resecta" : ""
    }
}
