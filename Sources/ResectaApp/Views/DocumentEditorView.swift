import SwiftUI
import UIKit
import StoreKit
import PDFKit
import RedactionEngine

// §A2: Phase body router — switches on documentState.phase inside a ZStack.
// §A3: Toolbar matrix — toolbar items driven by phaseKind.
// C1: Replaces VerificationContainerView approach with full phase router.
// Phase 1A: Export state + dialogs lifted here from VerificationResultsView.

struct DocumentEditorView: View {
    @Environment(DocumentState.self) private var documentState
    @Environment(RedactionState.self) private var redactionState
    @Environment(SettingsState.self) private var settingsState
    @Environment(PipelineCoordinator.self) private var coordinator
    @Environment(AppCoordinator.self) private var appCoordinator
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(ToastQueueManager.self) private var toastManager
    @Environment(\.requestReview) private var requestReview
    // KI-4: scene-phase observer fires the proactive purge re-run toast
    // on `.background → .active`. See `onScenePhaseChange(old:new:)` and
    // `specs/ui/ERROR_UX.md §3.1`.
    @Environment(\.scenePhase) private var scenePhase
    // SEC-3: Capture/mirroring privacy shield. When `isShielded` is true
    // the phase-router body is replaced with `PrivacyShieldView` so the
    // canvas (.editing/.detecting/.redacting/.exporting) and verification
    // results (.verified) never reach a screen recorder or external display.
    @Environment(ScreenCaptureMonitor.self) private var captureMonitor

    // UI_UX §6.2: View-local tool state — purely UI, no cross-view observation needed.
    // D8: Persistent — toggled only by explicit tap, Escape, or Done.
    @State private var activeTool: DrawingTool? = nil

    /// WU-38: iPhone "Select More" toolbar toggle. While on, a tap on a
    /// region toggles its membership in the selection instead of replacing
    /// the selection — iPhone parity for the iPad Shift+tap path. iPad
    /// Shift+tap continues to work whether the toggle is on or off.
    @State private var isMultiSelectActive: Bool = false

    // UI_UX §5.6: Per-document pipeline mode override (nil = use global setting)
    @State private var documentOverride: PipelineMode?

    // §A4.3: Brief status flash state for .verifying → .verified transition
    @State private var showBriefStatus = false
    @State private var briefStatus: VerificationStatus?
    @State private var dismissTask: Task<Void, Never>?

    // GAP-7: Batch delete confirmation
    @State private var showBatchDeleteConfirmation = false

    // GATE-3 (Pkg I): Done confirmation for the verification results screen.
    // Lifted from VerificationActionBar when Done moved into the top-left
    // toolbar. The dialog gates only when drawn regions are present —
    // empty sessions close directly.
    @State private var showDoneConfirmation = false

    // UXC-14: drives the bespoke share-risk confirm sheet shown when a
    // Share tap reaches handleExportTap while the report is FAIL/ATTENTION
    // (not yet overridden), SKIPPED (not yet acknowledged), or an
    // incomplete-WARN (digest-dependent layers skipped, not yet
    // acknowledged). One optional-enum slot replaces the former two
    // booleans — the three families are mutually exclusive by
    // overallStatus, so at most one case is ever non-nil, and the type
    // itself now says so rather than a convention across two Bools.
    @State private var shareRiskConfirmKind: ShareRiskConfirmKind?

    // GAP §6.2: iPad hover popover state
    @State private var showHoverPopover = false
    @State private var hoveredMetadata: RegionMetadata?

    // U4: Search sheet detent for auto-minimize on result navigation
    @State private var searchSheetDetent: PresentationDetent = .medium

    // Detection summary banner
    @State private var detectionBanner: DetectionBannerModel?
    @State private var dismissSummaryTask: Task<Void, Never>?
    // WP4a: Auto-dismiss timer for background resume banner
    @State private var dismissBannerTask: Task<Void, Never>?

    /// Bindings to trigger import/settings from parent ContentView
    @Binding var showFilePicker: Bool
    @Binding var showPhotoPicker: Bool
    @Binding var showSettings: Bool

    enum DrawingTool {
        case rectangle
        /// DRAW-1: tap-to-vertex polygon. Double-tap closes the loop and
        /// commits via `coordinator?.addRegion(_:page:undoManager:)`.
        case polygon
        /// DRAW-1: continuous-touch freeform stroke. On touch-up, the raw
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

    /// DRAW-1: map a `DrawingTool` to the overlay's `ShapeTool`. `nil` is
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

    // MARK: - Body (§A2 Phase Router)

