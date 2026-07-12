import SwiftUI
import RedactionEngine

// GAP §4.2: Detection triage sheet — review and accept/reject detections
// before they become redaction regions.

struct DetectionTriageSheet: View {
    // ACCESSIBILITY.md §9.2 — VoiceOver strings exposed as `static`
    // constants so the contract can be pinned by unit tests without
    // rendering the sheet. Mirrors the `InlineWarningBanner.lineLimit(for:)`
    // pattern used for the AX5 line-cap predicate.
    static let menuAccessibilityLabel = "Triage batch actions"
    static let sliderAccessibilityLabel = "Minimum detection confidence"
    static func sliderAccessibilityValue(forConfidence confidence: Double) -> String {
        "\(Int(confidence * 100)) percent"
    }

    // GATE-4 — title for the menu action that opts into the
    // pre-decouple chip behavior (select all matching, deselect
    // everything else). Exposed as a `static` so the menu wiring
    // contract can be pinned by unit tests without rendering.
    static let selectAllInVisibleFilterLabel = "Select All in Visible Filter"

    // Dismiss-confirmation copy as the single source
    // of truth. Both the production `.confirmationDialog` below AND the copy-pin
    // banned-word sweep (DetectionTriageSheetDismissConfirmationTests) reference
    // these, so a copy rename can no longer drift silently past the sweep.
    static let dismissTitle = "Dismiss detection results?"
    static let dismissMessage = "Selections will not be saved."

    /// UXF-13 (labels only) — summary-bar selection line. When every
    /// detected item is selected (the arrival default: triage opens
    /// all-preselected), the label states that default explicitly and
    /// prompts review; otherwise it reads as a plain "M of N" count.
    /// Pure function pinned by `DetectionTriageSelectionLabelTests`.
    static func selectionSummaryLabel(accepted: Int, total: Int) -> String {
        if total > 0 && accepted == total {
            return "All \(total) preselected — review before Apply"
        }
        return "\(accepted) of \(total) selected for redaction"
    }

    /// GATE-4 — pure helper that re-applies the rewrite logic
    /// formerly run from the `.onChange(of: filterKind)` handler:
    /// for every detection, set its selection to `true` iff its
    /// `kind` matches `filter`. When `filter` is nil ("All" chip),
    /// every detection is selected. Returns the next selection
    /// map; callers assign it to `redactionState.triageSelections`.
    ///
    /// Exposed as a `static` pure function so the menu-action
    /// contract is testable without rendering the sheet.
    static func triageSelections(
        rewritingFor filter: DetectionResult.Kind?,
        in detections: [(page: Int, detection: DetectionResult)]
    ) -> [UUID: Bool] {
        var next: [UUID: Bool] = [:]
        for item in detections {
            if let filter {
                next[item.detection.id] = (item.detection.kind == filter)
            } else {
                next[item.detection.id] = true
            }
        }
        return next
    }

    @Environment(RedactionState.self) private var redactionState
    @Environment(DocumentState.self) private var documentState
    @Environment(ToastQueueManager.self) private var toastManager  // F2-4
    @Environment(SettingsState.self) private var settingsState
    @Environment(\.undoManager) private var undoManager
    @Environment(\.dismiss) private var dismiss
    /// S6 / C10 — SEC-3 extension: read ONCE at sheet level, passed to
    /// `ShieldedSheetContent` as a `let` (37b56c9 let-injection precedent).
    @Environment(ScreenCaptureMonitor.self) private var captureMonitor
    @State private var filterKind: DetectionResult.Kind? = nil
    @State private var sortOrder: SortOrder = .byPage
    @State private var minimumConfidence: Double = 0.0
    // §4.6: Haptic triggers — state toggles fire sensory feedback
    @State private var applyTrigger = false
    @State private var dismissTrigger = false
    // WP5b: Cached kind counts — prevents recomputation on every body evaluation
    @State private var cachedKindsWithCounts: [(kind: DetectionResult.Kind, count: Int)] = []
    // Perf: Cached filtered+sorted detections — avoids O(n log n) re-sort per body evaluation
    @State private var cachedFilteredDetections: [(page: Int, detection: DetectionResult)] = []
    // W9 — present "Why this match?" popover for the tapped detection.
    @State private var reverseRationaleRequest: ReverseRationaleRequest?
    @State private var pendingRecomputeTask: Task<Void, Never>?
    // GATE-5 (Pkg I): destructive-action confirmation symmetry. Track
    // whether the user has toggled any individual selection (row tap,
    // filter chip, or bulk Select/Deselect). The Dismiss confirmation
    // dialog is conditional — it only fires when this flag is true so
    // a no-op Dismiss tap on an untouched sheet doesn't add friction.
    @State private var hasModifiedSelections = false
    @State private var showDismissConfirmation = false

