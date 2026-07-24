import SwiftUI
import RedactionEngine

// Staged-detections review inside the Scan interface — the unified
// review surface's detection-origin half. Presents whenever
// `redactionState.pendingTriage` is non-nil (pipeline staging, the
// summary banner's Review re-entry, or the DEBUG `--seedTriage` hook):
// staged detections render through the shared `FindingRow` family,
// arrive with nothing selected (review-first arrival), and apply
// through the one `applyFindings` path from the sheet's toolbar. This
// replaces the standalone "Review Detections" triage sheet — one
// review surface for both result origins.
//
// Carried from the retired sheet: the pipeline-side OCR-skip banner
// (ST-83), the classification-diagnostic disclosure (G5), the
// cross-page Grouped view with atomic group apply (DRAW-4/UXF-29), and
// the per-row detector-evaluation entry (W9). Retired with it: the
// batch-actions menu (superseded by the footer Select All and the
// Select-Where predicates) and the min-confidence slider (the same
// review-side confidence idiom the per-run Confidence slider's
// retirement replaced with confidence predicates).

struct ScanReviewSection: View {
    @Bindable var searchState: SearchState
    /// Kind filter, hoisted to the sheet so the footer's Select All
    /// can target the visible (kind-filtered) findings.
    @Binding var filterKind: DetectionResult.Kind?
    @Environment(RedactionState.self) private var redactionState
    @Environment(DocumentState.self) private var documentState
    @Environment(ToastQueueManager.self) private var toastManager
    @Environment(\.undoManager) private var undoManager
    /// Route a row's detector-evaluation request up to the sheet's
    /// single `activeModal` slot (the same `ReverseRationalePopover`
    /// search rows open from their context menu).
    let onRequestWhy: (ReverseRationaleRequest) -> Void
    /// SA-3 rider (B-3): row-body tap navigates the canvas to the
    /// finding's page — the search rows' shipped idiom (page write +
    /// compact drop live on the hub, which owns the detent).
    let onNavigateToPage: (Int) -> Void

    @State private var viewMode: ReviewViewMode = .byPage
    // WP5b pattern carried: cached kind counts + filtered list so the
    // sort/filter work doesn't rerun per body evaluation.
    @State private var cachedKindsWithCounts: [(kind: DetectionResult.Kind, count: Int)] = []
    @State private var cachedFilteredFindings: [(page: Int, detection: DetectionResult)] = []
    @State private var cachedFilteredGroups: [CrossPageEntityGroup] = []

    /// View modes for the review list. The first three order individual
    /// detection rows; `.grouped` (DRAW-4) replaces the per-detection list
    /// with a per-`CrossPageEntityGroup` list. Orthogonal to the kind
    /// filter chips, which continue to apply in `.grouped` mode.
    enum ReviewViewMode: String, CaseIterable {
        case byPage = "By Page"
        case byType = "By Type"
        case byConfidence = "By Confidence"
        case grouped = "Grouped"
    }

    private var allFindings: [(page: Int, detection: DetectionResult)] {
        Self.flattenedFindings(redactionState.pendingTriage)
    }

    var body: some View {
        // SA-2 (D-70): the List is the section's root and the fixed
        // chrome rides its top safe-area inset, so the List's UIKit
        // frame binds at the sheet top for cooperative scroll↔detent
        // arbitration (18- §10 — chrome HEIGHT above the list, not
        // chrome species, is what unbinds it). Both view modes get
        // the same treatment (the grouped branch roots a List
        // whenever groups exist; its empty placeholder has nothing to
        // scroll).
        Group {
            if viewMode == .grouped {
                groupedFindingList
                    .safeAreaInset(edge: .top, spacing: 0) {
                        reviewTopChrome
                    }
            } else {
                List {
                    ForEach(cachedFilteredFindings, id: \.detection.id) { item in
                        reviewRow(page: item.page, detection: item.detection)
                    }
                }
                .listStyle(.plain)
                .accessibilityIdentifier("scanReviewList")
                .safeAreaInset(edge: .top, spacing: 0) {
                    reviewTopChrome
                }
            }
        }
        .task {
            recomputeAll()
        }
        .onChange(of: viewMode) { _, _ in recomputeAll() }
        .onChange(of: filterKind) { _, _ in recomputeAll() }
        // Re-derive when the staged set changes shape — keyed on the
        // total count, not `!= nil`, so a wholesale replacement or a
        // partial prune (group apply) refreshes the caches too. (No
        // arrival-entry normalization remains: the one apply path reads
        // an absent selection id as not accepted, so display state and
        // apply state agree without producer entries or a belt.)
        .onChange(of: redactionState.pendingTriage?.values.reduce(0) { $0 + $1.count } ?? 0) { _, _ in
            recomputeAll()
        }
        .onChange(of: redactionState.crossPageEntityGroups.count) { _, _ in recomputeAll() }
    }

