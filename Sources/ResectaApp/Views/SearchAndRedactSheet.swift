import SwiftUI
import UIKit
import PDFKit
import RedactionEngine

// Modal sheet for search-and-redact workflow.
// Follows Safari "Find on Page" pattern adapted for redaction.
//
// Hub view. The toolbar, results list, and footer live in dedicated files
// under `Sources/ResectaApp/Views/Search/`:
// `SearchToolbarSection.swift`, `SearchResultsSection.swift`,
// `SearchFooterSection.swift`, and the Mode picker in `SearchModeContainer.swift`.
// Additional features should land in a new section file under that
// directory, not inline — the audit-lint hook enforces a 1500 LOC cap on
// this hub and a 700 LOC cap on each new file.

/// Single Identifiable enum that drives the consolidated
/// `.sheet(item:)` on `SearchAndRedactSheet`. Replaces four overlapping
/// modifiers (two `.sheet`s, one `.popover`, one `.sheet(item:)`) whose
/// boolean and item-driven bindings could fight over UIKit's
/// single-modal-presenter contract on the hosting view controller.
/// The consolidation also absorbs the per-row rationale sheet as
/// `.rowRationale`; the row signals via an `onRequestShowRationale`
/// callback instead of holding its own `@State`.
enum SearchModal: Identifiable {
    case rationale(ReverseRationaleRequest)
    case rowRationale(rowID: UUID)
    /// Saved-searches recall list.
    case savedSearches

    var id: String {
        switch self {
        case .rationale(let request): return "rationale.\(request.id)"
        case .rowRationale(let rowID): return "rowRationale.\(rowID)"
        case .savedSearches: return "savedSearches"
        }
    }
}

struct SearchAndRedactSheet: View {
    @Bindable var searchState: SearchState
    /// Binding to parent's detent for auto-minimize on result navigation.
    @Binding var selectedDetent: PresentationDetent
    // Visibility note: the @Environment / @State properties below that
    // dropped the `private` modifier are read or written by the
    // `SearchAndRedactSheet+Trigger.swift` and
    // `+AuditExport.swift` extensions. Cross-file
    // extensions cannot see `private`/`fileprivate` members; `internal`
    // (the default) is the smallest visibility that compiles.
    @Environment(RedactionState.self) var redactionState
    @Environment(DocumentState.self) var documentState
    @Environment(ToastQueueManager.self) var toastManager
    @Environment(SettingsState.self) var settingsState
    @Environment(UserTermsStore.self) var userTermsStore
    @Environment(SavedRegexStore.self) var savedRegexStore
    /// Saved-searches recall.
    @Environment(SavedSearchStore.self) var savedSearchStore
    /// Audit-leak fix: `+AuditExport.swift` threads
    /// `pipelineCoordinator.tempExportDirectory` (the hardened
    /// session directory) into `MatchExportService.share`.
    @Environment(PipelineCoordinator.self) var pipelineCoordinator
    /// Read ONCE at sheet level (a stable container view) and
    /// passed down as a value — the let-injection pattern from the toast
    /// dismiss-crash fix (37b56c9); never an @Environment read inside a
    /// view that re-lays-out during sheet dismissal.
    @Environment(ScreenCaptureMonitor.self) var captureMonitor
    @Environment(\.undoManager) var undoManager
    /// Suppression gate for the grabber pulse —
    /// Reduce Motion replaces the pulse with no animation rather than
    /// the `Anim.resolved` fade since the pulse is a one-shot affordance
    /// hint, not a state-change cue. See `CompactFloatDetent.shouldPulseGrabber`.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State var searchDebounceTask: Task<Void, Never>?
    // The prior `applyResultMessage`
    // state field drove an `.alert("Redaction Applied", ...)` that blocked
    // the sheet on every successful apply. Both apply paths now route
    // through `toastManager.enqueue` for a non-modal success toast; the
    // alert and its backing state are removed.
    /// In-flight gate for the async `applySearchResults` call. Set true
    /// at the start of every apply (toolbar Apply or Return-key)
    /// and cleared in a `defer` — disables the Return shortcut Button
    /// so a held key doesn't queue an apply per repeat tick.
    @State private var isApplying = false
    // Dismiss closes in ONE tap, selected or not: a live
    // selection is deselected in-place and the sheet dismisses in the
    // same action — silently, with no confirmation dialog or undo toast
    // (both the prior `showDiscardConfirmation` dialog and the two-tap
    // Done flow that replaced it are gone). See
    // `SearchAndRedactSheet+DiscardUndo.swift` for the selection
    // helpers and the UXF-27 dismissal message.
    @State private var duplicateTermMessage: String?
    @FocusState private var isSearchFieldFocused: Bool
    // `appliedResultIDs` lives on `SearchState`. View-side reads/writes go
    // through `searchState.appliedResultIDs`; cleared symmetrically by
    // `SearchState.clear()` and `clearResults()`.
    @State var searcher = DocumentSearcher()
    /// Controls the match-audit share confirmation dialog.
    @State private var showAuditExport = false

    /// Single sheet-presentation slot. The cases of
    /// `SearchModal` cover what was previously four overlapping modifiers
    /// plus the per-row rationale sheet on `SearchResultRow`. Setting
    /// `activeModal = .X` then `.Y` lets SwiftUI run one dismiss-and-
    /// present cycle instead of stacking presentations on the hosting
    /// `UIViewController`. Cross-file extensions write to this — keep
    /// non-`private`.
    @State var activeModal: SearchModal?