    /// View modes for the triage list. The first three drive how
    /// individual detection rows are ordered; the fourth — DRAW-4 —
    /// replaces the per-detection list with a per-`CrossPageEntityGroup`
    /// list. The view-mode switch is orthogonal to the type filter chips
    /// and the confidence slider, which continue to apply in `.grouped`
    /// mode (groups whose category is filtered out, or whose members
    /// all fall below the confidence floor, are hidden).
    enum SortOrder: String, CaseIterable {
        case byPage = "By Page"
        case byType = "By Type"
        case byConfidence = "By Confidence"
        case grouped = "Grouped"
    }

    private var allDetections: [(page: Int, detection: DetectionResult)] {
        guard let pending = redactionState.pendingTriage else { return [] }
        var flat: [(Int, DetectionResult)] = []
        for (page, results) in pending.sorted(by: { $0.key < $1.key }) {
            for result in results {
                flat.append((page, result))
            }
        }
        return flat
    }

    private func recomputeFilteredDetections() {
        var result = allDetections
        if let filter = filterKind {
            result = result.filter { $0.detection.kind == filter }
        }
        if minimumConfidence > 0 {
            result = result.filter { $0.detection.confidence >= minimumConfidence }
        }
        switch sortOrder {
        case .byPage: break // Already sorted by page
        case .byType:
            result.sort { $0.detection.kind.fullName < $1.detection.kind.fullName }
        case .byConfidence:
            result.sort { $0.detection.confidence > $1.detection.confidence }
        case .grouped:
            // .grouped mode renders `cachedFilteredGroups` instead of this
            // flat list; the order chosen here is the byPage fall-through
            // so toggling back to a flat mode lands on a sensible default.
            break
        }
        cachedFilteredDetections = result
    }

    /// DRAW-4 — cache for the "Grouped" view-mode rows. Filtered by the
    /// active type-chip / confidence slider so the user sees the same
    /// subset across view modes. Populated in `recomputeFilteredGroups`
    /// on appear and on input change.
    @State private var cachedFilteredGroups: [CrossPageEntityGroup] = []

    private func recomputeFilteredGroups() {
        guard let pending = redactionState.pendingTriage else {
            cachedFilteredGroups = []
            return
        }
        // Build a (detectionID → confidence) lookup once so the per-group
        // confidence floor filter is O(group members) rather than re-scan.
        var lookup: [UUID: DetectionResult] = [:]
        for (_, results) in pending {
            for result in results { lookup[result.id] = result }
        }

        let groups = redactionState.crossPageEntityGroups.filter { group in
            // UXF-29 — a group whose members are all gone from
            // `pendingTriage` (already promoted by "Apply Group", or
            // otherwise resolved) has nothing left to apply; keeping its
            // row invited a second tap that used to double-create.
            guard group.detectionIDs.contains(where: { lookup[$0] != nil }) else {
                return false
            }
            if let filter = filterKind {
                // .grouped mode honors the type filter — a chip narrows to
                // groups in that category only.
                guard case .pii(let kind) = filter, kind == group.category else {
                    return false
                }
            }
            if minimumConfidence > 0 {
                // Hide a group iff all its members fall below the slider's
                // floor. Group apply atomically promotes every member, so
                // a single high-confidence member is sufficient to keep
                // the group surfaceable.
                let surviving = group.detectionIDs
                    .compactMap { lookup[$0]?.confidence }
                    .contains { $0 >= minimumConfidence }
                guard surviving else { return false }
            }
            return true
        }
        cachedFilteredGroups = groups
    }

    private func recomputeAll() {
        recomputeFilteredDetections()
        recomputeFilteredGroups()
    }

    private var acceptedCount: Int {
        redactionState.triageSelections.values.filter { $0 }.count
    }