    var body: some View {
        // §A2: ZStack with phase switch (FB91311311 workaround)
        ZStack {
            // SEC-3: When capture/mirroring is active, swap the phase
            // router for the opaque shield. Empty state has no document
            // content, but we shield it anyway — this is the simplest
            // way to keep the threat model uniform (no doc-chrome leakage
            // about whether a document is loaded) and matches the SEC-3
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
                // calling returnHome(). See plan
                // `i-want-you-to-declarative-sparkle.md` Phase 1
                // "Race analysis".
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
                // Phase 3C: Styled import card matching PipelineProgressCard visual.
                // CANCEL-006 / UX-import-cancel-affordance (Pkg B): import is
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
                // §A4.5: Shared PDFDocumentView mount — PipelineProgressCard overlay
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
                    // Detection summary banner (UXF-06: all run outcomes,
                    // not just success — zero/failed previously left no
                    // persistent record).
                    .overlay(alignment: .top) {
                        detectionBannerOverlay
                    }
                    // C9/D11: InlineWarningBanner for background resume
                    // (cancel-from-detecting / cancel-from-redacting path).
                    .overlay(alignment: .top) {
                        if documentState.wasPausedByBackground,
                           documentState.phaseKind == .editing {
                            // Offer the pipeline matching the
                            // phase the user paused from. A detect-pause resumes
                            // detection at the recorded recognition level
                            // (fallback .accurate); any other origin re-runs the
                            // full pipeline (unchanged behavior).
                            let resume = DocumentEditorView.resumeAction(
                                forPausedFrom: documentState.pausedFromPhase)
                            InlineWarningBanner(
                                message: resume == .detect
                                    ? "Detection was paused."
                                    : "Processing was paused. Your drawn regions are preserved.",
                                primaryAction: (
                                    label: resume == .detect ? "Resume Detection" : "Restart",
                                    action: {
                                        dismissBannerTask?.cancel()
                                        switch resume {
                                        case .detect:
                                            coordinator.runDetectionPipeline(
                                                recognitionLevel: documentState.lastUsedRecognitionLevel ?? .accurate)
                                        case .fullPipeline:
                                            coordinator.runFullPipeline(documentOverride: documentOverride)
                                        }
                                    }
                                ),
                                onDismiss: {
                                    dismissBannerTask?.cancel()
                                    documentState.wasPausedByBackground = false
                                    documentState.pausedFromPhase = nil
                                }
                            )
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .padding(.top, ResectaTokens.Spacing.toolbarClearance)
                            .onAppear {
                                dismissBannerTask?.cancel()
                                dismissBannerTask = Task { [weak documentState] in
                                    try? await Task.sleep(for: .seconds(8))
                                    guard !Task.isCancelled else { return }
                                    withAnimation(ResectaTokens.Anim.overlayDismiss) {
                                        documentState?.wasPausedByBackground = false
                                        documentState?.pausedFromPhase = nil
                                    }
                                }
                            }
                        }
                    }
                    // Import annotation notice: the imported source
                    // carries annotations, which the on-screen view draws
                    // but the export raster (built from the page content
                    // stream) does not include. Persistent until the user
                    // dismisses it; yields to the two banners above via
                    // the visibility predicate rather than stacking.
                    .overlay(alignment: .top) {
                        if ImportAnnotationNoticeBanner.isVisible(
                            phaseKind: documentState.phaseKind,
                            annotationTypeCount: ImportAnnotationNoticeBanner.noticeWorthyCount(
                                documentState.sourceAnnotationFindings),
                            dismissed: documentState.annotationNoticeDismissed,
                            pausedBannerActive: documentState.wasPausedByBackground,
                            detectionBannerActive: detectionBanner != nil
                        ) {
                            ImportAnnotationNoticeBanner {
                                withAnimation(ResectaTokens.Anim.overlayDismiss) {
                                    documentState.annotationNoticeDismissed = true
                                }
                            }
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .padding(.top, ResectaTokens.Spacing.toolbarClearance)
                        }
                    }
                    // (CANCEL-009 note: the mid-verify background-resume
                    // banner that used to chain here was structurally
                    // unreachable — it gated on `.verified(report: .skipped)`,
                    // a phase whose router branch renders
                    // `VerificationResultsView`, never this overlay chain.
                    // The recovery CTA now lives on the results screen as the
                    // Run Verification card; see `handleRunVerificationTap`.)
                    // WU-42 M-C.8 / DRAW-1: drawing-mode caption — subtle
                    // banner names the active gesture for the rectangle
                    // tool, and for the polygon tool also surfaces the
                    // in-progress vertex count and Cancel / Close polygon
                    // buttons (DRAW-1 §S2.2).
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
                                .padding(.bottom, ResectaTokens.Spacing.lg)
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
                // D6: Full-screen replacement — verification is a distinct workflow phase
                VerificationProgressView()
                    .transition(reduceMotion
                        ? .opacity
                        : .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .opacity))

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
            } // SEC-3: end of `else` branch on captureMonitor.isShielded
        }
        .animation(ResectaTokens.Anim.resolved(ResectaTokens.Anim.modeTransition, reduceMotion: reduceMotion),
                   value: documentState.phaseKind)
        // SEC-3: also animate the shield in/out so the swap reads as a
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
        // `specs/ui/ERROR_UX.md §3.1` and `KNOWN_ISSUES.md` KI-4.
        .onChange(of: scenePhase) { oldPhase, newPhase in
            handleScenePhaseChange(old: oldPhase, new: newPhase)
        }
        // Phase 5B: Consolidated phase change handler (was two separate .onChange)
        .onChange(of: documentState.phaseKind) { oldKind, newKind in
            // §A4.3: Brief status flash for .verifying → .verified transition
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
        // §A4.3: Brief status flash overlay
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
        // highest-precedence active source. SEARCH-AND-REDACT §6.1
        // (search), WU-71 / [P10] path (a) (rationale). Staged
        // detections ride the search case — the `pendingTriage`
        // observer below keeps `activeSearch` populated while
        // detections are pending.
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
        )) { sheet in
            switch sheet {
            case .search(let searchState):
                SearchAndRedactSheet(searchState: searchState, selectedDetent: $searchSheetDetent)
                    // Conditional dismiss: block swipe-dismiss once the USER has
                    // modified selections this session, so the Dismiss
                    // button's confirmation dialog can't be bypassed.
                    // An untouched sheet swipes away freely (one-tap
                    // dismiss rule). UXC-39: an unreviewed magic-wand
                    // preselect also blocks the swipe now — a
                    // never-reviewed auto-selected set no longer drops
                    // silently.
                    .interactiveDismissDisabled(searchState.requiresDismissConfirmation)
                    // Compact float detent — a fixed title-only hug
                    // (`CompactFloatDetent.swift`, WA/D-75). The PDF
                    // surfaces behind; every control lives at
                    // medium/large. Tap-on-row drops to compact; the
                    // chevron/keyboard navigation path keeps the prior
                    // large → medium semantics so result-list visibility
                    // is preserved while the user scans.
                    .presentationDetents([.compactFloat, .medium, .large], selection: $searchSheetDetent)
                    // WU-59: hide the system drag indicator so the custom
                    // pulsing grabber inside `SearchAndRedactSheet` is the
                    // sole visual cue. Drag still works via the system
                    // gesture on the sheet's top area.
                    .presentationDragIndicator(.hidden)
                    // BH-A-04 — the compact float exists so the user
                    // can interact with the document beneath it, but
                    // without a background-interaction grant UIKit
                    // routed EVERY outside tap (canvas or toolbar) to
                    // sheet dismissal — silently destroying live scan
                    // results, with the sticky detent re-arming the
                    // trap on the next Scan. Interaction is enabled
                    // only up through the compact detent; medium/large
                    // keep the standard dimmed scrim.
                    .presentationBackgroundInteraction(.enabled(upThrough: .compactFloat))
                    // D-70 supersession (SA-2): the D-68
                    // `.presentationContentInteraction(.scrolls)` pin
                    // is RETIRED. D-67 attributed the dead in-list
                    // drags to the custom compact float mixed into the
                    // detent set; the D-70 probe matrix
                    // (18-SCROLL-ARCH §3) corrected the mechanism —
                    // `.automatic` cooperation fails only while the
                    // sheet content carries either of two composition
                    // poisons: a NavigationStack wrapper, or a
                    // horizontal chip ScrollView sibling above the
                    // List. SA-2 removed both, so the system default
                    // (.automatic) now arbitrates cooperatively: one
                    // continuous swipe scrolls the list AND grows or
                    // shrinks the sheet at content edges; the grabber
                    // path still resizes; compactFloat, the BH-A-04
                    // grant, and the hidden indicator are all proven
                    // compatible (probe runs R6/R7). No explicit
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
        // GAP §6.2: iPad hover popover — observe hoveredRegionID on RedactionState
        // GAP-7: VoiceOver announcement on selection count change
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
        // WU-72 / [R-20]: manual-draw nearby-PII nudge observer. The
        // post-add hook on `RedactionState.addRegion` sets
        // `pendingManualDrawNudge` after a `.manual` region commits
        // adjacent (≤ 50 pt normalized) to an unapplied high-confidence
        // PII match. We enqueue a non-modal info toast with an "Add"
        // action that calls `acceptManualDrawNudge(_:undoManager:)`
        // with the nudge captured by value — closure-capture per
        // [RR-23] so the accept path survives the suppression mark
        // below clearing the pending field. The
        // `markManualDrawNudgeSuppressed()` call gates further toasts
        // for the current search session; per [RR-29] the suppression
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
        // DRAW-5: magic-wand "Select all instances" observer. The canvas
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
                // WU-71 — pass the region's forward-rationale, if any, into
                // the popover so the "View rationale" disclosure renders.
                let rationale = redactionState.hoveredRegionID.flatMap {
                    redactionState.rationale(forRegionID: $0)
                }
                RegionInfoPopover(metadata: metadata, rationale: rationale)
                    .frame(minWidth: 160, idealWidth: 200, maxWidth: 260)
                    .presentationCompactAdaptation(.popover)
            }
        }
        // GAP-7: Batch delete confirmation (mechanism-description language)
        .confirmationDialog(
            "Delete \(redactionState.selectedRegionIDs.count) Regions",
            isPresented: $showBatchDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete \(redactionState.selectedRegionIDs.count) Regions",
                   role: .destructive) {
                deleteSelectedRegions()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            // WU-42 M-D.2: page-span line names how many pages the deletion
            // spans so the user can reckon scope before confirming.
            Text(DocumentEditorView.batchDeleteDialogMessage(
                regionCount: redactionState.selectedRegionIDs.count,
                pageCount: DocumentEditorView.selectedPageCount(
                    selectedIDs: redactionState.selectedRegionIDs,
                    pageLookup: redactionState.pageIndex(for:)
                )
            ))
        }
        // GATE-3 (Pkg I): destructive-action confirmation symmetry for
        // the verification-results Done. Same pattern as the Redact /
        // Delete N Regions / Pre-Export / Override-FAIL dialogs. Copy is
        // mechanism-description (ARCH §1.3) — describes what Close does,
        // not an outcome promise. Pinned by
        // VerificationActionBarDoneConfirmationTests.testConfirmationCopyIsMechanismDescription.
        .confirmationDialog(
            "Close this document?",
            isPresented: $showDoneConfirmation,
            titleVisibility: .visible
        ) {
            Button("Close", role: .destructive) {
                performDoneCloseSession()
            }
            .accessibilityIdentifier("verificationActionBarDoneConfirm")
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Drawn regions and verification results will be cleared.")
        }
        // UXC-14: the bespoke share-risk confirm sheet (FAIL/ATTENTION,
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
            // GAP §3.2: Forward toast manager and undo manager to coordinator
            coordinator.toastManager = toastManager
            coordinator.undoManager = undoManager
        }
        // Keyboard shortcuts for editing — handled via single onKeyPress to reduce body complexity
        .onKeyPress(phases: .down, action: handleKeyPress)
        // UI_UX §6.5, §10.1: Page navigation bar on iPhone only (editing phase)
        .safeAreaInset(edge: .bottom) {
            if horizontalSizeClass == .compact,
               documentState.pageCount > 1,
               documentState.phaseKind == .editing {
                PageNavigationBar()
            }
        }
        // §A3: Phase-switched toolbar
        .toolbar {
            // Leading items
            ToolbarItemGroup(placement: .topBarLeading) {
                leadingToolbarItems
            }

            // Trailing items
            ToolbarItemGroup(placement: .topBarTrailing) {
                trailingToolbarItems
            }

            // Editing secondary actions (iPhone overflow menu)
            // Phase 4A: undo/redo moved to trailing toolbar for visibility
            if documentState.phaseKind == .editing, horizontalSizeClass == .compact {
                ToolbarItemGroup(placement: .secondaryAction) {
                    selectionMenu
                    selectMoreToggle
                    deleteButton
                    batchOpsMenu
                    pipelineModePicker
                    openDocumentButton
                }
            }
        }
        .navigationTitle(documentTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Toolbar Leading Items (§A3)

    @ViewBuilder
    private var leadingToolbarItems: some View {
        switch documentState.phaseKind {
        case .editing:
            // Drawing tools.
            // §6.2 / iPhone nav-bar overflow: keep a CONSTANT-width glyph per draw tool
            // and signal "active" via .tint only. A wider active glyph (the former
            // rectangle.dashed.badge.checkmark / scribble.variable) grows the leading
            // ToolbarItemGroup past the bar width and collapses the whole group into the
            // system "…" overflow menu. Polygon keeps hexagon/hexagon.fill — fill variants
            // share advance width, so that selected cue is width-safe.
            Button("Rectangle", systemImage: "rectangle.dashed") {
                activeTool = activeTool == .rectangle ? nil : .rectangle
            }
            .tint(activeTool == .rectangle ? ResectaTokens.BrandTeal.tint : nil)
            .accessibilityIdentifier("drawTool")
            .accessibilityValue(activeTool == .rectangle
                                ? "Drawing mode active" : "Tap to enter drawing mode") // §A8

            // V1.0: the polygon + freeform draw tools are gated off for
            // launch; see `advancedDrawToolsEnabled`. The engine, overlay,
            // and tests are preserved, and the downstream hint-capsule /
            // Escape branches stay inert because `activeTool` can no longer
            // become `.polygon` / `.freeform` while the buttons are hidden.
            if Self.advancedDrawToolsEnabled {
                // DRAW-1 (revised): polygon tool — tap-to-vertex. Close
                // the loop by tapping the first vertex (a ring appears
                // around it once count ≥ 3) or by tapping "Close polygon"
                // in the bottom hint capsule. "Cancel" in the same capsule
                // discards the in-progress vertex list; Escape does the
                // same. See `CANVAS_OVERLAY.md` §S2.2 / DRAW-1.
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

                // DRAW-1: freeform tool — continuous-touch path simplified to
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
            // Done lives top-left on the verification results screen.
            // Lifted from VerificationActionBar when the bottom bar was
            // removed; the GATE-3 confirmation dialog (pinned by ARCH §1.3
            // and VerificationActionBarDoneConfirmationTests) still gates
            // sessions that carry drawn regions.
            Button("Done", systemImage: "checkmark.circle") {
                if hasDrawnRegions {
                    showDoneConfirmation = true
                } else {
                    performDoneCloseSession()
                }
            }
            .accessibilityIdentifier("verificationDoneButton")
        default:
            EmptyView()
        }
    }

    // MARK: - Toolbar Trailing Items (§A3)

    @ViewBuilder
    private var trailingToolbarItems: some View {
        switch documentState.phaseKind {
        case .editing:
            // Phase 4A: Undo/redo always visible (both iPhone and iPad)
            undoRedoButtons

            // iPad: additional edit actions visible in toolbar
            if horizontalSizeClass == .regular {
                selectionMenu
                selectMoreToggle
                deleteButton
                batchOpsMenu
                pipelineModePicker
            }

            // Redact button — always visible
            Button("Redact", systemImage: "scissors") {
                coordinator.runFullPipeline(documentOverride: documentOverride)
            }
            // Pkg D / STATE-3: gate on the full pipeline-start predicate
            // (phase + triage + active task) in addition to the existing
            // effective-regions check. `keyboardShortcut` on a Button
            // inherits the `.disabled` modifier, so Cmd-Shift-R is
            // covered without a separate guard.
            .disabled(!redactionState.hasEffectiveRegions
                      || !documentState.canStartPipeline(with: redactionState))
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .accessibilityIdentifier("redactButton")
            .accessibilityHint(redactionState.hasEffectiveRegions
                               ? "" : "Draw regions or apply Scan or Search results first") // §A8

            settingsButton

        case .detecting, .redacting:
            // §A3: Single cancel button
            Button("Stop Processing", systemImage: "stop.circle") {
                documentState.cancelActivePipeline(redactionState: redactionState)
            }
            .accessibilityIdentifier("stopProcessing")
            .accessibilityHint("Stops processing. Your document is preserved.") // §A8

        case .verifying:
            // §A3: Single cancel button
            Button("Stop Verification", systemImage: "stop.circle") {
                documentState.cancelActivePipeline(redactionState: redactionState)
            }
            .accessibilityIdentifier("stopProcessing")
            .accessibilityHint("Stops processing. Your document is preserved.") // §A8

        default:
            // .verified, .failed — settings gear only.
            // `.empty` flashes Color.clear and auto-returns home
            // (Phase 1 redesign) — this trailing branch is unreachable
            // for that phase but kept as a defense-in-depth fallback
            // during the 150ms debounce window.
            settingsButton
        }
    }

    @ViewBuilder
    private var settingsButton: some View {
        Button("Settings", systemImage: "gearshape") {
            showSettings = true
        }
        .accessibilityIdentifier("settings-button")
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
                // GAP-7: Batch delete confirmation for multi-selection
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

    // WU-39: "More" menu that bundles batch operations on the active
    // selection. Visible only when `selectedRegionIDs.isEmpty == false`,
    // gated by `batchOpsMenuShouldShow(selectedCount:)`. "Delete Selected"
    // routes through the existing `showBatchDeleteConfirmation` dialog
    // so the WU-42 M-D.2 page-span message applies to this entry too.
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

    /// WU-39 visibility predicate. The "More" menu surfaces only when at
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
    /// See plan `i-want-you-to-declarative-sparkle.md` Phase 1
    /// "Race analysis".
    static func shouldAutoReturnHome(
        phaseKind: DocumentState.PhaseKind,
        sourceDocument: PDFDocument?
    ) -> Bool {
        phaseKind == .empty && sourceDocument == nil
    }

    // WU-38: "Select More" toolbar toggle. While on, a tap on a region
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

    // GAP-7: Select All / Deselect All menu — touch-accessible on both platforms
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
                // UXF-22: verb-object menu label (was the bare noun
                // "Selection").
                Label("Select Regions", systemImage: selectedCount > 0
                      ? "checkmark.circle.fill" : "checkmark.circle")
            }
        }
    }

    private var deleteButtonLabel: String {
        let count = redactionState.selectedRegionIDs.count
        return count > 1 ? "Delete \(count) Regions" : "Delete Region"
    }

    private func deleteSelectedRegions() {
        redactionState.deleteSelected(undoManager: undoManager)
    }

    // MARK: - WU-42 M-D.2 — Batch delete dialog page-span helpers

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

    // MARK: - WU-42 M-C.8 — Drawing-mode caption helpers

    /// Caption text shown while the rectangle drawing tool is active.
    /// Mechanism description: names the active gesture so the user knows
    /// what shape the touch will produce.
    static let drawingModeCaption = "Drawing — tap and drag"

    /// DRAW-1 (revised): caption text shown while the polygon tool is
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
    /// active (rectangle or polygon — DRAW-1) AND (b) the document is
    /// in the editing phase. Other phases blur the canvas underneath
    /// their own progress UI, so the caption would be stale.
    static func drawingModeCaptionShouldShow(
        activeTool: DrawingTool?,
        phaseKind: DocumentState.PhaseKind
    ) -> Bool {
        guard phaseKind == .editing else { return false }
        return activeTool == .rectangle || activeTool == .polygon
    }

    /// CANCEL-009 (results-screen card): which pipeline the Run Verification
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

    /// DRAW-1: pick the caption string for whichever drawing tool is
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

    /// DRAW-1: VoiceOver label for the bottom hint capsule. Mirrors the
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

    // UI_UX §5.6: Pipeline mode picker (per-document override)
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
            // UXF-22: verb-object menu label (was the bare noun "Mode").
            Label { Text("Switch Mode") } icon: { effectivePipelineMode.glyph }
        }
        .disabled(documentState.phaseKind != .editing)
        .accessibilityIdentifier("pipelineMode")
    }

    @ViewBuilder
    private var openDocumentButton: some View {
        Button("Open Document", systemImage: "folder") {
            showFilePicker = true
        }
    }

    // MARK: - DRAW-5 Magic Wand

    /// DRAW-5: open / re-use the SearchAndRedactSheet with the magic-wand
    /// term pre-filled and `exactMatch` engaged. Reuses
    /// the search-origin apply (plan §0.4 hard stop — do not
    /// introduce a new apply method). If a search session is already
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
        // DRAW-5 — auto-select every match so the user can apply with one
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

    // MARK: - Verification Done (GATE-3 / Pkg I — lifted from VerificationActionBar)

    /// True when the session carries at least one drawn region. Gates
    /// the Done confirmation dialog on the verification-results screen —
    /// empty sessions close directly. Lifted verbatim from
    /// `VerificationActionBar.hasDrawnRegions` when Done moved into the
    /// top-left toolbar.
    private var hasDrawnRegions: Bool {
        redactionState.regions.values.contains { !$0.isEmpty }
    }

    /// SEC-1 + F-4: tear down the verified session. Lifted verbatim from
    /// `VerificationActionBar.performDoneCloseSession()` — the bar is
    /// gone; the close path now hangs off the top-left Done button.
    /// Extracted so the empty-regions direct path and the
    /// confirmed-with-regions path share one implementation.
    private func performDoneCloseSession() {
        // SEC-1: downgrade temp-file protection before tearing down
        // the session state. Done before clearAll() so the path
        // walked still matches the live session's outputURL.
        coordinator.downgradeTempProtectionOnSessionClose()
        redactionState.clearAll()
        documentState.sourceDocument = nil
        documentState.textLayerStatus = [:]
        documentState.sourceAnnotationFindings = []
        documentState.annotationNoticeDismissed = false
        documentState.currentPageIndex = 0
        documentState.lastUsedPipelineMode = nil
        documentState.wasPausedByBackground = false
        documentState.pausedFromPhase = nil
        documentState.transition(to: .empty)
    }

    // MARK: - Export (Phase 1A — lifted from VerificationResultsView)

    // Q1 / §4.4a defense-in-depth export gate. Lifted from
    // VerificationActionBar so the bar and the Phase 2 action card share
    // one source of truth.
    /// §3.4 FAIL override / "Option B": a standing FAIL verdict (not yet
    /// user-overridden) means Share must route through a one-time "Share
    /// Anyway" confirmation before exporting — it no longer hard-blocks the
    /// Share card. Pure + `static` so the predicate is one source of truth and
    /// is unit-testable without a SwiftUI host (mirrors
    /// `VerificationResultsView.shareDisabled`).
    /// An ATTENTION verdict (un-redacted residual text) keeps the same
    /// one-time confirm: the tier re-class changes presentation, not the
    /// share-time acknowledgment. WARN and PASS stay confirm-free.
    /// UXC-13 (RB-22 + RB-45): `report` alone can no longer answer whether
    /// the confirm is needed — `report.userOverrodeFailure` is a write-only
    /// mirror now (see `DocumentState.failShareAcknowledged`), because a
    /// value that lived and died with the report couldn't be re-armed when
    /// the user backed out of the share sheet without sending (GAP-12).
    /// The predicate takes `acknowledged` as an explicit parameter instead,
    /// sourced at the call site from `DocumentState.failShareAcknowledged`
    /// — `acknowledged == true` makes the confirm a no-op for THIS send
    /// ("confirm once per attempt", not "once per report").
    static func shareNeedsFailConfirm(report: VerificationReport, acknowledged: Bool) -> Bool {
        (report.overallStatus.isFail || report.overallStatus.isAttention)
            && !acknowledged
    }

    /// Skipped-share confirm predicate: a SKIPPED report (verification never
    /// ran — any skip reason) not yet acknowledged for sharing routes the
    /// Share tap through a one-time confirm before exporting. Same shape as
    /// `shareNeedsFailConfirm(report:acknowledged:)`: pure + `static` so it
    /// is unit-testable without a SwiftUI host, and the acknowledgement
    /// conjunct makes it one-time per attempt. WARN and PASS deliberately
    /// stay confirm-free. UXC-13: `acknowledged` is sourced at the call site
    /// from `DocumentState.skippedShareAcknowledged` — see
    /// `shareNeedsFailConfirm(report:acknowledged:)`'s doc comment for why
    /// the report's own `userAcknowledgedSkippedShare` is a write-only
    /// mirror rather than the read source now.
    static func shareNeedsSkippedConfirm(report: VerificationReport, acknowledged: Bool) -> Bool {
        report.overallStatus.isSkipped && !acknowledged
    }

    /// UXC-14 / GAP-14: incomplete-WARN share-risk confirm predicate. A WARN
    /// report whose aggregate carries zero real WARN layers but at least one
    /// SKIPPED layer is the digest-less verify-only degrade
    /// (`VerificationResultsView.mastheadSubtitle`'s "Completed with N of M
    /// checks skipped — results may be incomplete." branch) — the narrow
    /// condition is deliberately identical to that branch's own gate, so the
    /// confirm sheet can reuse its exact sentence with no new string. A WARN
    /// that mixes real WARN layers with skipped ones does NOT take this
    /// confirm (`warnCount == 0` fails) — that combination has no approved
    /// copy and stays confirm-free, same as any other routine WARN. `report`
    /// alone can't carry the acknowledgement (`VerificationReport` lives in
    /// the C-5-fenced Packages/RedactionEngine), so unlike its two siblings
    /// this predicate takes `acknowledged` as an explicit parameter, sourced
    /// at the call site from `DocumentState.incompleteWarnShareAcknowledged`.
    /// Pure + `static` for the same testability reason as the two siblings.
    static func shareNeedsIncompleteWarnConfirm(
        report: VerificationReport, acknowledged: Bool
    ) -> Bool {
        guard report.overallStatus.isWarn else { return false }
        let warnCount = report.layers.filter(\.status.isWarn).count
        let skippedCount = report.layers.filter(\.status.isSkipped).count
        return warnCount == 0 && skippedCount > 0 && !acknowledged
    }

    private func canExport(report: VerificationReport) -> Bool {
        // §3.4 FAIL override / "Option B": a standing FAIL no longer disables
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

    /// UXC-14: title for the bespoke share-risk confirm sheet. One title
    /// across all three confirm families (FAIL/ATTENTION, SKIPPED,
    /// incomplete-WARN) — RB-34 D3; only one title is approved copy, and
    /// re-scoping a second one is out of the sprint's timeline.
    static let shareRiskConfirmTitle = "Share with reported issues?"

    /// List header shown above the at-risk item list — the FAIL/ATTENTION
    /// confirm family only.
    static let shareRiskConfirmListHeader = "The verification check reported:"

    /// At-risk item lines for the FAIL/ATTENTION confirm family: every
    /// failed- or attention-flagged layer's `shortDescription` — already
    /// content-free by ARCH §12.2 (page numbers / key names only, never
    /// matched text). Replaces the retired `shareAnywayConfirmMessage`,
    /// which quoted only the aggregate's first failing layer; this lists
    /// every at-risk layer. Static so the derivation is unit-testable
    /// without a SwiftUI host.
    static func atRiskItemLines(report: VerificationReport) -> [String] {
        report.layers
            .filter { $0.status.isFail || $0.status.isAttention }
            .map(\.shortDescription)
    }

    /// Skip-fact line for the SKIPPED confirm family. A new string — the
    /// former `.alert`-era `shareSkippedConfirmMessage` named both the fact
    /// and the two choices in one sentence; the sheet draws the choices as
    /// the slide control + Go back, so this line names only the fact.
    static let shareRiskConfirmSkipFactLine =
        "Verification did not run on this output."

    /// Deselected-items fact line for the confirm sheet, singular/plural.
    /// Distinct from `VerificationResultsView.deselectionRowText(deselected:
    /// total:)` — different wording ("flagged" not "detected", no "of M"
    /// total) for a different surface. Static so the copy is pinned exactly.
    static func deselectedItemsConfirmLine(count: Int) -> String {
        count == 1
            ? "1 flagged item was deselected before redaction."
            : "\(count) flagged items were deselected before redaction."
    }

    /// UXC-14: engagement-control completion label (the slide track's
    /// visible + accessible text).
    static let shareRiskConfirmSlideLabel = "Slide to share anyway"

    /// Test seam: overridable in tests to assert the confirm's haptic fired
    /// without CoreHaptics/hardware (mirrors the "Test seam:" convention
    /// already used elsewhere, e.g. PipelineCoordinator's replay-order
    /// hooks). `playExportConfirmation()` is the RB-33 minimal DC-022
    /// revival — see ResectaTokens.swift.
    static var shareRiskConfirmHaptic: () -> Void = {
        ResectaTokens.Haptics.playExportConfirmation()
    }

    /// UXC-14 confirm-sheet completion. Records the acknowledgement for
    /// whichever family presented (routes through the same three
    /// DocumentState methods the old two `.alert`s used, plus the new
    /// third), fires the haptic seam once, then re-reads `documentState
    /// .phase` for the live report and exports it — re-reading rather than
    /// trusting `kind`'s captured report mirrors the former `.alert`
    /// actions' lifecycle (a phase change racing the presented sheet is
    /// possible in principle; the re-read is the same defense they used).
    /// A plain `static` function with explicit dependencies (no SwiftUI
    /// coupling) so a unit test can call it directly and assert on
    /// `documentState`, the haptic spy, and the `beginExport` spy.
    static func completeShareRiskConfirm(
        kind: ShareRiskConfirmKind,
        documentState: DocumentState,
        beginExport: (VerificationReport) -> Void
    ) {
        switch kind {
        case .failOrAttention:
            documentState.overrideVerificationFailure()
        case .skipped:
            documentState.acknowledgeSkippedShare()
        case .incompleteWarn:
            documentState.acknowledgeIncompleteWarnShare()
        }
        shareRiskConfirmHaptic()
        if case .verified(let report) = documentState.phase {
            beginExport(report)
        }
    }

    private func handleExportTap(report: VerificationReport) {
        // §3.4 FAIL override / "Option B": a standing FAIL/ATTENTION verdict
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
        // UXC-14 / GAP-14: incomplete-WARN confirm — a WARN whose
        // digest-dependent layers were skipped, not yet acknowledged.
        // Mutually exclusive with both branches above by overallStatus.
        if Self.shareNeedsIncompleteWarnConfirm(
            report: report,
            acknowledged: documentState.incompleteWarnShareAcknowledged
        ) {
            shareRiskConfirmKind = .incompleteWarn(report)
            return
        }
        beginExport(report: report)
    }

    // MARK: - Post-share acknowledgment (UXC-36 / RB-41) + re-arm (UXC-13)

    /// UXC-36: toast enqueued when the share sheet reports the document was
    /// actually sent (`completed == true`) — confirms the app's own action
    /// (handing the file to the share sheet) went through, without naming
    /// which destination the user chose. Never enqueued on cancel — see
    /// `handleShareSheetCompletion`.
    static let sharedAcknowledgmentToast = "Shared."

    /// UXC-13 (RB-22 + RB-45): the share sheet's `completionWithItemsHandler`
    /// routes through this pure static so the re-arm / announce /
    /// record-export decision is unit-testable without
    /// `UIActivityViewController`. `completed == false` means the user
    /// backed out of the sheet without sending — the share-risk confirms
    /// are spent only for a send that actually happened, so a cancelled
    /// attempt re-arms all three (`DocumentState.rearmShareRiskConfirms()`)
    /// for the next Share tap on the same report (GAP-12). `completed ==
    /// true` announces the share (UXC-36) and then records it — the
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

        // UI_UX §5.4: Timestamped filename, no original name (could be sensitive)
        let exportName = "redacted_\(Self.exportFormatter.string(from: Date())).pdf"
        // SEC-2: place the share-export copy inside the per-session
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

        // SEC-1: Apply `.complete` protection to the export copy. The
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
            // Order matters (UXC-13): the transition above restores the
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
            // UXC-13: the share sheet never presented, so no send
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
    /// description per ARCH §1.3: names what
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
    /// `verified -> editing` transition is legal (UI_UX §1.2 transition table).
    /// activeSearch is torn down first (Pkg D / STATE-7): the Search & Redact
    /// sheet mutates `redactionState.regions` and is incompatible with the
    /// `.redacting` / `.verifying` phases the re-run enters.
    @MainActor
    static func prepareForPurgeRerun(
        documentState: DocumentState,
        redactionState: RedactionState
    ) {
        redactionState.activeSearch = nil
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
    /// shows only the title-only handle (WA/D-75) — the coverage panel
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

    /// Which resume pipeline the editing-phase background-
    /// resume banner offers, derived from the phase the user paused from. A
    /// detect-pause resumes detection (partial detection results were discarded
    /// on cancel); any other origin (redact-pause, or unknown) re-runs the full
    /// redact pipeline. Static so the selection is testable without a SwiftUI host.
    enum ResumeAction: Equatable { case detect, fullPipeline }

    static func resumeAction(forPausedFrom phase: DocumentState.PhaseKind?) -> ResumeAction {
        phase == .detecting ? .detect : .fullPipeline
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

    // MARK: - Detection Summary

    /// UXF-06 — banner overlay, extracted from `body` (the inline closure
    /// pushed the type-checker past its budget). The record observer
    /// lives on the always-installed `Group` — driven by the run record,
    /// not the .detecting → .editing phase edge, because a page-0
    /// bootstrap failure degrades without ever leaving .editing, so a
    /// phase-edge trigger missed the failed outcome entirely. `run`
    /// increments per record, so consecutive identical outcomes still
    /// fire the observer.
    private var detectionBannerOverlay: some View {
        Group {
            if let banner = detectionBanner,
               documentState.phaseKind == .editing {
                DetectionSummaryBanner(
                    model: banner,
                    // Review re-entry is additionally gated on the promotion
                    // flag (UXF-29 family): re-staging `detectionResults`
                    // after an apply would stage the already-promoted
                    // detections a second time.
                    showsReviewAction: banner.showsReview
                        && !redactionState.triagePromotionOccurred
                        && !redactionState.detectionResults.isEmpty,
                    onReview: handleBannerReview,
                    onDismiss: {
                        withAnimation { detectionBanner = nil }
                    }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
                .padding(.top, ResectaTokens.Spacing.toolbarClearance)
            }
        }
        .onChange(of: redactionState.lastDetectionRun) { _, record in
            handleDetectionRunChange(record)
        }
        .onAppear {
            // Hydrate from a record written before this view mounted. In
            // production the editor is installed whenever a run finishes
            // (records are per-document and cleared on close), so this
            // only fires for the DEBUG `--seedTriage` path, whose record
            // lands during launch — without it the seeded staged banner
            // never appears on the Simulator.
            if detectionBanner == nil, let record = redactionState.lastDetectionRun {
                handleDetectionRunChange(record)
            }
        }
    }

    /// Phase 1C: Re-populate pendingTriage from stored detectionResults to
    /// re-open the review — now the search sheet's Scan interface, not
    /// the retired standalone triage sheet.
    private func handleBannerReview() {
        detectionBanner = nil
        // Block while a review is already pending (mirrors the
        // pipeline's own entry guard): re-staging would silently reset
        // the user's in-progress selections to the all-deselected
        // arrival default. The pending review is already on screen —
        // dismissing the banner is all this tap should do.
        guard redactionState.pendingTriage == nil else { return }
        guard !redactionState.triagePromotionOccurred,
              !redactionState.detectionResults.isEmpty else { return }
        redactionState.pendingTriage = redactionState.detectionResults
        // Review-first arrival: re-staged detections arrive
        // all-DESELECTED, like every arrival — an empty map, since the
        // one apply path reads an absent id as not accepted.
        redactionState.triageSelections = [:]
        // Deterministic presentation (the observer above also fires,
        // but a direct call doesn't depend on change delivery).
        presentReviewInScanInterface()
    }

    /// Open — or re-target — the one search sheet on its Scan
    /// interface so the staged detections render for review.
    private func presentReviewInScanInterface() {
        // A review is a full-chrome activity: the sheet's detent
        // selection is sticky @State across sheet sessions, and a
        // stale compactFloat (~110 pt) would present the arrival with
        // the review list clipped out of sight. Never LOWER an
        // already-larger detent.
        if searchSheetDetent == .compactFloat {
            searchSheetDetent = .medium
        }
        if let state = redactionState.activeSearch {
            // Sheet already up: surface the review by re-targeting its
            // interface. This is a PROGRAMMATIC transition (no user
            // gesture), so it must not ride the user-transition path:
            // that path's undo toast offered to restore the cleared
            // session — and taking that restore during the pending
            // review buried the review behind the parked switcher (its
            // every entry point disables while detections are staged).
            // Instead the arrival owns the whole transition: cancel any
            // in-flight run (an orphaned task would keep streaming into
            // the review's interface and its completion tail would
            // record a false run outcome), clear the session state the
            // user-transition path would have cleared, and name the
            // drop with a plain notice — no restore affordance. The
            // touched tracker resets with it: the arriving review is a
            // fresh all-deselected selection context, and a Dismiss
            // confirmation about the just-cleared session's work would
            // reference selections the user can no longer see.
            if state.searchModeType != .piiScan {
                state.cancelSearchWithoutAwait()
                let dropped = SearchAndRedactSheet.unappliedMatchCount(in: state)
                if let message = Self.reviewArrivalClearedMessage(unappliedCount: dropped) {
                    toastManager.enqueue(message, severity: .info)
                }
                state.isProgrammaticModeChange = true
                state.searchModeType = .piiScan
                state.clearResults()
                state.piiCategoryFilter = nil
                state.sortOrder = .discoveryOrder
                state.userModifiedSelections = false
                // UXC-39 — the arriving review is a fresh all-deselected
                // context; a stale unreviewed-preselect flag from the
                // cleared session must not carry into it.
                state.hasUnreviewedPreselection = false
            }
        } else {
            let state = SearchState()
            state.searchModeType = .piiScan
            // Deliberately NOT arming `pendingAutoRunScan`: a review
            // arrival presents staged detections; it never starts a run.
            redactionState.activeSearch = state
        }
    }

    /// Notice for the review-arrival re-target when the drop would
    /// otherwise be silent: the arriving review replaces a session that
    /// still held unapplied matches. Returns nil when nothing unapplied
    /// is lost so the common arrival stays toast-free. Deliberately
    /// carries no restore action — restoring the cleared session over a
    /// pending review would bury the review behind its parked entry
    /// points. Pinned by `InterfaceSwitchClearTests`.
    static func reviewArrivalClearedMessage(unappliedCount: Int) -> String? {
        guard unappliedCount > 0 else { return nil }
        let suffix = unappliedCount == 1 ? "" : "es"
        return "Detection review opened — \(unappliedCount) unapplied match\(suffix) cleared."
    }

    /// UXF-06 — rebuild the banner when a detection run records its
    /// outcome. Success outcomes keep the pre-existing 5 s auto-dismiss;
    /// zero/failed records stay until dismissed or the next run replaces
    /// them — a failure notice that vanishes on a timer is no record at all.
    private func handleDetectionRunChange(
        _ record: RedactionState.DetectionRunRecord?
    ) {
        dismissSummaryTask?.cancel()
        guard let record else {
            // Document closed / replaced — drop the stale banner.
            detectionBanner = nil
            return
        }
        let model = Self.detectionBannerModel(
            outcome: record.outcome,
            scanSummary: record.scanSummary,
            pendingTriage: redactionState.pendingTriage,
            // Scan-interface runs disclose OCR skips through the
            // sheet's own per-page banner (ST-83); the pipeline-side
            // skip count belongs to pipeline records only.
            ocrSkippedPageCount: record.scanSummary != nil
                ? 0 : redactionState.ocrPixelCapSkippedPages.count
        )
        withAnimation { detectionBanner = model }
        if model.autoDismisses {
            dismissSummaryTask = Task {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                withAnimation(ResectaTokens.Anim.overlayDismiss) {
                    detectionBanner = nil
                }
            }
        }
    }

    /// UXF-06 — view model for the detection summary banner. One value per
    /// run outcome; pure data so `detectionBannerModel` is unit-testable
    /// without a SwiftUI host (`DetectionBannerModelTests`).
    struct DetectionBannerModel: Equatable {
        let message: String
        /// Whether this outcome supports Review re-entry at all. The view
        /// additionally gates the button on the live promotion flag and
        /// on `detectionResults` being present.
        let showsReview: Bool
        /// Success outcomes keep the 5 s auto-dismiss; zero/failed
        /// records persist until dismissed or the next run.
        let autoDismisses: Bool
        /// Warning icon for zero-with-skips / failed outcomes.
        let isWarning: Bool
    }

    /// Pure banner-model builder covering every `DetectionRunRecord`
    /// outcome, for both run origins. Pipeline-staged records derive
    /// their per-kind "Found …" summary from `pendingTriage`;
    /// Scan-interface records carry their counts in `scanSummary`
    /// (their results live in the sheet's list, not in triage). The
    /// former auto-applied case is retired with the auto-apply setting.
    static func detectionBannerModel(
        outcome: RedactionState.DetectionRunRecord.Outcome,
        scanSummary: RedactionState.DetectionRunRecord.ScanRunSummary?,
        pendingTriage: [Int: [DetectionResult]]?,
        ocrSkippedPageCount: Int
    ) -> DetectionBannerModel {
        switch outcome {
        case .staged:
            // Scan-interface run: counts come from the record itself.
            // No Review action — the results are (or were) on screen in
            // the sheet, and a dismissed sheet's results are cleared by
            // design (re-running the scan restores them).
            if let scanSummary {
                let n = scanSummary.foundCount
                let p = scanSummary.pageCount
                return DetectionBannerModel(
                    message: "Scan found \(n) item\(n == 1 ? "" : "s") across \(p) page\(p == 1 ? "" : "s")",
                    showsReview: false, autoDismisses: true, isWarning: false)
            }
            let pending = pendingTriage ?? [:]
            let flat = pending.values.flatMap { $0 }
            guard !flat.isEmpty else {
                // Staged record but triage already resolved by the time
                // the banner rebuilt (fast Apply) — generic re-entry copy.
                return DetectionBannerModel(
                    message: "Detection finished \u{2014} results were staged for review",
                    showsReview: true, autoDismisses: true, isWarning: false)
            }
            var counts: [String: Int] = [:]
            for det in flat {
                let label: String = switch det.kind {
                case .pii(let kind): kind.accessibilityName
                case .face: "face"
                case .searchMatch: "search match"
                }
                counts[label, default: 0] += 1
            }
            let pages = Set(pending.keys).count
            let parts = counts.sorted(by: { $0.value > $1.value })
                .prefix(3)
                .map { "\($0.value) \($0.key)\($0.value == 1 ? "" : "s")" }
            return DetectionBannerModel(
                message: "Found \(parts.joined(separator: ", ")) across \(pages) page\(pages == 1 ? "" : "s")",
                showsReview: true, autoDismisses: true, isWarning: false)

        case .nothingFound(let pageCount):
            var message = "Detection ran on \(pageCount) page\(pageCount == 1 ? "" : "s") and flagged no items."
            if ocrSkippedPageCount > 0 {
                // ST-83 family — a zero-found run never opens the triage
                // sheet, so its OCR-skip banner can't carry this; the
                // coverage gap must be disclosed here instead.
                message += " \(ocrSkippedPageCount) page\(ocrSkippedPageCount == 1 ? " was" : "s were") too large to scan for text \u{2014} review \(ocrSkippedPageCount == 1 ? "it" : "them") manually."
            }
            return DetectionBannerModel(
                message: message,
                showsReview: false, autoDismisses: false,
                isWarning: ocrSkippedPageCount > 0)

        case .failed:
            return DetectionBannerModel(
                message: "Detection couldn't finish \u{2014} no regions were changed. Manual redaction tools remain available.",
                showsReview: false, autoDismisses: false, isWarning: true)
        }
    }

    // MARK: - Keyboard Shortcuts

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        // GATE-6 (Pkg N): keyboard-shortcut entry point honors the
        // phase gate. The `phaseKind == .editing` guard mirrors Pkg D's
        // `canStartPipeline` / `canMutateRegions` discipline so a
        // mid-pipeline arrow / Escape / Cmd-A press cannot mutate
        // `redactionState.regions` while `.detecting / .redacting /
        // .verifying` owns it. Every key-handler delegate
        // (handleEscapeKey, handleSelectAllKey, nudgeSelection)
        // re-asserts the same guard for defense-in-depth. Spot-check
        // passed in Pkg N — no behavioral change needed.
        guard documentState.phaseKind == .editing else { return .ignored }

        switch press.key {
        case .escape:
            return handleEscapeKey()
        case .upArrow:
            return nudgeSelection(dx: 0, dy: -nudgeAmount)
        case .downArrow:
            return nudgeSelection(dx: 0, dy: nudgeAmount)
        case .leftArrow:
            return nudgeSelection(dx: -nudgeAmount, dy: 0)
        case .rightArrow:
            return nudgeSelection(dx: nudgeAmount, dy: 0)
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
        // DRAW-1 / §S2.2: with the polygon tool active and at least
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

    /// Nudge amount in normalized coordinates (1pt ≈ 1/page-dimension).
    /// Approximate: assumes ~400pt page width, so 1pt ≈ 0.0025.
    private var nudgeAmount: CGFloat { 0.0025 }

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

// MARK: - Detection Summary Banner

/// Inline banner recording how the last detection run ended (UXF-06):
/// found-and-staged, auto-applied, nothing found, or failed. The warning
/// variants swap the icon; layout and styling are shared.
private struct DetectionSummaryBanner: View {
    let model: DocumentEditorView.DetectionBannerModel
    let showsReviewAction: Bool
    let onReview: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: ResectaTokens.Spacing.sm) {
            // Non-warning icon follows the Scan entry point's glyph —
            // the banner is the run-outcome surface for detection runs
            // from either origin; the former sparkle glyph retired with
            // the Auto-Detect menu.
            Image(systemName: model.isWarning
                ? "exclamationmark.triangle.fill"
                : "doc.viewfinder")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(model.message)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            // Phase 1C: Review button re-opens triage sheet
            if showsReviewAction {
                Button("Review") {
                    onReview()
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.tint)
            }
            Button("Dismiss", systemImage: "xmark") {
                onDismiss()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, ResectaTokens.Spacing.md)
        .padding(.vertical, ResectaTokens.Spacing.sm)
        .background(.regularMaterial, in: RoundedRectangle(
            cornerRadius: ResectaTokens.CornerRadius.toast, style: .continuous))
        .padding(.horizontal, ResectaTokens.Spacing.md)
        .accessibilityIdentifier("detectionSummaryBanner")
    }
}

// MARK: - Share-risk confirm sheet (UXC-14)

/// The three families of confirm that route through the bespoke share-risk
/// confirm sheet, each carrying the report that triggered it (for display —
/// `completeShareRiskConfirm` re-reads `documentState.phase` for the actual
/// export, not this captured value). Mutually exclusive by construction:
/// `handleExportTap` sets at most one, gated by `overallStatus`, which can
/// never simultaneously satisfy more than one of the three predicates.
enum ShareRiskConfirmKind: Identifiable {
    /// §3.4 FAIL override / "Option B", widened to ATTENTION (PD-17
    /// residual tier — the tier re-class changes presentation, not the
    /// share-time acknowledgment).
    case failOrAttention(VerificationReport)
    /// Verification never ran (any `SkipReason`).
    case skipped(VerificationReport)
    /// GAP-14: WARN whose digest-dependent layers were skipped.
    case incompleteWarn(VerificationReport)

    var id: String {
        switch self {
        case .failOrAttention: "failOrAttention"
        case .skipped: "skipped"
        case .incompleteWarn: "incompleteWarn"
        }
    }

    /// The captured report, for display derivation.
    var report: VerificationReport {
        switch self {
        case .failOrAttention(let r), .skipped(let r), .incompleteWarn(let r): r
        }
    }

    /// Accessibility identifier of the element that completes the share —
    /// the hidden-but-accessible Button inside `SlideToShareControl` (RB-32
    /// / D6). `shareAnywayConfirm` / `shareSkippedConfirm` are the former
    /// `.alert` Share buttons' identifiers, kept stable across the
    /// alert→sheet restructure; `shareIncompleteWarnConfirm` is new.
    var accessibilityIdentifier: String {
        switch self {
        case .failOrAttention: "shareAnywayConfirm"
        case .skipped: "shareSkippedConfirm"
        case .incompleteWarn: "shareIncompleteWarnConfirm"
        }
    }
}

/// The bespoke share-risk confirm sheet, extracted from DocumentEditorView
/// .body so its modifier chain stays within the type-checker's expression
/// budget (mirrors the former two-.alert `ShareConfirmAlerts` this
/// replaces).
///
/// UXC-14: replaces the former text-variant system `.alert`s for
/// FAIL/ATTENTION and SKIPPED, and adds the third incomplete-WARN family
/// (GAP-14), with one EV-P1-11-shaped content-engaging step: the confirm
/// names the specific at-risk items and requires a swipe-class engagement
/// (never type-to-confirm) rather than a single default-focused alert
/// button. "Slide to share anyway" records the acknowledgement on
/// `documentState` (`completeShareRiskConfirm`), fires the restored
/// `playExportConfirmation()` haptic once, then re-reads the live report
/// and exports it — same post-share lifecycle the former `.alert` Share
/// actions used (02-FIX "Change set 2").
private struct ShareRiskConfirmPresentation: ViewModifier {
    @Binding var kind: ShareRiskConfirmKind?
    let documentState: DocumentState
    let deselectionSnapshot: RedactionState.DeselectionSnapshot?
    let beginExport: (VerificationReport) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(item: $kind) { activeKind in
                ShareRiskConfirmSheet(
                    kind: activeKind,
                    deselectionSnapshot: deselectionSnapshot,
                    onConfirm: {
                        DocumentEditorView.completeShareRiskConfirm(
                            kind: activeKind,
                            documentState: documentState,
                            beginExport: beginExport
                        )
                        kind = nil
                    },
                    onCancel: { kind = nil }
                )
                .presentationDetents([.medium])
            }
    }
}

/// UXC-14 confirm-sheet content. Title is shared across all three families
/// (RB-34 D3); body content is family-specific. The deselected-items line
/// is cross-cutting — it renders whenever `shouldShowDeselectionRow` is
/// true, regardless of which family presented.
struct ShareRiskConfirmSheet: View {
    let kind: ShareRiskConfirmKind
    let deselectionSnapshot: RedactionState.DeselectionSnapshot?
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var atRiskItems: [String] {
        switch kind {
        case .failOrAttention(let report): DocumentEditorView.atRiskItemLines(report: report)
        case .skipped, .incompleteWarn: []
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ResectaTokens.Spacing.lg) {
            Text(DocumentEditorView.shareRiskConfirmTitle)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            // The item list can in principle be long (many failed/attention
            // layers); the slide track below must never sit inside this (or
            // any) ScrollView — a SwiftUI DragGesture inside a ScrollView
            // kills the ScrollView's own scroll.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: ResectaTokens.Spacing.sm) {
                    switch kind {
                    case .failOrAttention:
                        Text(DocumentEditorView.shareRiskConfirmListHeader)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        ForEach(Array(atRiskItems.enumerated()), id: \.offset) { _, line in
                            Label {
                                Text(line).font(.subheadline)
                            } icon: {
                                Image(systemName: "exclamationmark.circle")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    case .skipped:
                        Text(DocumentEditorView.shareRiskConfirmSkipFactLine)
                            .font(.subheadline)
                    case .incompleteWarn(let report):
                        // RB-34 D4: reuse the masthead's own skip-induced-WARN
                        // sentence verbatim — no new string.
                        Text(VerificationResultsView.mastheadSubtitle(report: report))
                            .font(.subheadline)
                    }

                    if VerificationResultsView.shouldShowDeselectionRow(
                        snapshot: deselectionSnapshot),
                       let snapshot = deselectionSnapshot {
                        Text(DocumentEditorView.deselectedItemsConfirmLine(
                            count: snapshot.deselectedCount))
                            .font(.subheadline)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)

            // Footer: plain VStack, never a ScrollView — see the comment
            // above the item-list ScrollView.
            VStack(spacing: ResectaTokens.Spacing.md) {
                SlideToShareControl(
                    label: DocumentEditorView.shareRiskConfirmSlideLabel,
                    accessibilityIdentifier: kind.accessibilityIdentifier,
                    onComplete: onConfirm
                )
                Button("Go back", action: onCancel)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("shareRiskConfirmGoBack")
            }
        }
        .padding(ResectaTokens.Spacing.lg)
    }
}

/// UXC-14 engagement control: a swipe-class, cheap-but-physical slide track
/// (never type-to-confirm). RB-32 / D6: the visible track is the touch
/// path; a hidden-but-accessible `Button` overlaid at a single point off
/// the track's hit area carries the family's stable accessibility
/// identifier and is the VoiceOver / XCUI completion path — VoiceOver
/// activation and XCUITest's `.tap()` both reach a Button directly, where
/// neither can replay a physical drag.
struct SlideToShareControl: View {
    let label: String
    let accessibilityIdentifier: String
    let onComplete: () -> Void

    @State private var dragX: CGFloat = 0
    @State private var trackWidth: CGFloat = 0
    @State private var completed = false

    private let knobDiameter: CGFloat = 44

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.secondary.opacity(0.15))
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            Circle()
                .fill(Color.accentColor)
                .frame(width: knobDiameter, height: knobDiameter)
                .overlay {
                    Image(systemName: "chevron.right.2")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .offset(x: dragX)
                .gesture(dragGesture)
        }
        .frame(height: knobDiameter)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { trackWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, newValue in trackWidth = newValue }
            }
        )
        .accessibilityHidden(true)
        // Positioned above the track (negative y-offset) rather than at any
        // point WITHIN it: the knob's hit area sweeps the whole horizontal
        // range as it drags (x ∈ [0, trackWidth]), so any in-track corner
        // risks the hidden Button's 1×1 frame coinciding with the knob at
        // some position along the slide. Placed outside the vertical range
        // instead, it can never overlap the knob at rest or mid-drag.
        .overlay(alignment: .top) {
            Button(label, action: complete)
                .frame(width: 1, height: 1)
                .opacity(0.02)
                .offset(y: -12)
                .accessibilityIdentifier(accessibilityIdentifier)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !completed, trackWidth > knobDiameter else { return }
                let maxX = trackWidth - knobDiameter
                dragX = min(max(0, value.translation.width), maxX)
            }
            .onEnded { _ in
                guard !completed, trackWidth > knobDiameter else { return }
                let maxX = trackWidth - knobDiameter
                if dragX >= maxX * 0.9 {
                    dragX = maxX
                    complete()
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        dragX = 0
                    }
                }
            }
    }

    private func complete() {
        guard !completed else { return }
        completed = true
        onComplete()
    }
}