    /// Audit-export schema choice for the confirmation dialog. v4 is
    /// the engine's current default — see
    /// `Packages/RedactionEngine/Sources/RedactionEngine/Export/ExportMetadata.swift`
    /// `init(schemaVersion: UInt8 = 4, ...)` — and the only schema
    /// V1.0 exports.
    /// The state is per-sheet-session — resets on sheet dismiss
    /// because @State on `SearchAndRedactSheet` re-instantiates with
    /// `.v4` on next open.
    @State var auditSchemaVersion: AuditSchemaVersion = .v4

    /// Per-sheet-session pulse gate.
    /// Resets to `false` on `.onDisappear` so the next sheet session
    /// re-enables the pulse. The flag flips to `true` immediately when
    /// the first compact-drop fires, so subsequent compact-drops in the
    /// same session don't re-pulse. Predicate lives on
    /// `CompactFloatDetent.shouldPulseGrabber(...)` for testability.
    @State private var hasPulsedGrabberThisSession: Bool = false

    /// Toolbar "Save as…" prompt state. The in-list save
    /// affordance lives inside `SavedSearchListSheet`; this pair backs the
    /// toolbar menu entry point (visible once a search shape exists).
    @State private var showSavedSearchSavePrompt = false
    @State var savedSearchSaveName: String = ""

    /// UXF-04: "Save current..." (saved-regex menu) naming prompt state.
    /// The alert lives at this sheet's root, the same attachment the
    /// working "Save as…" alert above uses; the menu-side half of the
    /// fix (item ordering) is documented on
    /// `SearchToolbarSection.onRequestSaveCurrentRegex`.
    @State private var showSavedRegexSavePrompt = false
    @State private var savedRegexSaveLabel: String = ""
    @State private var savedRegexSaveError: String?

    /// Scale binding the custom grabber capsule animates against.
    /// `withAnimation(ResectaTokens.Anim.attentionPulse) { ... = 1.4 }`
    /// produces a single up-and-back oscillation; the deferred reset
    /// settles the value back to 1.0 after the pulse cycle so the
    /// scaleEffect doesn't drift if the animation visual+state diverge.
    @State private var grabberPulseScale: CGFloat = 1.0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                SearchToolbarSection(
                    searchState: searchState,
                    duplicateTermMessage: $duplicateTermMessage,
                    onTriggerSearch: triggerSearch,
                    onRequestSaveCurrentRegex: {
                        savedRegexSaveLabel = ""
                        savedRegexSaveError = nil
                        showSavedRegexSavePrompt = true
                    }
                )
                Divider()

                SearchResultsSection(
                    searchState: searchState,
                    selectedDetent: $selectedDetent,
                    onRequestWhy: presentReverseRationale,
                    onApplyShortcut: applyFromKeyboardShortcut,
                    applyShortcutEnabled: applyShortcutEnabled,
                    onRequestShowRationale: { rowID in
                        activeModal = .rowRationale(rowID: rowID)
                    },
                    onTriggerSearch: triggerSearch
                )