    private var totalCount: Int {
        allDetections.count
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // SEC-7 — persistent top banner whenever the auto-detection
                // corpus failed to load this session. Mechanism-description
                // copy (I6): describes what happened and what remains
                // available, no outcome promises.
                if redactionState.autoDetectionDegraded {
                    degradedDetectionBanner
                }

                // ST-83 — top banner whenever one or more pages exceeded
                // the OCR pixel caps during this detection run, so their
                // image content was never text-scanned. Mechanism-
                // description copy, same shape as the SEC-7 banner above.
                if !redactionState.ocrPixelCapSkippedPages.isEmpty {
                    ocrSkipBanner
                }

                // Summary bar
                triageSummaryBar

                // Phase 3 G5: "Why this classification?" panel (in-memory only).
                classificationDiagnosticPanel

                // Filter chips
                filterChipBar

                // Detection list — flat-row in byPage/byType/byConfidence;
                // group-row in .grouped (DRAW-4) so the user reasons about
                // the cross-page entity instead of every instance.
                if sortOrder == .grouped {
                    groupedDetectionList
                } else {
                    List {
                        ForEach(cachedFilteredDetections, id: \.detection.id) { item in
                            DetectionTriageRow(
                                page: item.page,
                                detection: item.detection,
                                isAccepted: Binding(
                                    get: {
                                        redactionState.triageSelections[item.detection.id] ?? true
                                    },
                                    set: {
                                        // GATE-5 (Pkg I): row-level toggle flips
                                        // the modified-selections flag so the
                                        // conditional Dismiss confirmation
                                        // surfaces from here forward.
                                        redactionState.triageSelections[item.detection.id] = $0
                                        hasModifiedSelections = true
                                    }
                                ),
                                onRequestWhy: { detection in
                                    presentReverseRationale(for: detection, page: item.page)
                                }
                            )
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Review Detections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Dismiss") {
                        // GATE-5 (Pkg I): conditional confirmation — only
                        // route through the dialog when the user has
                        // toggled at least one selection. Untouched-sheet
                        // dismiss runs directly so the no-op case adds no
                        // friction.
                        if hasModifiedSelections {
                            showDismissConfirmation = true
                        } else {
                            performDismiss()
                        }
                    }
                    .accessibilityIdentifier("detectionTriageDismissButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply \(acceptedCount)") {
                        let created = redactionState.applyTriagedResults(
                            undoManager: undoManager)
                        applyTrigger.toggle()
                        // UXF-11 — commit feedback parity with Search &
                        // Redact's "Marked N for redaction" toast, using
                        // the count of regions actually created. Deferred
                        // one runloop turn (deferral pattern — see
                        // `performDismiss`): the apply clears
                        // `pendingTriage`, which tears down this sheet in
                        // the same transaction, so the enqueue must not
                        // run inside it. Capture the manager while the
                        // @Environment is live.
                        if let message = CommitFeedback.markedMessage(applied: created) {
                            let manager = toastManager
                            Task { @MainActor in
                                manager.enqueue(message, severity: .success)
                            }
                        }
                    }
                    .disabled(acceptedCount == 0)
                    .fontWeight(.semibold)
                }
            }
            // GATE-5 (Pkg I): conditional Dismiss confirmation. Copy is
            // mechanism-description (ARCH §1.3) — names what the action
            // does without an outcome promise.
            .confirmationDialog(
                Self.dismissTitle,
                isPresented: $showDismissConfirmation,
                titleVisibility: .visible
            ) {
                Button("Dismiss", role: .destructive) {
                    performDismiss()
                }
                .accessibilityIdentifier("detectionTriageDismissConfirm")
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(Self.dismissMessage)
            }
            .sheet(item: $reverseRationaleRequest) { request in
                ReverseRationalePopover(request: request)
                    .environment(settingsState)
            }
            // §4.6: Haptic — sheet presented
            .onAppear {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            // §4.6: Haptic — apply triaged results (matches detectionComplete A3.4)
            .sensoryFeedback(.success, trigger: applyTrigger)
            // §4.6: Haptic — dismiss triage (soft dismissal)
            .sensoryFeedback(.impact(weight: .light), trigger: dismissTrigger)
            // WP5b: Populate caches once on appear
            .task {
                cachedKindsWithCounts = computeKindsWithCounts()
                recomputeAll()
            }
            // Recompute filtered list when sort/filter inputs change
            .onChange(of: sortOrder) { _, _ in
                recomputeAll()
            }
            .onChange(of: minimumConfidence) { _, _ in
                pendingRecomputeTask?.cancel()
                pendingRecomputeTask = Task {
                    try? await Task.sleep(for: .milliseconds(80))
                    guard !Task.isCancelled else { return }
                    recomputeAll()
                }
            }
            // GATE-4 — chip-filter decouple. Tapping a filter chip
            // narrows the visible list only. The auto-select rewrite
            // moved to the "Select All in Visible Filter" action on
            // the ellipsis Menu so the user's manual unchecks survive
            // a filter change. See `triageSelections(rewritingFor:in:)`.
            .onChange(of: filterKind) { _, _ in
                recomputeAll()
            }
        }
        // S6 / C10 — SEC-3 extension: this sheet presents modally ABOVE the
        // editor's shield swap; the row-level `.privacySensitive()` on
        // canonical text is complementary, not sufficient, against an
        // active capture. Outermost modifier swaps the whole sheet.
        .shieldedSheetContent(monitor: captureMonitor)
    }

