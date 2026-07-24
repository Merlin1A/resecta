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
    /// One-shot debounce suppression for programmatic `queryText`
    /// writes that carry their own trigger (recall chips): the field's
    /// `.onChange` consumes it instead of arming the 300 ms debounce,
    /// so a recalled query runs exactly once instead of once now and
    /// once again at debounce expiry.
    @State var suppressNextQueryDebounce = false
    // The prior `applyResultMessage`
    // state field drove an `.alert("Redaction Applied", ...)` that blocked
    // the sheet on every successful apply. Both apply paths now route
    // through `toastManager.enqueue` for a non-modal success toast; the
    // alert and its backing state are removed.
    /// In-flight gate for the async search-origin apply call. Set true
    /// at the start of every apply (toolbar Apply or Return-key)
    /// and cleared in a `defer` — disables the Return shortcut Button
    /// so a held key doesn't queue an apply per repeat tick.
    /// Internal (not private): the apply handlers live in the
    /// `+Trigger` extension file.
    @State var isApplying = false
    // Conditional dismiss: Dismiss is conditional on user selection work: an
    // untouched sheet closes in one tap (a live machine-made selection,
    // e.g. the magic-wand preselect, is deselected in-place on the way
    // out); once the USER has modified selections this session
    // (`searchState.userModifiedSelections`), Dismiss routes through a
    // confirmation dialog. This generalizes the retired triage sheet's
    // confirm-if-selections-touched rule to the whole surface and
    // consciously supersedes the prior one-tap-always ruling: under
    // all-deselected arrival, every live selection is deliberate opt-in
    // work. See `SearchAndRedactSheet+DiscardUndo.swift` for the
    // selection helpers and the UXF-27 dismissal message (untouched
    // path only — the dialog already names the drop on the other).
    // Visibility: read/written by the sheetHeaderChrome builder in
    // `SearchSheetHeaderSection.swift` (cross-file extension — the
    // established +Trigger pattern; internal is the smallest
    // visibility that compiles).
    @State var showDismissConfirmation = false
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

    /// UXF-04: "Save current..." (saved-regex menu) naming prompt state.
    /// The alert lives at this sheet's root — the attachment that stays
    /// presentable after the triggering Menu dismisses; the menu-side
    /// half of the fix (item ordering) is documented on
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

    /// Review-mode kind filter, hoisted to the sheet so the footer's
    /// Select All can target the VISIBLE (kind-filtered) findings —
    /// mirroring the search footer's filtered-only semantics.
    @State private var reviewFilterKind: DetectionResult.Kind? = nil

    // MARK: - Absorbed review (detection findings)

    /// Whether the Scan interface is presenting staged detections
    /// for review. The staged set (`pendingTriage`) is the
    /// store of record; the unified sheet is its one surface.
    var isReviewActive: Bool {
        redactionState.pendingTriage != nil
            && searchState.searchModeType.interface == .scan
    }

    private var reviewFindings: [(page: Int, detection: DetectionResult)] {
        ScanReviewSection.flattenedFindings(redactionState.pendingTriage)
    }

    /// Toolbar "Apply N" count for the review origin — explicit-true
    /// entries only. Producer sites write an explicit entry per staged
    /// detection with an explicit true entry, so this count and the apply's
    /// accepted set describe the same selections.
    var reviewAcceptedCount: Int {
        redactionState.triageSelections.values.count { $0 }
    }

    private var reviewVisibleIDs: [UUID] {
        ScanReviewSection.filteredFindings(
            reviewFindings, filterKind: reviewFilterKind, viewMode: .byPage
        ).map(\.detection.id)
    }

    /// Full-chrome composition (medium / large detents). The
    /// presentation-level modifier chain (single modal slot, onChange
    /// handlers, sheet-local toast host, shield) lives on `body`'s
    /// shared container so BOTH compositions keep it.
    private var fullSheetContent: some View {
        // SA-2 (D-70): the NavigationStack wrapper is RETIRED and the
        // sheet's fixed chrome rides the active List's top safe-area
        // insets instead of stacking above it as VStack siblings. The
        // SA-2 bisect corrected the D-70 poison model (18- §10):
        // UISheetPresentationController's `.automatic` cooperation
        // binds only to a scroll view whose top edge sits at/near the
        // sheet's content top (~40 pt tolerance on this device
        // class) — the chrome's SPECIES never mattered, its HEIGHT
        // did. Chrome stacked as siblings pushed the List past that
        // threshold, so every sibling composition was dead. With the
        // chrome in `.safeAreaInset(edge: .top)` layers the List's
        // UIKit frame binds at the sheet top and one-swipe
        // scroll↔detent cooperation is native (probe SPIKE-1a/b:
        // listY 415→62 cooperative expand with the full chrome load
        // in the inset).
        Group {
            if isReviewActive {
                VStack(spacing: 0) {
                    // Absorbed review: staged detections render
                    // inside the Scan interface. Run affordances are
                    // parked while the review is pending — resolve it
                    // (Apply / Dismiss) to scan again.
                    ScanReviewSection(
                        searchState: searchState,
                        filterKind: $reviewFilterKind,
                        onRequestWhy: { request in
                            activeModal = .rationale(request)
                        },
                        // SA-3 rider (B-3): review rows navigate the
                        // canvas with the search rows' shipped idiom —
                        // page write + compact drop (page-granular by
                        // ruling; ST-105 keeps the canvas interactive
                        // behind the compact float).
                        onNavigateToPage: { page in
                            documentState.currentPageIndex = page
                            if selectedDetent != .compactFloat {
                                selectedDetent = .compactFloat
                            }
                        }
                    )
                    .safeAreaInset(edge: .top, spacing: 0) {
                        sheetHeaderChrome
                    }

                    if !reviewFindings.isEmpty {
                        SearchFooterSection(
                            searchState: searchState,
                            showAuditExport: $showAuditExport,
                            review: SearchFooterSection.ReviewFooterModel(
                                selectedCount: reviewAcceptedCount,
                                visibleCount: reviewVisibleIDs.count,
                                allVisibleSelected: allReviewVisibleSelected,
                                onToggleSelectAll: toggleReviewSelectAll
                            )
                        )
                    }
                }
            } else {
                VStack(spacing: 0) {
                    SearchResultsSection(
                        searchState: searchState,
                        selectedDetent: $selectedDetent,
                        onRequestWhy: presentReverseRationale,
                        onApplyShortcut: applyFromKeyboardShortcut,
                        applyShortcutEnabled: applyShortcutEnabled,
                        onRequestShowRationale: { rowID in
                            activeModal = .rowRationale(rowID: rowID)
                        },
                        onTriggerSearch: triggerSearch,
                        onRecallQuery: { query in
                            // One run per recall: suppress the
                            // `.onChange` debounce the write below arms,
                            // then trigger directly.
                            suppressNextQueryDebounce = true
                            searchState.queryText = query
                            triggerSearch()
                        },
                        onShowSavedSearches: {
                            activeModal = .savedSearches
                        },
                        onNavigateToCurrentResult: navigateToCurrentResult
                    )
                    .safeAreaInset(edge: .top, spacing: 0) {
                        // The Search interface's whole fixed chrome
                        // joins the header in ONE inset stack — the
                        // search bar, toolbar, and separator must not
                        // re-offset the results list's frame (the
                        // same threshold, 18- §10).
                        VStack(spacing: 0) {
                            sheetHeaderChrome
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
                        }
                        .background(.background)
                    }

                    if searchState.filteredCount > 0 {
                        SearchFooterSection(
                            searchState: searchState,
                            showAuditExport: $showAuditExport
                        )
                    }
                }
            }
        }
        // Conditional dismiss: conditional Dismiss confirmation, the retired
        // triage sheet's donor rule generalized. Copy is
        // mechanism-description (ARCH §1.3) — names what the action
        // does without an outcome promise. Attached to the content
        // Group (not the outer modifier chain) to stay inside the
        // type-checker budget beside the audit-export dialog.
        .confirmationDialog(
            Self.dismissTitle,
            isPresented: $showDismissConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) {
                performDismiss(afterConfirmation: true)
            }
            .accessibilityIdentifier("searchDismissConfirmButton")
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(Self.dismissMessage)
        }
    }

    var body: some View {
        // BH-B-01 — compactFloat composition branch: compressed into
        // ~110–131pt the full NavigationStack chrome z-overlapped into
        // unusable rows and NONE of the detent's promised controls
        // (search bar, nav chevrons, first result row —
        // `CompactFloatDetent.swift` contract) were visible. Render the
        // documented strip at the compact detent instead; the full
        // chrome returns at medium/large. The review origin gets a
        // one-line selection summary (arrivals raise the detent — the
        // strip is the drag-down residue state).
        Group {
            if selectedDetent == .compactFloat {
                compactFloatStrip
            } else {
                fullSheetContent
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
        // UXF-04: "Save current..." (saved-regex menu) naming prompt.
        // Root-attached — see `showSavedRegexSavePrompt`. Sentinel-validates via
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
            // BH-B-01 rider — no auto-focus at the compact detent
            // (sticky-detent reopen): the raised keyboard would cover
            // the very document the float exists to expose.
            isSearchFieldFocused = selectedDetent != .compactFloat
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
            // One-tap contract: the toolbar Scan button armed a
            // one-shot flag before presenting. Consume it exactly once
            // here — this is the sole trigger for the auto-run.
            // Overlapping `triggerSearch()` callers additionally
            // coalesce through the single-flight gate
            // (`beginTriggerSetup`), so a second same-turn trigger site
            // re-runs once instead of racing; the single consume stays
            // the first line of defense. Mutually exclusive with the
            // magic-wand branch above by construction (magic wand seeds
            // `.text`; the Scan button seeds the scan mode).
            if searchState.pendingAutoRunScan {
                searchState.pendingAutoRunScan = false
                if searchState.searchModeType == .piiScan {
                    triggerSearch()
                }
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
            // Skipped when a magic-wand pre-fill already ran above —
            // overlapping calls would coalesce through the
            // single-flight gate, but one deliberate trigger per
            // launch stays the cleaner contract.
            if let queryArg = CommandLine.arguments
                .first(where: { $0.hasPrefix("--searchQuery=") })?
                .split(separator: "=").last,
               searchState.searchModeType != .piiScan,
               !searchState.preselectIncomingResults {
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
                // Belt: no user-initiated mode/interface change may
                // leave an in-flight scan running — an orphaned task
                // would keep appending into the new mode's list and its
                // completion tail would record a false run outcome. The
                // pickers gate on `isSearching`, so this is
                // defense-in-depth for any future un-gated write.
                // (Programmatic recall skips this: its own
                // `triggerSearch()` cancels-and-awaits the prior task.)
                searchState.cancelSearchWithoutAwait()
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
                    redactionState: redactionState,
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
        // NOT for the apply that just created them: the search-origin apply bumps
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
            // BH-B-01 rider — dropping to compact releases field focus
            // so the keyboard never sits over the exposed document.
            if newDetent == .compactFloat {
                isSearchFieldFocused = false
            }
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

    // MARK: - compactFloat Strip (BH-B-01)

    /// The compact detent's documented composition: the search bar row
    /// (field + cancel + result-nav chevrons) over ONE line naming the
    /// current result — nothing else. While a run is in flight the
    /// result line yields to the toolbar's progress line (same strings)
    /// so the H-202 compact progress state survives the recomposition.
    @ViewBuilder
    private var compactFloatStrip: some View {
        VStack(spacing: 0) {
            if isReviewActive {
                compactReviewSummaryLine
            } else {
                searchBar
                if searchState.isSearching {
                    compactScanProgressLine
                } else {
                    compactCurrentResultLine
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("compactFloatStrip")
    }

    /// Review origin at the compact detent: a one-line selection
    /// summary through the footer's pinned label builder (no new
    /// strings). Review arrivals raise the detent
    /// (`presentReviewInScanInterface`), so this renders only after a
    /// deliberate drag-down.
    private var compactReviewSummaryLine: some View {
        HStack {
            Text(SearchFooterSection.selectionCountLabel(
                selected: reviewAcceptedCount,
                total: reviewVisibleIDs.count
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, ResectaTokens.Spacing.md)
        .padding(.vertical, ResectaTokens.Spacing.sm)
    }

    /// Byte-identical to the toolbar section's progress row so the
    /// compact in-flight state introduces no new strings.
    private var compactScanProgressLine: some View {
        HStack {
            ProgressView()
                .controlSize(.small)
            Text("Scanning page \(searchState.currentSearchPage) of \(searchState.totalPages)…")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(searchState.totalCount) found")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, ResectaTokens.Spacing.md)
    }

    /// One-line readout of the row the chevrons navigate (falls back
    /// to the first result — the contract's "first result row").
    /// Blank when no results exist: the field alone invites a query.
    @ViewBuilder
    private var compactCurrentResultLine: some View {
        if let current = searchState.currentResult ?? searchState.results.first {
            HStack(spacing: ResectaTokens.Spacing.xs) {
                if searchState.appliedResultIDs.contains(current.id) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .accessibilityLabel("Applied")
                }
                Text(current.matchedText)
                    .font(.callout)
                    .lineLimit(1)
                    // The matched text is document content.
                    .privacySensitive()
                Spacer()
                Text("Page \(current.pageIndex + 1)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, ResectaTokens.Spacing.md)
            .padding(.vertical, ResectaTokens.Spacing.xxs)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: ResectaTokens.Spacing.sm) {
            if searchState.searchModeType == .piiScan {
                // Scan interface leading controls (D-63/UT-04): the ↻
                // re-run — relocated here from the retired
                // category-chips row, and hidden again whenever the
                // DEBUG reveal restores that row so the surface never
                // renders two run controls — and the saved-searches
                // bookmark, relocated from the retired scope row
                // (this home is reachable at every detent; the scope
                // row never was at compact). Entry auto-run still
                // starts scans (the one-tap contract); the row keeps
                // its cancel-while-searching and result-navigation
                // jobs at the trailing edge, giving Scan the same
                // leading-controls … trailing-nav read as Search.
                if !SearchState.scanCategoryStripEnabled {
                    scanRescanButton
                }
                savedSearchesBookmark
                Spacer(minLength: 0)
            } else if searchState.searchModeType == .multiTerm {
                TextField("Add term…", text: $searchState.queryText)
                    .textFieldStyle(.roundedBorder)
                    // The typed term may itself be PII
                    // (a user searching their own SSN).
                    .privacySensitive()
                    // Search input is verbatim: autocapitalization would
                    // rewrite case-sensitive terms and autocorrect can
                    // silently replace the typed term before it runs.
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
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
                            // Return on an empty field with terms staged
                            // re-runs the current set — the affordance
                            // the not-run empty state names.
                            if !searchState.searchTerms.isEmpty {
                                triggerSearch()
                            }
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
                    // Verbatim input: autocapitalization breaks
                    // case-sensitive queries and mangles regex patterns;
                    // autocorrect can silently rewrite the query.
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isSearchFieldFocused)
                    .accessibilityLabel("Search text")
                    // Return runs the current query — the explicit-run
                    // affordance for carried queries the mode switch
                    // deliberately does not auto-run (UXF-16) and for
                    // short queries below the debounce floor.
                    .onSubmit {
                        // BH-B-06 — trimmed gate (mirrors multi-term's
                        // validator): a whitespace-only Return must not
                        // run an invisible query.
                        if !searchState.queryText
                            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            triggerSearch()
                        }
                    }
                    .onChange(of: searchState.queryText) { _, newValue in
                        if suppressNextQueryDebounce {
                            // Recall chips trigger their own run; the
                            // flag is one-shot.
                            suppressNextQueryDebounce = false
                        } else {
                            debounceSearch(query: newValue)
                        }
                        scheduleLivePreviewIfApplicable()
                    }
            }

            // Saved-searches entry point for the Search interface —
            // by the field so it stays reachable at the compact
            // detent. The Scan interface renders the SAME
            // `savedSearchesBookmark` from its leading branch above
            // (D-63/UT-04) — one shared component, two per-mode
            // render sites, so exactly one bookmark shows per mode.
            if searchState.searchModeType != .piiScan {
                savedSearchesBookmark
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

    /// Bookmark button presenting the saved-searches list through the
    /// single modal slot. Parked while staged detections await review:
    /// a recall re-triggers a run, and a run must not race the pending
    /// review for the Scan surface. Resolve the review (Apply /
    /// Dismiss) first. Since D-63/UT-04 this is the one live bookmark
    /// for BOTH interfaces (Scan renders it from the search bar's
    /// leading branch; the scope-row sibling is dormant).
    private var savedSearchesBookmark: some View {
        Button {
            activeModal = .savedSearches
        } label: {
            Image(systemName: "bookmark")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(redactionState.pendingTriage != nil)
        .accessibilityLabel("Saved Searches")
    }

    /// Compact re-run control for the Scan interface bar — the
    /// relocated home of the retired chips-row ↻ (D-63/UT-04).
    /// Inherits the run control's stable accessibility label
    /// ("Scan document for PII") so existing UI-test queries and
    /// VoiceOver habits keep resolving to the surface's one run
    /// control; the render site above gates on
    /// `!scanCategoryStripEnabled` so the DEBUG reveal — which
    /// restores the chips row and its in-row ↻ — never co-renders a
    /// second one. An empty chip selection never disables the run
    /// (it means scan everything via `effectiveScanCategories`).
    private var scanRescanButton: some View {
        Button {
            triggerSearch()
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(searchState.isSearching)
        .accessibilityLabel("Scan document for PII")
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

    /// The ONE result-navigation seam (SA-3 rider d — the former
    /// section-side duplicate is deleted; its J/K keyboard buttons
    /// call back through `onNavigateToCurrentResult`).
    private func navigateToCurrentResult() {
        guard let result = searchState.currentResult else { return }
        documentState.currentPageIndex = result.pageIndex
        // SA-3 rider (D-70): rect-level half — when the canvas is
        // zoomed past fit, the page write alone can leave the match
        // off-screen; the canvas consumes this with the engine's
        // canonical rect conversion.
        documentState.requestCanvasScroll(
            toPageIndex: result.pageIndex,
            normalizedRect: result.normalizedRect
        )
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

    // MARK: - Dismiss (conditional dismiss)

    /// Dismiss-confirmation copy — the single source of truth for both
    /// the production `.confirmationDialog` and the copy-pin banned-word
    /// sweep (`SearchSheetDismissRuleTests`), so a copy rename can't
    /// drift past the sweep. Covers both result origins; the message
    /// names the concrete loss — selected matches that will not be
    /// applied — rather than a generic "not saved".
    static let dismissTitle = "Discard selections?"
    static let dismissMessage = "Selected matches will not be applied to the document."

    /// Shared dismiss path for the direct (untouched) and confirmed
    /// (touched) routes. Closes BOTH sheet arms: a live selection is
    /// deselected in-place; a pending review is discarded (the retired
    /// triage sheet's Dismiss semantics — the summary banner's Review
    /// re-stages the findings, and re-running detection rebuilds them).
    /// `afterConfirmation` suppresses the loss-naming toasts — the
    /// dialog already named the drop, and dialog + toast on one dismiss
    /// would double-message.
    func performDismiss(afterConfirmation: Bool) {
        if searchState.selectedCount > 0 {
            let snapshot = Self.currentSelectionSnapshot(in: searchState)
            Self.clearSelection(in: searchState, snapshot: snapshot)
        } else if redactionState.pendingTriage == nil,
                  !afterConfirmation,
                  let message = Self.dismissClearedMessage(
                      unappliedCount: Self.unappliedMatchCount(in: searchState),
                      interface: searchState.searchModeType.interface
                  ) {
            // UXF-27: a 0-selected dismissal names what the close drops
            // when unapplied matches exist so the loss isn't silent.
            // The toast manager outlives the sheet.
            toastManager.enqueue(message, severity: .info)
        }
        if redactionState.pendingTriage != nil {
            if !afterConfirmation {
                // Carried from the retired review surface — the info
                // trace that staged findings were dropped.
                toastManager.enqueue("Detection results dismissed", severity: .info)
            }
            redactionState.dismissTriage()
        }
        redactionState.activeSearch = nil
    }

    // MARK: - the unified degrade rule Degrade banner

    /// Unified degrade-banner rule: Scan always surfaces a degraded
    /// detection corpus (its runs consult it); Search only when a
    /// scan-class capability degrades the CURRENT action — and no
    /// Search-side action in this tree uses one (literal matching plus
    /// OCR modality access), so the Search side renders none until a
    /// recall-aid lands there. Pure predicate, pinned by
    /// `DegradedBannerTests`.
    static func degradeBannerShouldShow(
        interface: SearchInterface,
        degraded: Bool
    ) -> Bool {
        degraded && interface == .scan
    }

    /// Persistent top banner while `redactionState.autoDetectionDegraded`
    /// is true (one or more gazetteer / context-keywords resources failed
    /// to load this session). Mechanism-description copy per ARCH §1.3 /
    /// I6 — describes what happened and what remains available, no
    /// outcome promises. The copy pass reworded the inherited banner
    /// line: the state is a degrade (runs proceed with the resources
    /// that loaded), and the retired flow name is gone — the wording
    /// now matches the toast that announces the same state.
    @ViewBuilder
    var degradedDetectionBanner: some View {
        HStack(alignment: .top, spacing: ResectaTokens.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(DetectionDegradeCopy.banner(
                failedGazetteers: redactionState.autoDetectionDegradeFailures))
                .font(.subheadline)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ResectaTokens.Spacing.md)
        .padding(.vertical, ResectaTokens.Spacing.sm)
        .background(ResectaTokens.SemanticColor.warningTint.opacity(0.12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("degradedDetectionBanner")
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Apply (review origin)

    /// Toolbar Apply for the review origin: the staged detections
    /// promote through the one `applyFindings` path, which writes their
    /// metadata + audit records, owns the undo registration, and
    /// re-checks the mutation guard inside the action (passing
    /// `documentState` arms the path-internal re-check — the action
    /// guard here is the second site of the two-site discipline, and
    /// the path is the third, race-proof one).
    func applyReviewFindings() {
        // Refuse mutations while the pipeline owns
        // `redactionState.regions` — re-checked in the action against a
        // pipeline that started after the last render.
        guard documentState.canMutateRegions else { return }
        Task { @MainActor in
            guard let outcome = await redactionState.applyFindings(
                .stagedDetections,
                undoManager: undoManager,
                documentState: documentState
            ) else { return }
            // UXF-11 — commit feedback through the shared copy builder so
            // the count stays in lockstep with every other apply surface.
            // The sheet stays up (the review resolves in place); the
            // sheet-local toast host renders it. The conditional-dismiss
            // tracker reset is owned by the apply path.
            if let message = CommitFeedback.markedMessage(applied: outcome.applied) {
                toastManager.enqueue(message, severity: .success)
            }
        }
    }

    /// Footer Select All over the VISIBLE (kind-filtered) review
    /// detections; hidden detections retain their selection state,
    /// mirroring the search footer's filtered-only semantics.
    private var allReviewVisibleSelected: Bool {
        let visible = reviewVisibleIDs
        guard !visible.isEmpty else { return false }
        return visible.allSatisfy { redactionState.triageSelections[$0] ?? false }
    }

    private func toggleReviewSelectAll() {
        let visible = reviewVisibleIDs
        guard !visible.isEmpty else { return }
        let target = !allReviewVisibleSelected
        for id in visible {
            redactionState.triageSelections[id] = target
        }
        // Conditional dismiss: bulk select/deselect is user selection work.
        searchState.userModifiedSelections = true
    }

    // `debounceSearch(query:)`, `triggerSearch()`, the two apply
    // handlers (toolbar + keyboard shortcut), `applyShortcutEnabled`,
    // and the saved-search recall live in
    // `Search/SearchAndRedactSheet+Trigger.swift` (M-6 hub-cap
    // decomposition; run-orchestration family stays together).

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
            // Empty chip selection = scan everything (the one-tap
            // contract needs no configuration) — the effective set
            // maps no-selection to the full category set.
            return .piiScan(categories: searchState.effectiveScanCategories, options: options)
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