    /// The review surface's fixed chrome — OCR-skip banner,
    /// classification diagnostics, the view-mode/kind chip bar, and
    /// the Select-Where row — riding the review List's top safe-area
    /// inset (SA-2/D-70: chrome must not offset the List's frame from
    /// the sheet top or cooperative arbitration unbinds; 18- §10).
    /// Opaque background — rows scroll UNDER the inset region.
    private var reviewTopChrome: some View {
        VStack(spacing: 0) {
            // ST-83 — pipeline-side OCR-skip disclosure: pages whose
            // raster exceeded the OCR pixel caps during the detection
            // run under review, so their image content was never
            // text-scanned.
            if !redactionState.ocrPixelCapSkippedPages.isEmpty {
                ocrSkipBanner
            }

            // Phase 3 G5: "Why this classification?" (in-memory only).
            classificationDiagnosticPanel

            // View-mode picker + kind filter chips (one chip component).
            reviewChipBar

            // Select-Where predicates over the staged findings —
            // the review-side selection-throughput tools.
            selectWhereRow
        }
        .background(.background)
    }

    // MARK: - Rows

    /// One review row through the shared family: detection badge,
    /// confidence bar on the shared absolute bands, selection bound to
    /// `triageSelections` (explicit-entry contract), and the W9
    /// detector-evaluation entry in the trailing slot.
    @ViewBuilder
    private func reviewRow(page: Int, detection: DetectionResult) -> some View {
        let isSelected = redactionState.triageSelections[detection.id] ?? false
        FindingRow(
            model: FindingRowModel(
                page: page,
                detection: detection,
                isSelected: isSelected,
                isAmbiguousSurname: redactionState.ambiguousSurnameDetectionIDs
                    .contains(detection.id)
            ),
            isSelected: Binding(
                get: { redactionState.triageSelections[detection.id] ?? false },
                set: { newValue in
                    redactionState.triageSelections[detection.id] = newValue
                    // Conditional dismiss: a row toggle is user selection work; the
                    // sheet's Dismiss confirms from here forward.
                    searchState.userModifiedSelections = true
                }
            ),
            leading: {
                Rectangle()
                    .fill(SearchResultRow.absoluteConfidenceTier(detection.confidence).color)
                    .frame(width: 2)
                    .accessibilityHidden(true)
            },
            badge: {
                Text(detection.kind.badge)
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, ResectaTokens.Spacing.xs)
                    .padding(.vertical, 2)
                    .background(detection.kind.badgeColor, in: Capsule())
            },
            trailing: {
                // W9 — reverse rationale entry point (text kinds only).
                if detection.matchedText != nil {
                    Button {
                        presentReverseRationale(for: detection, page: page)
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show detector evaluation")
                }
            }
        )
        .padding(.vertical, ResectaTokens.Spacing.xxs)
        // SA-3 rider (B-3): row-body tap navigates the canvas —
        // parity with `SearchResultRow`'s contentShape+onTapGesture
        // idiom. The inner selection circle and W9 button are
        // Buttons, so they keep winning their own hit regions; the
        // rest of the row navigates.
        .contentShape(Rectangle())
        .onTapGesture { onNavigateToPage(page) }
        // The family row's `.ignore` merge hides the trailing W9 button
        // from VoiceOver (the retired triage row's `.combine` surfaced
        // it implicitly) — expose it as a named action so the detector-
        // evaluation entry stays reachable non-visually. The builder
        // form keeps the action conditional on the same gate as the
        // visual button, so non-text rows advertise no dead action.
        .accessibilityActions {
            if detection.matchedText != nil {
                Button("Show detector evaluation") {
                    presentReverseRationale(for: detection, page: page)
                }
            }
        }
    }

    // MARK: - Chip Bar