                if searchState.filteredCount > 0 {
                    SearchFooterSection(
                        searchState: searchState,
                        showAuditExport: $showAuditExport
                    )
                }
            }
            .navigationTitle("Search & Redact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Dismiss") {
                        // ONE tap closes, selected or not — triage's
                        // Dismiss naming and single-tap behavior (the
                        // prior Done needed a second tap when a
                        // selection existed). A live selection is
                        // deselected in-place and dropped silently: it
                        // only feeds Apply, and re-running the search
                        // restores it. No confirmation dialog, no undo
                        // toast.
                        if searchState.selectedCount > 0 {
                            let snapshot = Self.currentSelectionSnapshot(in: searchState)
                            Self.clearSelection(in: searchState, snapshot: snapshot)
                        } else {
                            // UXF-27: a 0-selected dismissal names what
                            // the close drops when unapplied matches
                            // exist (the driven piiScan case — results
                            // arrive deselected) so the loss isn't
                            // silent. The toast manager outlives the
                            // sheet, so the toast survives dismissal.
                            if let message = Self.dismissClearedMessage(
                                unappliedCount: Self.unappliedMatchCount(in: searchState)
                            ) {
                                toastManager.enqueue(message, severity: .info)
                            }
                        }
                        redactionState.activeSearch = nil
                    }
                    .accessibilityIdentifier("searchDismissButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    // Triage parity: "Apply \(count)" — semibold, no
                    // destructive role, disabled at zero — and the apply
                    // runs directly on tap; the prior "Redact N
                    // instances?" confirmation dialog is gone. The live
                    // count in the label carries the scale, and the
                    // undoable mark plus the "Marked N" toast carry the
                    // confirmation.
                    Button("Apply \(searchState.selectedCount)") {
                        guard !isApplying else { return }
                        // Refuse mutations while the pipeline owns
                        // `redactionState.regions` — same gate as the
                        // `.disabled` below, re-checked in the action
                        // against a pipeline that started after the last
                        // render.
                        guard documentState.canMutateRegions else { return }
                        isApplying = true
                        // Capture selected IDs before apply clears selection
                        let selectedIDs = Set(searchState.results.filter(\.isSelected).map(\.id))
                        Task { @MainActor in
                            defer { isApplying = false }
                            guard let result = await redactionState.applySearchResults(
                                undoManager: undoManager,
                                documentState: documentState
                            ) else {
                                redactionState.activeSearch = nil
                                return
                            }
                            // QW-1 (D06-F3) — union only the results that
                            // produced a region. Overlap-skipped members of
                            // the selection get no audit entry, so they must
                            // not earn the "applied" badge either.
                            searchState.appliedResultIDs.formUnion(result.appliedResultIDs)
                            // Non-modal success toast via the shared
                            // UXF-11 copy builder (`CommitFeedback`) so
                            // the count stays in lockstep with the
                            // triage-apply toasts. `toastManager.enqueue`
                            // coalesces duplicates so repeated taps can't
                            // queue a pile of identical toasts.
                            if let message = CommitFeedback.markedMessage(
                                applied: result.applied,
                                alreadyCovered: result.skippedOverlaps
                            ) {
                                toastManager.enqueue(message, severity: .success)
                            }
                            // Navigate to first affected page
                            if let firstPage = searchState.results.first(where: { selectedIDs.contains($0.id) })?.pageIndex {
                                documentState.currentPageIndex = firstPage
                            }
                        }
                    }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("searchApplyButton")
                    // Also disabled while the pipeline
                    // owns `redactionState.regions` so the mark
                    // write-back transaction cannot interleave
                    // with `.detecting / .redacting / .verifying`.
                    .disabled(searchState.selectedCount == 0
                              || isApplying
                              || !documentState.canMutateRegions)
                }
                // Saved-searches actions surface FLAT in the system
                // overflow (•••) menu — no nested submenu. The list is
                // available in EVERY mode (incl. PII Scan per the design's
                // entry-point note), so both mount in the navigation
                // toolbar's .secondaryAction zone rather than inside the
                // mode-gated SearchToolbarSection rows. "Save as…" is
                // enabled once a search shape exists.
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        activeModal = .savedSearches
                    } label: {
                        Label("Saved Searches", systemImage: "bookmark")
                    }
                    .accessibilityIdentifier("saved-searches-menu")
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        savedSearchSaveName = SavedSearchListSheet.generatedName(for: searchState)
                        showSavedSearchSavePrompt = true
                    } label: {
                        Label("Save as…", systemImage: "plus.circle")
                    }
                    .disabled(!(searchState.results.isEmpty == false
                                || !searchState.queryText.isEmpty
                                || !searchState.searchTerms.isEmpty))
                    .accessibilityIdentifier("saved-searches-save-as")
                }
            }
        }
        // Custom grabber capsule lives in the top safe-area
        // inset so it sits above the navigation bar — the natural
        // grabber position. The system `.presentationDragIndicator` is
        // hidden on the call site (`DocumentEditorView`) so the user
        // sees only this one. Drag still works via the system gesture
        // on the sheet's top area; this capsule is purely visual.
        .safeAreaInset(edge: .top, spacing: 0) {
            grabberCapsule
        }
        // Both apply paths (toolbar Apply and keyboard-shortcut
        // Apply) enqueue a success toast via `toastManager` so the
        // search sheet stays interactive after every apply — no
        // blocking alert, no confirmation dialog.
        // Match audit export. Two share options: abbreviated content
        // (default, safer) and raw content (destructive role). Cancel
        // dismisses without writing anything.
        // The confirmation
        // dialog carries two v4 share `Button`s (redacted + raw) plus
        // a Cancel role, routing through
        // `exportAudit(includeSensitive:schema:)` with `.v4`. The
        // dialog-shape choice (vs. a custom sheet) keeps the
        // three-row `.confirmationDialog` fitting inside the iOS sheet at
        // AX5 since each label is single-line. V1.1+ scope
        // re-introduces a v3 surface only if the per-region exemption
        // tagging deferral lands (a late-cutover deferral).
        // With the audit surfaces hidden for 1.0 the Export Audit
        // button (the only setter of `showAuditExport`) is gone; the
        // constant-false binding keeps this dialog unpresentable too.
        .confirmationDialog(
            "Share match audit log?",
            isPresented: SearchState.searchAuditSurfacesEnabled
                ? $showAuditExport : .constant(false),
            titleVisibility: .visible
        ) {
            Button("Share v4 (redacted content)") {
                Task { await exportAudit(includeSensitive: false, schema: .v4) }
            }
            Button("Share v4 with raw content", role: .destructive) {
                Task { await exportAudit(includeSensitive: true, schema: .v4) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Creates a CSV and JSON record of each detected match and the rule that triggered it. Designed for legal review of detection reasoning. Matched text is abbreviated unless you choose raw content.")
        }
        // One `.sheet(item:)` replaces the prior pair of
        // `.sheet`s and the per-row rationale sheet on
        // `SearchResultRow` — a single presentation slot on the
        // hosting view controller.
        .sheet(item: $activeModal) { modal in
            switch modal {
            case .rationale(let request):
                ReverseRationalePopover(request: request)
                    .environment(settingsState)
                    .environment(userTermsStore)
            case .rowRationale(let rowID):
                rowRationaleSheet(rowID: rowID)
            case .savedSearches:
                // Store re-injected (sheet content does not
                // inherit the presenting hierarchy's environment) and the
                // capture monitor passed as a let per 37b56c9.
                SavedSearchListSheet(
                    searchState: searchState,
                    captureMonitor: captureMonitor,
                    onRecall: { saved in
                        recallSavedSearch(saved)
                    }
                )
                .environment(savedSearchStore)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        // Toolbar "Save as…" prompt (the in-list affordance is
        // the second entry point; both commit through the same capture
        // static).
        .alert("Save Current Search", isPresented: $showSavedSearchSavePrompt) {
            TextField("Name", text: $savedSearchSaveName)
            Button("Save") {
                let trimmed = savedSearchSaveName.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                savedSearchStore.add(SavedSearchListSheet.capture(from: searchState, name: trimmed))
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Saves the current query shape — mode, query text, and filter settings. Never document content or results.")
        }
        // UXF-04: "Save current..." (saved-regex menu) naming prompt.
        // Root-attached for the same reason as the "Save as…" alert
        // above — see `showSavedRegexSavePrompt`. Sentinel-validates via
        // `RegexSentinelCheck.validate(_:)`, then commits through
        // `savedRegexStore.add(label:pattern:)`; on success a toast
        // names where the saved pattern is managed (UXF-20).
        .alert(SearchToolbarSection.saveCurrentRegexMenuItem, isPresented: $showSavedRegexSavePrompt) {
            TextField("Label", text: $savedRegexSaveLabel)
                .textInputAutocapitalization(.words)
            Button("Save") {
                Task { await saveCurrentRegex() }
            }
            .disabled(savedRegexSaveLabel.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {
                savedRegexSaveLabel = ""
                savedRegexSaveError = nil
            }
        } message: {
            if let savedRegexSaveError {
                Text(savedRegexSaveError)
            } else {
                Text("The current pattern will be saved under this label.")
            }
        }
        .onAppear {
            isSearchFieldFocused = true
            // When the sheet appears already carrying a
            // magic-wand pre-fill (the host wrote `queryText` +
            // `preselectIncomingResults = true` before flipping
            // `activeSearch` non-nil), the TextField's `.onChange` does
            // not fire on the initial render — kick off the search here
            // so the first run actually executes. Gated on the
            // magic-wand flag so non-magic-wand sheet sessions retain
            // their existing manual-entry behavior.
            if searchState.preselectIncomingResults,
               !searchState.queryText.isEmpty {
                triggerSearch()
            }
            #if DEBUG
            // Sim-verification hook (read-only MCP — no taps): present
            // the saved-searches list on launch. The arg implies
            // --openSearchSheet at the app root, which mounts this sheet.
            // Focus is dropped so the
            // keyboard does not cover the presented list in screenshots.
            if CommandLine.arguments.contains("--openSavedSearches") {
                isSearchFieldFocused = false
                activeModal = .savedSearches
            }
            // Sim-verification hook: seed a query and run it, so
            // the results-arrival layout states are reachable on the
            // sim drive even when the AX automation server is
            // unavailable.
            if let queryArg = CommandLine.arguments
                .first(where: { $0.hasPrefix("--searchQuery=") })?
                .split(separator: "=").last,
               searchState.searchModeType != .piiScan {
                isSearchFieldFocused = false
                searchState.queryText = String(queryArg)
                triggerSearch()
            }
            // Sim-verification hook: FBSimulator HID cannot
            // synthesize drag gestures, so detent-dependent layout
            // states are unreachable on the MCP sim drive without a
            // programmatic detent. `--searchDetent=<compact|medium|large>`
            // seeds the parent's detent selection binding on appear.
            if let detentArg = CommandLine.arguments
                .first(where: { $0.hasPrefix("--searchDetent=") })?
                .split(separator: "=").last {
                switch detentArg {
                case "compact": selectedDetent = .compactFloat
                case "medium": selectedDetent = .medium
                case "large": selectedDetent = .large
                default: break
                }
            }
            #endif
        }
        .onDisappear {
            // Cancel the in-flight debounce task on sheet
            // dismissal. Without this, a search debounce sleep that was
            // started just before `.onDisappear` fires would still resolve
            // after the sheet vanishes, doing a wasted scan whose
            // results are immediately discarded. Cancelling here also
            // drops the task captures held by the @State property.
            searchDebounceTask?.cancel()
            searchDebounceTask = nil
            searchState.cancelSearchWithoutAwait()
            searchState.clearLivePreview()
            searchState.clear()
            // Reset the per-sheet-session pulse flag
            // so the next sheet session re-enables the first-compact
            // pulse. @State resets automatically on view destruction;
            // the explicit reset is defensive against future refactors
            // that might switch to @SceneStorage by accident.
            hasPulsedGrabberThisSession = false
            grabberPulseScale = 1.0
        }
        // Resolve live-preview NSRanges → normalized rects whenever a
        // new preview snapshot arrives. Only the visible page's ranges are
        // populated by the engine, so we resolve against the visible page.
        .onChange(of: searchState.livePreview) { _, _ in
            resolveAndPublishLivePreviewRects()
        }
        // Page change refreshes preview rects (visible page changed).
        .onChange(of: documentState.currentPageIndex) { _, _ in
            // Page change invalidates current rects; if the new page has no
            // engine-reported matches we publish empty rects via resolve.
            resolveAndPublishLivePreviewRects()
            // Re-run live preview because `currentPageMatches` is keyed to
            // the old visible page — the new page needs fresh ranges.
            scheduleLivePreviewIfApplicable()
        }
        // Scope change re-runs the preview pass with new totals.
        .onChange(of: searchState.navigationScope) { _, _ in
            scheduleLivePreviewIfApplicable()
        }
        // Notify when results are truncated.
        .onChange(of: searchState.resultsAtCap) { _, atCap in
            if atCap {
                toastManager.enqueue(
                    "Search results truncated. Refine your query for more specific matches.",
                    severity: .warning
                )
            }
        }
        // Mode switch cleanup: clear stale results and mode-specific state.
        // User-initiated transitions clear;
        // programmatic transitions (e.g. saved-search recall) set
        // `searchState.isProgrammaticModeChange = true` briefly to
        // preserve applied markers + filter chips. Today every transition
        // is user-initiated, so the gate is always taken.
        .onChange(of: searchState.searchModeType) { oldMode, newMode in
            // UXF-19: snapshot BEFORE `clearResults()` so the undo toast
            // can restore the session ([RR-04] reset-after-check
            // ordering). The unapplied-count is likewise read against
            // the LIVE results array.
            let isProgrammatic = searchState.isProgrammaticModeChange
            let snapshot = Self.modeSwitchSnapshot(of: searchState, previousMode: oldMode)
            let unappliedCount = Self.unappliedMatchCount(in: searchState)
            if !isProgrammatic {
                // `clearResults()` already drops `appliedResultIDs` —
                // no separate `removeAll()` here.
                searchState.clearResults()
                searchState.piiCategoryFilter = nil
                searchState.sortOrder = .discoveryOrder
                // Post-clear undo toast replaces the former pre-clear
                // warning; fires whenever the clear dropped results —
                // including the all-applied case that used to clear
                // silently (pack 01 carve-out B).
                Self.enqueueModeSwitchUndoToast(
                    on: toastManager,
                    searchState: searchState,
                    snapshot: snapshot,
                    isProgrammatic: isProgrammatic,
                    unappliedCount: unappliedCount
                )
            }
            // Reset the programmatic flag AFTER the gated
            // branch so the next programmatic transition starts from
            // `false` and a fresh user transition still defaults to `false`.
            searchState.isProgrammaticModeChange = false
            // UXF-16 — drop the previous mode's preview counters on EVERY
            // user transition: the "Matches this page … Total …" row
            // otherwise sits beside the new mode's empty state right
            // after a switch (demonstrated ts3-01). No immediate
            // reschedule — the persisted query would repopulate the row
            // before the user has interacted with the new mode; the
            // `queryText` onChange below re-schedules on the first edit.
            // Programmatic transitions (saved-search recall) keep the
            // pre-existing schedule so recall still previews immediately.
            searchState.clearLivePreview()
            if newMode != .piiScan && isProgrammatic {
                scheduleLivePreviewIfApplicable()
            }
        }
        // Clear stale applied markers when regions change (undo/redo), but
        // NOT for the apply that just created them: applySearchResults bumps
        // regionVersion in the same MainActor tick as the appliedResultIDs
        // union, so this handler cannot otherwise tell that bump apart from a
        // real undo/redo. The decision is factored into the pure, testable
        // `shouldClearAppliedMarkers(...)` helper.
        .onChange(of: redactionState.regionVersion) { _, newVersion in
            if Self.shouldClearAppliedMarkers(
                newVersion: newVersion,
                lastAppliedVersion: redactionState.lastAppliedSearchRegionVersion,
                isEmpty: searchState.appliedResultIDs.isEmpty
            ) {
                searchState.appliedResultIDs.removeAll()
            }
        }
        // UXF-05 (ts2-04): at the medium detent the fixed chrome above
        // the results list consumes nearly the full sheet height, so
        // arriving results rendered below the fold with the first row
        // clipped at the footer. Raise the detent to large when results
        // arrive while the sheet sits at medium — the blessed small
        // behavior nudge. Never fires from compactFloat (ST-105: the
        // canvas stays interactive behind the sheet by design) and
        // never re-fires while results merely change, only on the
        // empty → non-empty transition. Predicate is static for
        // unit-testability.
        .onChange(of: searchState.results.isEmpty) { wasEmpty, isEmpty in
            if Self.shouldRaiseDetentForArrivedResults(
                wasEmpty: wasEmpty,
                isEmpty: isEmpty,
                currentDetent: selectedDetent
            ) {
                selectedDetent = .large
            }
        }
        // Fire the one-shot grabber pulse on the FIRST detent
        // transition to compact within this sheet session per
        // `CompactFloatDetent.shouldPulseGrabber(...)`. Reduce Motion
        // and the per-session flag both gate the pulse at the
        // predicate seam so the call site stays declarative.
        .onChange(of: selectedDetent, initial: false) { (_: PresentationDetent, newDetent: PresentationDetent) in
            handleDetentChangeForPulse(newDetent: newDetent)
        }
        // Observed on-sim: the app's single toast host
        // lives on ContentView, which renders BEHIND this presented
        // sheet — bottom toasts (the mode-switch undo and apply-success
        // toasts this sheet enqueues) were invisible and their Undo
        // buttons un-tappable while the sheet was up (a tap on the
        // ContentView copy's coordinates hits the sheet/scrim instead).
        // Mount a sheet-local bottom host so this sheet's own toasts
        // render in the presented layer. ContentView's copy stays —
        // it is covered while the sheet is up and takes over if the
        // toast outlives the sheet (e.g. the UXF-27 dismissal toast).
        .overlay(alignment: .bottom) {
            VStack(spacing: ResectaTokens.Spacing.sm) {
                ForEach(toastManager.activeBottomToasts) { item in
                    ToastView(item: item, toastManager: toastManager)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .opacity
                        ))
                        .onTapGesture { toastManager.dismiss(item) }
                }
            }
            .padding(.bottom, ResectaTokens.Spacing.xl)
            .animation(
                ResectaTokens.Anim.resolved(ResectaTokens.Anim.toastIn, reduceMotion: reduceMotion),
                value: toastManager.toastVersion
            )
        }
        // This sheet presents modally ABOVE the
        // editor's shield swap, so it needs its own. Outermost modifier so
        // the entire sheet (toolbar, results, footer) swaps for the shield.
        .shieldedSheetContent(monitor: captureMonitor)
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: ResectaTokens.Spacing.sm) {
            if searchState.searchModeType == .piiScan {
                // PII Scan mode: scan button instead of text field
                Button {
                    triggerSearch()
                } label: {
                    Label("Scan Document", systemImage: "shield.lefthalf.filled")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(searchState.isSearching || searchState.enabledPIICategories.isEmpty)
                .accessibilityLabel("Scan document for PII")
            } else if searchState.searchModeType == .multiTerm {
                TextField("Add term…", text: $searchState.queryText)
                    .textFieldStyle(.roundedBorder)
                    // The typed term may itself be PII
                    // (a user searching their own SSN).
                    .privacySensitive()
                    .focused($isSearchFieldFocused)
                    .onSubmit {
                        // Route every multi-term submission
                        // through the pure validator (length cap BEFORE
                        // duplicate so an over-cap dup-of-existing entry
                        // surfaces the more specific copy).
                        let outcome = Self.validateMultiTermSubmission(
                            rawText: searchState.queryText,
                            existingTerms: searchState.searchTerms
                        )
                        switch outcome {
                        case .rejectedEmpty:
                            return
                        case .rejectedTooLong(let message):
                            searchState.queryText = ""
                            duplicateTermMessage = message
                            return
                        case .rejectedDuplicate(let message):
                            // Case-insensitive duplicate guard.
                            searchState.queryText = ""
                            duplicateTermMessage = message
                            return
                        case .accepted(let trimmed):
                            duplicateTermMessage = nil
                            searchState.searchTerms.append(trimmed)
                            searchState.queryText = ""
                            triggerSearch()
                        }
                    }
                    .accessibilityLabel("Search term input")
            } else {
                TextField("Search text…", text: $searchState.queryText)
                    .textFieldStyle(.roundedBorder)
                    // The typed query may itself be PII.
                    .privacySensitive()
                    .focused($isSearchFieldFocused)
                    .accessibilityLabel("Search text")
                    .onChange(of: searchState.queryText) { _, newValue in
                        debounceSearch(query: newValue)
                        scheduleLivePreviewIfApplicable()
                    }
            }

            if searchState.isSearching {
                Button {
                    Task { await searchState.cancelSearch() }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Cancel search")
            }

            // Prev/Next navigation + position indicator
            if !searchState.results.isEmpty {
                resultNavigationControls
            }
        }
        .padding(.horizontal, ResectaTokens.Spacing.md)
        .padding(.vertical, ResectaTokens.Spacing.sm)
    }

    // MARK: - Grabber Pulse

    /// Custom drag-indicator capsule replacing the system
    /// `.presentationDragIndicator(.visible)` for the search sheet
    /// (hidden in `DocumentEditorView`). 36×5pt matches Apple's system
    /// indicator dimensions; gray fill at 0.4 opacity matches the
    /// system tint within an order of magnitude. Pulse is driven by
    /// `grabberPulseScale` via `Anim.attentionPulse`.
    private var grabberCapsule: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.4))
            .frame(width: 36, height: 5)
            .padding(.top, 6)
            .padding(.bottom, 4)
            .scaleEffect(grabberPulseScale)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }

    /// Detent-change handler for the grabber pulse. Predicate lives on
    /// `CompactFloatDetent.shouldPulseGrabber(...)` so the gating
    /// contract (first-drop, not Reduce Motion, transitions to
    /// compact) is unit-tested separately from this view-side wiring.
    /// The deferred reset settles `grabberPulseScale` back to 1.0
    /// after the 0.45s pulse + 0.45s autoreverse so the scaleEffect
    /// converges to the neutral value even if the visual + state
    /// values diverge during the animation.
    private func handleDetentChangeForPulse(newDetent: PresentationDetent) {
        guard CompactFloatDetent.shouldPulseGrabber(
            transitioningTo: newDetent,
            hasAlreadyPulsed: hasPulsedGrabberThisSession,
            reduceMotion: reduceMotion
        ) else { return }
        hasPulsedGrabberThisSession = true
        withAnimation(ResectaTokens.Anim.attentionPulse) {
            grabberPulseScale = 1.4
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(950))
            grabberPulseScale = 1.0
        }
    }

    // MARK: - Result Navigation

    private var resultNavigationControls: some View {
        HStack(spacing: ResectaTokens.Spacing.xs) {
            HStack(spacing: 2) {
                Button {
                    searchState.navigateToPrevious(currentPageIndex: documentState.currentPageIndex)
                    navigateToCurrentResult()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .accessibilityLabel("Previous result")
                .keyboardShortcut("g", modifiers: [.command, .shift])

                Button {
                    searchState.navigateToNext(currentPageIndex: documentState.currentPageIndex)
                    navigateToCurrentResult()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .accessibilityLabel("Next result")
                .keyboardShortcut("g", modifiers: .command)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            // Counter respects active filters. When no filter is
            // active (filteredCount == totalCount) the simple 1-of-N form
            // is shown. When a filter is active the counter shows the
            // position within the visible filtered set; an en dash (–)
            // signals that the current result is hidden by the filter.
            if let idx = searchState.currentResultIndex {
                if searchState.filteredCount == searchState.totalCount {
                    Text("\(idx + 1)/\(searchState.totalCount)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Result \(idx + 1) of \(searchState.totalCount)")
                } else if let filteredPos = searchState.currentResultFilteredPosition {
                    Text("\(filteredPos)/\(searchState.filteredCount)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Result \(filteredPos) of \(searchState.filteredCount), \(searchState.totalCount - searchState.filteredCount) filtered")
                } else {
                    Text("–/\(searchState.filteredCount)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Current result hidden by filters, \(searchState.filteredCount) of \(searchState.totalCount) shown")
                }
            }
        }
    }

    private func navigateToCurrentResult() {
        guard let result = searchState.currentResult else { return }
        documentState.currentPageIndex = result.pageIndex
        // Only minimize from .large; preserve .medium so results list stays visible
        if selectedDetent == .large {
            selectedDetent = .medium
        }
    }

    // MARK: - Search Trigger

    // MARK: - Live Preview

    fileprivate func scheduleLivePreviewIfApplicable() {
        guard let liveDoc = documentState.sourceDocument,
              searchState.searchModeType != .piiScan
        else {
            searchState.clearLivePreview()
            return
        }
        // The preview text-walk reads a private copy off the live
        // instance; the rect resolution (resolveAndPublishLivePreviewRects)
        // stays on the LIVE page on MainActor. A nil copy ⇒ clear the preview
        // rather than read the shared instance the PDFView renders. The engine
        // path never invokes OCR for live preview.
        guard let previewDoc = DocumentState.makeSearchCopy(of: SendablePDFDocument(liveDoc)) else {
            searchState.clearLivePreview()
            return
        }
        searchState.scheduleLivePreview(
            searcher: searcher,
            currentPageIndex: documentState.currentPageIndex,
            totalPageCount: liveDoc.pageCount,
            pageTextProvider: { idx in
                guard idx >= 0 && idx < previewDoc.document.pageCount else { return nil }
                return previewDoc.document.page(at: idx)?.string
            }
        )
    }

    fileprivate func resolveAndPublishLivePreviewRects() {
        guard let preview = searchState.livePreview,
              let doc = documentState.sourceDocument,
              let page = doc.page(at: documentState.currentPageIndex)
        else {
            searchState.setLivePreviewRects([])
            return
        }
        let rects = PageHighlightOverlay.resolveRects(
            for: preview.currentPageMatches,
            page: page,
            searcher: searcher
        )
        searchState.setLivePreviewRects(rects)
    }

    // MARK: - Apply (keyboard shortcut)

    fileprivate func applyFromKeyboardShortcut() {
        guard !isApplying else { return }
        // Keyboard-shortcut Apply path mirrors the
        // toolbar Apply gate — refuse mutations while the
        // pipeline owns `redactionState.regions`.
        guard documentState.canMutateRegions else { return }
        guard searchState.selectCurrentMatchIfNoneSelected() else { return }
        isApplying = true
        let selectedIDs = Set(searchState.results.filter(\.isSelected).map(\.id))
        Task { @MainActor in
            defer { isApplying = false }
            guard let result = await redactionState.applySearchResults(
                undoManager: undoManager,
                documentState: documentState
            ) else {
                return
            }
            // QW-1 (D06-F3) — survivors only, mirroring the
            // toolbar Apply path above.
            searchState.appliedResultIDs.formUnion(result.appliedResultIDs)
            // Keyboard-shortcut path
            // mirrors the toolbar Apply path — non-modal toast via
            // the shared UXF-11 copy builder, which returns nil for a
            // no-op apply so a held shortcut against an all-overlap
            // selection still emits no "Marked 0" message.
            if let message = CommitFeedback.markedMessage(
                applied: result.applied,
                alreadyCovered: result.skippedOverlaps
            ) {
                toastManager.enqueue(message, severity: .success)
            }
            if let firstPage = searchState.results.first(where: { selectedIDs.contains($0.id) })?.pageIndex {
                documentState.currentPageIndex = firstPage
            }
        }
    }

    /// Forwarded to `SearchResultsSection` so the invisible Return-shortcut
    /// Button can disable itself during an in-flight apply.
    fileprivate var applyShortcutEnabled: Bool { !isApplying }

    // `debounceSearch(query:)`, `triggerSearch()`, and the static
    // helpers (`firstPageText(of:)`, `makeCoverageReport(...)`) live in
    // `Search/SearchAndRedactSheet+Trigger.swift`.

    // MARK: - Saved-Search Recall

    /// Apply a saved shape and re-run the search. The list sheet dismisses
    /// first (single-modal slot); recall then restores the shape via the
    /// testable static and triggers through the standard path. If the
    /// recalled filter state hides every result, the existing
    /// "filters hide all candidates" empty state surfaces (already
    /// implemented in SearchResultsSection; no new copy).
    private func recallSavedSearch(_ saved: SavedSearch) {
        activeModal = nil
        SavedSearchListSheet.apply(saved, to: searchState)
        triggerSearch()
    }

    private func presentReverseRationale(for result: SearchResult) {
        let doctype = searchState.lastDoctypeExplanation?.primary
        let context: String = {
            let snippet = result.contextSnippet
            if snippet.contains(result.matchedText) { return snippet }
            return "\(snippet) \(result.matchedText)"
        }()
        activeModal = .rationale(ReverseRationaleRequest(
            snippet: result.matchedText,
            fullContext: context,
            doctype: doctype
        ))
    }

    /// Content for the per-row rationale case of `activeModal`.
    /// Looks up the row by id from `searchState.results`; if the row is
    /// no longer present (rare race during result-list updates), the
    /// sheet renders an empty view and SwiftUI dismisses on the next
    /// update cycle.
    @ViewBuilder
    private func rowRationaleSheet(rowID: UUID) -> some View {
        if let result = searchState.results.first(where: { $0.id == rowID }) {
            MatchRationaleSheet(result: result)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        } else {
            EmptyView()
        }
    }

    // `exportAudit(includeSensitive:)` lives in
    // `Search/SearchAndRedactSheet+AuditExport.swift`.

    func buildSearchMode() -> SearchMode {
        let options = searchState.options
        switch searchState.searchModeType {
        case .text:
            return .text(searchState.queryText, options: options)
        case .regex:
            return .regex(searchState.queryText, options: options)
        case .multiTerm:
            return .multiTerm(searchState.searchTerms, options: options)
        case .piiScan:
            return .piiScan(categories: searchState.enabledPIICategories, options: options)
        }
    }

    /// UXF-05 (ts2-04) — pure decision for the results-arrival detent
    /// raise. True only on the empty → non-empty transition while the
    /// sheet sits at `.medium`: compactFloat is a deliberate
    /// canvas-visible state (ST-105) and large already shows the list,
    /// so neither is touched. Static so `SearchDetentRaiseTests` pins
    /// the contract without driving the SwiftUI render cycle.
    static func shouldRaiseDetentForArrivedResults(
        wasEmpty: Bool,
        isEmpty: Bool,
        currentDetent: PresentationDetent
    ) -> Bool {
        wasEmpty && !isEmpty && currentDetent == .medium
    }

    // Pure decision used by the `regionVersion` onChange handler,
    // factored out so it is unit-testable without driving the SwiftUI render
    // cycle. Returns false for the apply's own bump (`newVersion` equals the
    // version that apply recorded) so the just-applied markers persist;
    // returns true for a real undo/redo bump (any other version) when there
    // are markers to drop.
    static func shouldClearAppliedMarkers(
        newVersion: Int,
        lastAppliedVersion: Int,
        isEmpty: Bool
    ) -> Bool {
        if newVersion == lastAppliedVersion { return false }
        return !isEmpty
    }

    // MARK: - Save current regex (UXF-04)

    /// Success toast for a committed "Save current..." — names where the
    /// saved pattern is managed so the save isn't a dead end (UXF-20).
    /// SAFE copy — factual destination, no outcome promise.
    static let savedRegexSavedToast = "Saved — manage in Settings → Saved Regexes"

    /// Sentinel-validate then commit a "Save current..." request against
    /// the app-wide store. Returns nil on success, or the user-facing
    /// error message to re-present in the naming alert. Static seam so
    /// the full round-trip (validate → `SavedRegexStore.add` → persist)
    /// is unit-testable without hosting the sheet.
    static func commitSaveCurrentRegex(
        label: String,
        pattern: String,
        store: SavedRegexStore
    ) async -> String? {
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        let trimmedPattern = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmedLabel.isEmpty, !trimmedPattern.isEmpty else {
            return "Label and pattern must not be empty."
        }
        let accepted = await RegexSentinelCheck.validate(trimmedPattern)
        guard accepted else {
            return String(
                localized: "profile.regex.sentinel.rejected",
                table: "Legal",
                bundle: .main
            )
        }
        guard store.add(label: trimmedLabel, pattern: trimmedPattern) else {
            return "Pattern rejected. Check syntax, length, or label uniqueness."
        }
        return nil
    }

    /// Alert "Save" action: commit, then either toast success (naming
    /// the management surface) or re-present the alert with the error.
    private func saveCurrentRegex() async {
        let error = await Self.commitSaveCurrentRegex(
            label: savedRegexSaveLabel,
            pattern: searchState.queryText,
            store: savedRegexStore
        )
        if let error {
            savedRegexSaveError = error
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            showSavedRegexSavePrompt = true
        } else {
            savedRegexSaveLabel = ""
            savedRegexSaveError = nil
            toastManager.enqueue(Self.savedRegexSavedToast, severity: .success)
        }
    }
}