    // MARK: - Dismiss helper

    /// GATE-5 (Pkg I): shared post-confirmation dismiss path. Extracted
    /// from the toolbar button so the direct (no-modifications) and the
    /// confirmed (modifications-present) paths share one implementation.
    private func performDismiss() {
        // Deferral pattern: defer the enqueue past
        // the current SwiftUI transaction. `enqueue` → `show()` runs
        // `withAnimation { activeToasts.append }` + haptics + an
        // `UIAccessibility.post` synchronously; `dismiss()` then tears down the
        // sheet, re-evaluating the ancestor `DocumentEditorView` whose
        // `@Environment(ToastQueueManager.self)` read trips the Observation
        // assertion mid-update (the same EXC_BREAKPOINT class as the ToastView
        // fix, PR #148). Capture `toastManager` while the @Environment is still
        // live — a post-dismiss lookup from the Task body is invalid. The haptic
        // (`dismissTrigger.toggle()`) and `dismiss()` stay synchronous.
        let manager = toastManager
        Task { @MainActor in
            manager.enqueue("Detection results dismissed", severity: .info)
        }
        dismissTrigger.toggle()
        dismiss()
    }

    // MARK: - SEC-7 Degraded-mode banner

    /// Persistent top banner shown while `redactionState.autoDetectionDegraded`
    /// is true (one or more gazetteer / context-keywords resources failed to
    /// load for this session). Mechanism-description per ARCH §1.3 / I6 —
    /// no outcome promise language.
    @ViewBuilder
    private var degradedDetectionBanner: some View {
        HStack(alignment: .top, spacing: ResectaTokens.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("Auto-detection was disabled for this session because the detection corpus failed to load. Manual redaction tools remain available.")
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

    // MARK: - ST-83 OCR-Skip Banner

    /// Surfaces the pages whose raster exceeded the OCR pixel caps this
    /// run, so Vision OCR never ran there. Copy names only page numbers —
    /// never document content. Headline is a pure function pinned by
    /// `DetectionTriageOCRSkipBannerTests`.
    private var ocrSkipBanner: some View {
        let headline = Self.ocrSkipBannerHeadline(
            pages: redactionState.ocrPixelCapSkippedPages.sorted()
        )
        return HStack(alignment: .top, spacing: ResectaTokens.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(headline)
                .font(.subheadline)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ResectaTokens.Spacing.md)
        .padding(.vertical, ResectaTokens.Spacing.sm)
        .background(ResectaTokens.SemanticColor.warningTint.opacity(0.12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ocrSkipBanner")
        .accessibilityAddTraits(.isHeader)
    }

    /// ST-83 banner copy. Pages are 0-indexed internally; rendered
    /// 1-based. Mechanism description only — states what did not run and
    /// what the user can still do, no outcome promises.
    static func ocrSkipBannerHeadline(pages: [Int]) -> String {
        let oneBased = pages.map { $0 + 1 }
        let list = SearchResultsSection.formatPageList(oneBased)
        let pageNoun = oneBased.count == 1 ? "Page \(list) is" : "Pages \(list) are"
        return "\(pageNoun) too large to scan for text, so image content there was not checked. Review \(oneBased.count == 1 ? "that page" : "those pages") manually."
    }

    // MARK: - Summary Bar

    @ViewBuilder
    private var triageSummaryBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xxs) {
                // UX-singular-plural-grammar (Pkg N): "1 item" vs
                // "N items" — same one-character-conditional pattern
                // used at the SearchAndRedactSheet confirmation dialog.
                Text("\(totalCount) item\(totalCount == 1 ? "" : "s") detected")
                    .font(.headline)
                // Pkg N: `acceptedCount` is a count of items selected for
                // redaction; the "selected" verbal noun governs both
                // singular and plural without inflection.
                // UXF-13 (labels only): the all-preselected arrival
                // default is stated explicitly instead of implied.
                Text(Self.selectionSummaryLabel(accepted: acceptedCount, total: totalCount))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            // Batch actions — respect active filter
            Menu {
                Button(selectAllLabel) {
                    for id in targetIDs {
                        redactionState.triageSelections[id] = true
                    }
                    // GATE-5 (Pkg I): bulk select counts as a user
                    // selection change.
                    hasModifiedSelections = true
                }
                Button(deselectAllLabel) {
                    for id in targetIDs {
                        redactionState.triageSelections[id] = false
                    }
                    // GATE-5 (Pkg I): bulk deselect counts as a user
                    // selection change.
                    hasModifiedSelections = true
                }
                // GATE-4 — opt-in version of the pre-decouple chip
                // behavior. Selects every detection that matches the
                // active filter AND deselects everything else. When no
                // chip is active, selects every detection.
                Button(Self.selectAllInVisibleFilterLabel) {
                    redactionState.triageSelections =
                        Self.triageSelections(
                            rewritingFor: filterKind,
                            in: allDetections
                        )
                    // GATE-5 (Pkg I): this rewrite is a user-driven
                    // selection change — Dismiss should confirm afterward.
                    hasModifiedSelections = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
            // ACCESSIBILITY.md §9.2 — the ellipsis glyph alone reads as
            // "more" in VoiceOver. Pin the menu's purpose so the user hears
            // "Triage batch actions" before drilling into the options.
            .accessibilityLabel(Self.menuAccessibilityLabel)
        }
        .padding(.horizontal, ResectaTokens.Spacing.md)
        .padding(.vertical, ResectaTokens.Spacing.sm)
        .background(.bar)
    }

    // MARK: - Filter Chip Bar

    @ViewBuilder
    private var filterChipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ResectaTokens.Spacing.sm) {
                // Sort picker
                Picker("Sort", selection: $sortOrder) {
                    ForEach(SortOrder.allCases, id: \.self) { order in
                        Text(order.rawValue)
                    }
                }
                .pickerStyle(.menu)

                Divider().frame(height: 20)
                    .accessibilityHidden(true)

                // Type filter chips — dynamically generated from detected types
                FilterChip(label: "All", count: allDetections.count, isSelected: filterKind == nil) {
                    filterKind = nil
                }
                ForEach(cachedKindsWithCounts, id: \.kind) { item in
                    FilterChip(
                        label: item.kind.badge,
                        count: item.count,
                        isSelected: filterKind == item.kind
                    ) {
                        filterKind = item.kind
                    }
                }

                Divider().frame(height: 20)
                    .accessibilityHidden(true)

                // Confidence threshold slider
                HStack(spacing: ResectaTokens.Spacing.xs) {
                    Text("Min \(Int(minimumConfidence * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                    Slider(value: $minimumConfidence, in: 0...0.95, step: 0.05)
                        .frame(minWidth: 80, maxWidth: 140)
                        // ACCESSIBILITY.md §9.2 — pin a name + spoken value
                        // so VoiceOver announces "Minimum detection confidence,
                        // X percent, adjustable" instead of an unnamed slider.
                        .accessibilityLabel(Self.sliderAccessibilityLabel)
                        .accessibilityValue(
                            Self.sliderAccessibilityValue(
                                forConfidence: minimumConfidence
                            )
                        )
                }
            }
            .padding(.horizontal, ResectaTokens.Spacing.md)
            .padding(.vertical, ResectaTokens.Spacing.xs)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Detection filters")
    }

    // MARK: - Batch Action Helpers

    private var isFiltered: Bool {
        filterKind != nil || minimumConfidence > 0
    }

    private var targetIDs: [UUID] {
        if isFiltered {
            return cachedFilteredDetections.map(\.detection.id)
        }
        return Array(redactionState.triageSelections.keys)
    }

    private var selectAllLabel: String {
        if let kind = filterKind {
            return "Select All \(kind.badge)"
        }
        return isFiltered ? "Select Visible" : "Select All"
    }

    private var deselectAllLabel: String {
        if let kind = filterKind {
            return "Deselect All \(kind.badge)"
        }
        return isFiltered ? "Deselect Visible" : "Deselect All"
    }

    // MARK: - Phase 3 G5: Classification diagnostic

    /// Representative diagnostic chosen by majority doctype across all pages.
    /// Returns nil when no pages carry a diagnostic (e.g., classifier asset
    /// missing). In-memory only — never logged, never persisted.
    private var representativeDiagnostic: ClassificationDiagnostic? {
        let diagnostics = redactionState.pageDiagnostics
        guard !diagnostics.isEmpty else { return nil }
        // Pick the modal primary across pages.
        var primaryCounts: [DoctypeClass: Int] = [:]
        for diag in diagnostics.values {
            primaryCounts[diag.primary, default: 0] += 1
        }
        let modalPrimary = primaryCounts.max(by: { $0.value < $1.value })?.key
        // Among pages whose primary matches the mode, return the earliest one.
        let matching = diagnostics.sorted(by: { $0.key < $1.key })
            .first(where: { $0.value.primary == modalPrimary })
        return matching?.value ?? diagnostics.values.first
    }

    @ViewBuilder
    private var classificationDiagnosticPanel: some View {
        if let diag = representativeDiagnostic {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xs) {
                    HStack(spacing: ResectaTokens.Spacing.sm) {
                        Text("Primary:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(doctypeDisplayName(diag.primary))
                            .font(.caption.weight(.semibold))
                        if let prob = diag.softmaxSnapshot[diag.primary] {
                            Text("(\(Int(prob * 100))%)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let runnerUp = diag.runnerUp {
                        HStack(spacing: ResectaTokens.Spacing.sm) {
                            Text("Runner-up:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(doctypeDisplayName(runnerUp))
                                .font(.caption)
                            if let prob = diag.softmaxSnapshot[runnerUp] {
                                Text("(\(Int(prob * 100))%)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !diag.topKeywords.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Top keywords")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: ResectaTokens.Spacing.xs) {
                                ForEach(Array(diag.topKeywords.prefix(5)), id: \.keyword) { kw in
                                    Text(kw.keyword)
                                        .font(.caption.monospaced())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.quaternary, in: Capsule())
                                }
                            }
                        }
                    }
                }
                .padding(.top, ResectaTokens.Spacing.xxs)
            } label: {
                HStack(spacing: ResectaTokens.Spacing.xs) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                    Text("Why this classification?")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, ResectaTokens.Spacing.md)
            .padding(.vertical, ResectaTokens.Spacing.xs)
            .background(.bar)
        } else {
            EmptyView()
        }
    }

    private func doctypeDisplayName(_ c: DoctypeClass) -> String {
        switch c {
        case .court: return "Court"
        case .medical: return "Medical"
        case .financial: return "Financial"
        case .foia: return "Government records"
        case .generic: return "General"
        }
    }

    // MARK: - W9 Reverse Rationale

    /// W9 — derive the context buffer from the page's OCR/text layer and
    /// present the popover. Context window is bounded to ±250 chars around
    /// the detection's normalized rect midpoint (via page text search);
    /// the snippet itself is `detection.matchedText`.
    private func presentReverseRationale(for detection: DetectionResult, page: Int) {
        guard let snippet = detection.matchedText else { return }
        let doctype = representativeDiagnostic?.primary
        let context = contextBuffer(for: snippet, page: page)
        reverseRationaleRequest = ReverseRationaleRequest(
            snippet: snippet,
            fullContext: context,
            doctype: doctype
        )
    }

    /// Extract a ≤500-char buffer around the first occurrence of `snippet` on
    /// `page`'s text layer. Falls back to the snippet itself if the page
    /// text is unavailable.
    private func contextBuffer(for snippet: String, page: Int) -> String {
        guard let doc = documentState.sourceDocument,
              page >= 0, page < doc.pageCount,
              let pdfPage = doc.page(at: page),
              let text = pdfPage.string else {
            return snippet
        }
        let ns = text as NSString
        let loc = ns.range(of: snippet).location
        guard loc != NSNotFound else {
            // Snippet not in page text — use detector's matchedText as the
            // whole context so reverseRationale can still score it.
            return snippet
        }
        let radius = 250
        let start = max(0, loc - radius)
        let end = min(ns.length, loc + (snippet as NSString).length + radius)
        return ns.substring(with: NSRange(location: start, length: end - start))
    }

    // MARK: - Helpers

    /// Compute unique detection kinds with counts, sorted by display order.
    private func computeKindsWithCounts() -> [(kind: DetectionResult.Kind, count: Int)] {
        var counts: [DetectionResult.Kind: Int] = [:]
        for item in allDetections {
            counts[item.detection.kind, default: 0] += 1
        }
        return counts.sorted { $0.key.sortOrder < $1.key.sortOrder }
            .map { (kind: $0.key, count: $0.value) }
    }

    // MARK: - DRAW-4 Grouped view-mode list

    /// DRAW-4 — cross-page entity group list. Each row collapses every
    /// member detection of a single group into one tap-target so accept
    /// applies all members atomically through
    /// `RedactionState.applyEntityGroup(_:undoManager:)` — a single
    /// undo step. Detections not in any group remain reviewable via the
    /// non-grouped view modes (byPage / byType / byConfidence).
    @ViewBuilder
    private var groupedDetectionList: some View {
        if cachedFilteredGroups.isEmpty {
            VStack(spacing: ResectaTokens.Spacing.sm) {
                Image(systemName: "rectangle.stack")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No cross-page groups")
                    .font(.headline)
                Text("Switch view modes to review individual detections.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(ResectaTokens.Spacing.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(cachedFilteredGroups) { group in
                    CrossPageGroupRow(
                        group: group,
                        onAccept: {
                            let created = redactionState.applyEntityGroup(
                                group, undoManager: undoManager
                            )
                            applyTrigger.toggle()
                            // UXF-29 — the apply pruned its members from
                            // `pendingTriage`; refresh the caches so this
                            // group's row (and its flat-list rows) leave
                            // the screen instead of inviting a second,
                            // double-creating tap. The summary-bar counts
                            // update through the same recompute.
                            cachedKindsWithCounts = computeKindsWithCounts()
                            recomputeAll()
                            // UXF-11 — when the prune emptied the sheet,
                            // it closes (pendingTriage == nil) and the
                            // count toast is the surviving feedback; while
                            // the sheet stays open, the row removal + count
                            // change are the visible feedback and a toast
                            // would render invisibly behind the sheet.
                            if redactionState.pendingTriage == nil,
                               let message = CommitFeedback.markedMessage(applied: created) {
                                let manager = toastManager
                                Task { @MainActor in
                                    manager.enqueue(message, severity: .success)
                                }
                            }
                        }
                    )
                }
            }
            .listStyle(.plain)
            .accessibilityIdentifier("crossPageGroupList")
        }
    }

}

// MARK: - DRAW-4 CrossPageGroupRow

/// Single-row view for a `CrossPageEntityGroup`. Surfaces canonical text,
/// member count, and pages; "Apply Group" promotes every member in one
/// atomic undo step via `RedactionState.applyEntityGroup`.
struct CrossPageGroupRow: View {
    let group: CrossPageEntityGroup
    let onAccept: () -> Void

    var body: some View {
        HStack(spacing: ResectaTokens.Spacing.sm) {
            // Group badge — the category for this group
            Text(DetectionResult.Kind.pii(group.category).badge)
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, ResectaTokens.Spacing.xs)
                .padding(.vertical, ResectaTokens.Spacing.xxs)
                .background(
                    DetectionResult.Kind.pii(group.category).badgeColor,
                    in: RoundedRectangle(
                        cornerRadius: ResectaTokens.CornerRadius.small,
                        style: .continuous
                    )
                )

            VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xxs) {
                Text(group.canonicalText)
                    .font(.subheadline.monospaced())
                    .lineLimit(1)
                    .privacySensitive()
                Text(memberSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Apply Group", action: onAccept)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityHint("Redacts every instance of this group in one undo step")
        }
        .padding(.vertical, ResectaTokens.Spacing.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    /// "3 instances across pages 1, 3, 5". Page indices are 0-based
    /// internally; surface them 1-based to align with the page number
    /// chrome elsewhere in the app.
    private var memberSummary: String {
        let count = group.detectionIDs.count
        let pageList = group.pages.map { "\($0 + 1)" }.joined(separator: ", ")
        return "\(count) instances across pages \(pageList)"
    }

    private var accessibilityDescription: String {
        "\(group.canonicalText). \(memberSummary)."
    }
}