    @ViewBuilder
    private var reviewChipBar: some View {
        // SA-2 (D-70): FlowLayout wrap replaces the horizontal
        // ScrollView (B-1 — every control stays visible; at
        // accessibility sizes rows wrap instead of panning
        // off-screen), and the bar's two ARBITRATION POISONS are
        // gone: the SA-2 bisect (18- §10 correction) isolated the
        // menu-style Picker and the Divider as the elements that
        // killed the sheet's cooperative scroll↔detent arbitration —
        // the ScrollView container itself proved innocent. The
        // view-mode control rides a Menu (the class proven innocent
        // in every COOP probe run) wrapping the same inline Picker
        // rows; the Divider is dropped — a wrapped flow needs no
        // vertical separator.
        FlowLayout(spacing: ResectaTokens.Spacing.sm) {
            Menu {
                Picker("View", selection: $viewMode) {
                    ForEach(ReviewViewMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue)
                    }
                }
            } label: {
                HStack(spacing: ResectaTokens.Spacing.xxs) {
                    Text(viewMode.rawValue)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .accessibilityHidden(true)
                }
                .font(.caption)
            }
            // AX exposure parity with the retired menu-style Picker:
            // "View, <mode>".
            .accessibilityLabel("View")
            .accessibilityValue(viewMode.rawValue)

            // Kind filter chips — narrow the visible list only
            // (GATE-4 decouple carried: a filter change never
            // rewrites selections, so manual selection work
            // survives it; selection throughput lives in the
            // footer Select All + Select-Where).
            FilterChip(
                label: "All",
                count: allFindings.count,
                isSelected: filterKind == nil
            ) {
                filterKind = nil
            }
            ForEach(cachedKindsWithCounts, id: \.kind) { item in
                FilterChip(
                    label: item.kind.badge,
                    count: item.count,
                    tint: item.kind.badgeColor,
                    isSelected: filterKind == item.kind
                ) {
                    filterKind = item.kind
                }
            }
        }
        .padding(.horizontal, ResectaTokens.Spacing.md)
        .padding(.vertical, ResectaTokens.Spacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Detection filters")
    }

    // MARK: - Select Where

    /// Predicate-driven selection over the staged detections, mirroring
    /// the search side's menu: replaces every detection's selection with
    /// the predicate's verdict, so "select only ≥ 90%" is one mutation.
    private var selectWhereRow: some View {
        HStack {
            Menu {
                Section("By confidence") {
                    Button("\u{2265} 75%") { selectWhere { $0.confidence >= 0.75 } }
                    Button("\u{2265} 90%") { selectWhere { $0.confidence >= 0.90 } }
                }
                if !cachedKindsWithCounts.isEmpty {
                    Section("By category") {
                        ForEach(cachedKindsWithCounts, id: \.kind) { item in
                            Button(item.kind.fullName) {
                                selectWhere { $0.kind == item.kind }
                            }
                        }
                    }
                }
            } label: {
                Label("Select where...", systemImage: "checkmark.circle")
                    .font(.caption)
            }
            .controlSize(.small)
            .accessibilityLabel("Select findings by attribute")
            Spacer()
        }
        .padding(.horizontal, ResectaTokens.Spacing.md)
        .padding(.vertical, ResectaTokens.Spacing.xxs)
    }

    private func selectWhere(_ predicate: (DetectionResult) -> Bool) {
        redactionState.triageSelections = Self.selections(
            where: predicate, in: allFindings
        )
        // Conditional dismiss: predicate selection is user selection work.
        searchState.userModifiedSelections = true
    }

    // MARK: - ST-83 OCR-Skip Banner (pipeline-side)

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

    // MARK: - Phase 3 G5: Classification diagnostic

    /// Representative diagnostic chosen by majority doctype across all pages.
    /// Returns nil when no pages carry a diagnostic (e.g., classifier asset
    /// missing). In-memory only — never logged, never persisted.
    private var representativeDiagnostic: ClassificationDiagnostic? {
        let diagnostics = redactionState.pageDiagnostics
        guard !diagnostics.isEmpty else { return nil }
        var primaryCounts: [DoctypeClass: Int] = [:]
        for diag in diagnostics.values {
            primaryCounts[diag.primary, default: 0] += 1
        }
        let modalPrimary = primaryCounts.max(by: { $0.value < $1.value })?.key
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

    /// Derive the context buffer from the page's text layer and route
    /// the request to the sheet's modal slot. Context window is bounded
    /// to ±250 chars around the detection's matched text.
    private func presentReverseRationale(for detection: DetectionResult, page: Int) {
        guard let snippet = detection.matchedText else { return }
        let doctype = representativeDiagnostic?.primary
        let context = contextBuffer(for: snippet, page: page)
        onRequestWhy(ReverseRationaleRequest(
            snippet: snippet,
            fullContext: context,
            doctype: doctype
        ))
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
            return snippet
        }
        let radius = 250
        let start = max(0, loc - radius)
        let end = min(ns.length, loc + (snippet as NSString).length + radius)
        return ns.substring(with: NSRange(location: start, length: end - start))
    }

    // MARK: - DRAW-4 Grouped view mode

    /// Cross-page entity group list. Each row collapses every member
    /// detection of one group into a single tap-target so accept applies
    /// all members atomically through the group origin of
    /// `applyFindings` — one undo step.
    @ViewBuilder
    private var groupedFindingList: some View {
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
                            Task { @MainActor in
                                guard let outcome = await redactionState.applyFindings(
                                    .entityGroup(group),
                                    undoManager: undoManager,
                                    documentState: documentState
                                ) else { return }
                                // UXF-29 — the apply pruned its members
                                // from `pendingTriage`; refresh so this
                                // group's row (and its flat-list rows)
                                // leave the screen. A second tap racing
                                // this one resolves against the pruned
                                // review and applies zero — benign.
                                recomputeAll()
                                // UXF-11 — commit feedback through the
                                // shared copy builder. The sheet-local
                                // toast host renders it whether or not
                                // the prune emptied the review (the
                                // sheet itself stays up).
                                if let message = CommitFeedback.markedMessage(applied: outcome.applied) {
                                    toastManager.enqueue(message, severity: .success)
                                }
                            }
                        }
                    )
                    // Mirror the toolbar Apply's disable while the
                    // pipeline owns `regions`; the path re-checks
                    // inside the action either way.
                    .disabled(!documentState.canMutateRegions)
                }
            }
            .listStyle(.plain)
            .accessibilityIdentifier("crossPageGroupList")
        }
    }

    // MARK: - Derivations

    private func recomputeAll() {
        let flat = allFindings
        cachedKindsWithCounts = Self.kindsWithCounts(in: flat)
        cachedFilteredFindings = Self.filteredFindings(
            flat, filterKind: filterKind, viewMode: viewMode
        )
        cachedFilteredGroups = Self.filteredGroups(
            redactionState.crossPageEntityGroups,
            pending: redactionState.pendingTriage,
            filterKind: filterKind
        )
    }

    // MARK: - Pure helpers (testable without a SwiftUI host)

    /// Flatten the staged-detections map into a page-sorted list.
    static func flattenedFindings(
        _ pending: [Int: [DetectionResult]]?
    ) -> [(page: Int, detection: DetectionResult)] {
        guard let pending else { return [] }
        var flat: [(Int, DetectionResult)] = []
        for (page, results) in pending.sorted(by: { $0.key < $1.key }) {
            for result in results {
                flat.append((page, result))
            }
        }
        return flat
    }

    /// Unique detection kinds with counts, sorted by display order.
    static func kindsWithCounts(
        in findings: [(page: Int, detection: DetectionResult)]
    ) -> [(kind: DetectionResult.Kind, count: Int)] {
        var counts: [DetectionResult.Kind: Int] = [:]
        for item in findings {
            counts[item.detection.kind, default: 0] += 1
        }
        return counts.sorted { $0.key.sortOrder < $1.key.sortOrder }
            .map { (kind: $0.key, count: $0.value) }
    }

    /// Kind filter + view-mode ordering over the flattened detections.
    static func filteredFindings(
        _ findings: [(page: Int, detection: DetectionResult)],
        filterKind: DetectionResult.Kind?,
        viewMode: ReviewViewMode
    ) -> [(page: Int, detection: DetectionResult)] {
        var result = findings
        if let filterKind {
            result = result.filter { $0.detection.kind == filterKind }
        }
        switch viewMode {
        case .byPage: break // Already page-sorted by flattenedFindings.
        case .byType:
            result.sort { $0.detection.kind.fullName < $1.detection.kind.fullName }
        case .byConfidence:
            result.sort { $0.detection.confidence > $1.detection.confidence }
        case .grouped:
            // .grouped renders `cachedFilteredGroups`; the flat order
            // here is the byPage fall-through so toggling back to a
            // flat mode lands on a sensible default.
            break
        }
        return result
    }

    /// Group visibility under the active kind filter. A group whose
    /// members are all gone from `pendingTriage` (already promoted by
    /// "Apply Group") is hidden — keeping its row invited a second tap
    /// that used to double-create (UXF-29).
    static func filteredGroups(
        _ groups: [CrossPageEntityGroup],
        pending: [Int: [DetectionResult]]?,
        filterKind: DetectionResult.Kind?
    ) -> [CrossPageEntityGroup] {
        var lookup: [UUID: DetectionResult] = [:]
        if let pending {
            for (_, results) in pending {
                for result in results { lookup[result.id] = result }
            }
        }
        return groups.filter { group in
            guard group.detectionIDs.contains(where: { lookup[$0] != nil }) else {
                return false
            }
            if let filterKind {
                guard case .pii(let kind) = filterKind, kind == group.category else {
                    return false
                }
            }
            return true
        }
    }

    /// Predicate selection over the staged detections: every detection gets
    /// an EXPLICIT entry (predicate verdict), mirroring the search
    /// side's `selectWhere` replace-semantics.
    static func selections(
        where predicate: (DetectionResult) -> Bool,
        in findings: [(page: Int, detection: DetectionResult)]
    ) -> [UUID: Bool] {
        var next: [UUID: Bool] = [:]
        for item in findings {
            next[item.detection.id] = predicate(item.detection)
        }
        return next
    }
}

// MARK: - DRAW-4 CrossPageGroupRow

/// Single-row view for a `CrossPageEntityGroup`. Surfaces canonical text,
/// member count, and pages; "Apply Group" promotes every member in one
/// atomic undo step via the entity-group origin of `applyFindings`.
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
