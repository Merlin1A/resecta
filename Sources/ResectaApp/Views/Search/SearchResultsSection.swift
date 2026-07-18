import SwiftUI
import RedactionEngine

// Results list + empty / filtered-out states +
// row helpers + live preview row + scope picker + keyboard shortcuts.
// Lifted from `SearchAndRedactSheet.swift`; behavior unchanged.
// "Select where…" Menu lands in the results-header
// zone; predicate-driven attribute selection routes through the new
// `SearchState.selectWhere` helper.

struct SearchResultsSection: View {
    @Bindable var searchState: SearchState
    @Environment(DocumentState.self) private var documentState
    @Environment(RedactionState.self) private var redactionState
    // SettingsState injected so the Coverage Report
    // can build snapshot metadata without threading it through from the
    // sheet body.
    @Environment(SettingsState.self) private var settingsState
    // ToastQueueManager injected so the coverage
    // snapshot share path can surface a `.error` toast when the temp
    // file write fails (previously a silent return — indistinguishable
    // from a UI bug).
    @Environment(ToastQueueManager.self) private var toastManager
    // `appliedResultIDs` lives on `searchState`.
    // Reads go through `searchState.appliedResultIDs`.
    @Binding var selectedDetent: PresentationDetent
    let onRequestWhy: (SearchResult) -> Void
    let onApplyShortcut: () -> Void
    /// Gates the invisible Return-key Button. Held-Return key-repeat
    /// would otherwise fire the apply shortcut on every tick (25–50 Hz),
    /// each tick a full freeze; the parent sheet flips this
    /// false for the duration of an in-flight apply.
    let applyShortcutEnabled: Bool
    /// Emit a row's rationale request to the parent's single
    /// `activeModal` slot. The previous SearchResultRow held its own
    /// `@State showRationale` plus a `.sheet(isPresented:)` modifier;
    /// hoisting the presentation upward consolidates all sheet
    /// traffic into the parent's `.sheet(item:)`.
    let onRequestShowRationale: (UUID) -> Void
    /// Re-trigger the full search after a saturation
    /// banner shortcut mutates `searchState.options` (whole-word /
    /// case-sensitive) or `navigationScope`. Without re-triggering, the
    /// next 300 ms debounce would eventually run, but the banner's tap
    /// would feel broken in the interim.
    let onTriggerSearch: () -> Void

    /// Per-sheet-session dismiss state for the doctype banner.
    /// `SearchResultsSection` is re-instantiated when the sheet
    /// re-opens, so dismissal naturally resets per sheet session.
    @State private var isDoctypeBannerDismissed: Bool = false

    /// Anchored-row contract — when
    /// tap-on-row drops the sheet to compact, the row the user tapped
    /// must remain topmost in the (much shorter) results list. The tap
    /// handler writes `result.id` here; an `.onChange` on the wrapping
    /// `ScrollViewReader` consumes the value and routes it through
    /// `proxy.scrollTo(_:anchor:)` then resets to nil so the same row
    /// can be re-anchored later.
    @State private var pendingAnchorID: UUID?

    /// Per-row frames in the shared
    /// `PencilCircleSelectCoordinateSpace.name` coordinate space.
    /// Populated by each row's `.trackRowFrameForPencilSelect(id:)`
    /// modifier via the `RowFramesPreferenceKey`; consumed by the
    /// `pencilCircleSelect` overlay at gesture-end time to compute
    /// which rows the closed loop enclosed. The gesture is
    /// Pencil-only — finger drags
    /// fall through to the List's native scroll path.
    @State private var rowFrames: [UUID: CGRect] = [:]

    /// Reduce Motion gate for any animation introduced
    /// by the saturation banner (currently a no-op — the banner appears
    /// inside the existing show/hide branching of `livePreviewRow`).
    /// Threaded through so future per-button feedback stays guarded.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            // D06-F2 Part 2 — fold the live applied / deselected view-state
            // counts into the stored scan report so the panel AND the shared
            // audit snapshot (`shareCoverageSnapshot` below, which reads the
            // same `report`) reflect what the user has applied/deselected,
            // not the scan-time zeros `makeCoverageReport` stored.
            // The whole Scan Coverage surface (incl. the auto-open
            // and Share Snapshot) is hidden for 1.0 behind
            // `searchAuditSurfacesEnabled`; the report computation itself
            // keeps running in SearchState.
            if SearchState.searchAuditSurfacesEnabled,
               let report = searchState.coverageReportForDisplay(),
               searchState.searchModeType == .piiScan {
                CoverageReportView(
                    report: report,
                    results: searchState.results,
                    diff: searchState.diffSinceLastScan(),
                    onShareSnapshot: { shareCoverageSnapshot(report: report) }
                )
                .padding(.horizontal, ResectaTokens.Spacing.md)
                .padding(.top, ResectaTokens.Spacing.xs)
            }

            // Doctype banner — always-visible primary doctype +
            // detector count above the results list for simplicity.
            // Placed inside the same scroll container as the list
            // (acceptable to scroll off at compact detent).
            // Hidden for 1.0 behind `searchDiagnosticSurfacesEnabled`.
            if SearchState.searchDiagnosticSurfacesEnabled,
               searchState.searchModeType == .piiScan,
               let explanation = searchState.lastDoctypeExplanation,
               !isDoctypeBannerDismissed {
                DoctypeDiagnosticView(
                    explanation: explanation,
                    style: .banner(
                        enabledPIICategories: searchState.enabledPIICategories,
                        onDismiss: { isDoctypeBannerDismissed = true }
                    )
                )
            }

            // Per-page regex-timeout banner. Surfaces
            // when `DocumentSearcher`'s timeout sink fired for one or more
            // pages during the active scan. Copy NEVER echoes pattern text —
            // only generic active-pattern phrasing — so a
            // pasted PII-like regex can't leak via the banner.
            if !searchState.regexTimeoutPages.isEmpty {
                regexTimeoutBanner
            }

            // ST-83 — per-page OCR-skip banner. Surfaces when
            // `DocumentSearcher`'s OCR-skip sink fired for one or more
            // pages during the active scan: those pages exceeded the OCR
            // pixel caps, so their image content was never text-scanned.
            if !searchState.ocrSkippedPages.isEmpty {
                ocrSkipBanner
            }

            // Live preview row (counts + saturation/invalid signal).
            livePreviewRow

            // Session-scoped navigation scope — the shared page-scope
            // control, shown on BOTH interfaces (it scopes J/K and
            // Cmd+G result traversal; it was previously hidden in the
            // scan mode only because the live-preview path is disabled
            // there, which never affected its traversal job).
            scopePicker

            // "Select where…" Menu surfaces predicate-driven
            // attribute selection.
            selectWhereMenu

            if searchState.results.isEmpty && !searchState.isSearching {
                emptyState
            } else if searchState.filteredCount == 0 && !searchState.results.isEmpty && !searchState.isSearching {
                filteredOutState
            } else {
                resultsList
            }
        }
        .background { keyboardShortcutButtons }
    }

    // MARK: - Select Where… Menu

    /// Predicate-driven attribute selection. Each Section corresponds
    /// to one predicate kind (confidence threshold, source, category,
    /// applied state). Tapping an option routes through
    /// `searchState.selectWhere(_:)` — a pure replacement that
    /// deselects rows outside the predicate so the Menu reads as
    /// "select only matching rows" rather than "add to selection". By
    /// applying to `searchState.results` (not `filteredResults`) the
    /// Menu remains useful when filters hide candidates the user wants
    /// to operate on.
    /// Every branch routes through `userSelectWhere` so the conditional-dismiss
    /// touched tracker flips exactly once per user predicate pick.
    @ViewBuilder
    private var selectWhereMenu: some View {
        if !searchState.results.isEmpty {
            HStack {
                Menu {
                    Section("By confidence") {
                        Button("\u{2265} 75%") {
                            userSelectWhere { ($0.piiConfidence ?? 0) >= 0.75 }
                        }
                        Button("\u{2265} 90%") {
                            userSelectWhere { ($0.piiConfidence ?? 0) >= 0.90 }
                        }
                    }
                    Section("By source") {
                        Button("Text") {
                            userSelectWhere { $0.source == .textLayer }
                        }
                        Button("OCR") {
                            userSelectWhere { $0.source != .textLayer }
                        }
                    }
                    if searchState.searchModeType == .piiScan {
                        let categories = searchState.categoryCounts.keys
                            .sorted(by: { $0.rawValue < $1.rawValue })
                        if !categories.isEmpty {
                            Section("By category") {
                                ForEach(categories, id: \.self) { category in
                                    Button(category.rawValue) {
                                        userSelectWhere { $0.piiCategory == category }
                                    }
                                }
                            }
                        }
                    }
                    Section("By applied state") {
                        Button("Applied") {
                            let applied = searchState.appliedResultIDs
                            userSelectWhere { applied.contains($0.id) }
                        }
                        Button("Unapplied") {
                            let applied = searchState.appliedResultIDs
                            userSelectWhere { !applied.contains($0.id) }
                        }
                    }
                } label: {
                    Label("Select where...", systemImage: "checkmark.circle")
                        .font(.caption)
                }
                .controlSize(.small)
                .accessibilityLabel("Select results by attribute")
                Spacer()
            }
            .padding(.horizontal, ResectaTokens.Spacing.md)
            .padding(.vertical, ResectaTokens.Spacing.xxs)
        }
    }

    /// Select-Where wrapper: the predicate replacement plus the conditional-dismiss
    /// touched flip — predicate selection is user selection work, so
    /// the sheet's Dismiss confirms from here forward.
    private func userSelectWhere(_ predicate: (SearchResult) -> Bool) {
        searchState.selectWhere(predicate)
        searchState.userModifiedSelections = true
    }

    // MARK: - Live Preview Row

    @ViewBuilder
    private var livePreviewRow: some View {
        if !searchState.queryText.isEmpty,
           searchState.searchModeType != .piiScan,
           let preview = searchState.livePreview {
            if preview.saturated {
                saturationBanner
            } else {
                HStack(spacing: ResectaTokens.Spacing.xs) {
                    if preview.regexInvalid {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text("Regex: invalid")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Image(systemName: "eye")
                            .foregroundStyle(.secondary)
                        Text("Matches this page: \(preview.currentPageMatches.count) \u{00B7} Total: \(preview.totalCount)")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, ResectaTokens.Spacing.md)
                .padding(.vertical, ResectaTokens.Spacing.xxs)
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: - Saturation Banner

    /// Saturation message promoted from a flat
    /// `Image + Text` row to an actionable banner with three inline
    /// shortcuts that re-target the saturated query. Each shortcut
    /// mutates the corresponding `searchState` field then invokes
    /// `onTriggerSearch` so the saturated query re-runs with the new
    /// constraint without waiting for the next debounce. Banner appear/
    /// disappear stays inside the existing `livePreviewRow` show/hide
    /// branch — no new explicit transition. Reduce Motion preserved
    /// via the `reduceMotion` environment threaded above.
    /// "Add whole-word filter" / "Toggle case-sensitive" / "Scope to
    /// current page" are mechanism-description action labels.
    private var saturationBanner: some View {
        VStack(alignment: .leading, spacing: ResectaTokens.Spacing.xs) {
            HStack(spacing: ResectaTokens.Spacing.xs) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                Text(WU23Strings.headline)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                Spacer()
            }
            .accessibilityElement(children: .combine)

            HStack(spacing: ResectaTokens.Spacing.sm) {
                Button {
                    searchState.options.wholeWord = true
                    onTriggerSearch()
                } label: {
                    Text(WU23Strings.addWholeWord)
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(searchState.options.wholeWord || searchState.isSearching)
                .accessibilityLabel(WU23Strings.addWholeWord)

                Button {
                    searchState.options.caseSensitive.toggle()
                    onTriggerSearch()
                } label: {
                    Text(WU23Strings.toggleCaseSensitive)
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(searchState.isSearching)
                .accessibilityLabel(WU23Strings.toggleCaseSensitive)

                Button {
                    scopeSaturatedSearchToCurrentPage()
                } label: {
                    Text(WU23Strings.scopeToCurrentPage)
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(searchState.navigationScope == .currentPage || searchState.isSearching)
                .accessibilityLabel(WU23Strings.scopeToCurrentPage)
            }
        }
        .padding(.horizontal, ResectaTokens.Spacing.md)
        .padding(.vertical, ResectaTokens.Spacing.xs)
        .background(Color.orange.opacity(0.08))
    }

    /// Scope-to-current-page handler for the
    /// saturation banner. Delegates the flush → cancel → scope chain
    /// to `SearchState.scopeToCurrentPage()` (testable) then invokes
    /// `onTriggerSearch` so the saturated query re-runs against the
    /// page-scoped constraint. The page index that the
    /// `.currentPage` filter resolves against is read fresh by
    /// `scopedResults(currentPageIndex:)` at J/K-tap time —
    /// `documentState.currentPageIndex` is captured at tap time
    /// transitively through the SwiftUI button action firing
    /// synchronously when the user taps.
    private func scopeSaturatedSearchToCurrentPage() {
        Task { @MainActor in
            await searchState.scopeToCurrentPage()
            onTriggerSearch()
        }
    }

    // MARK: - Regex Timeout Banner

    /// Surfaces when one or more pages bailed on
    /// the regex per-page timeout. Copy NEVER echoes pattern text —
    /// uses only the generic active-pattern phrasing so a
    /// pasted PII-like regex can't leak via the banner. Pinned by
    /// `RegexTimeoutBannerTests.bannerCopyNeverEchoesPattern` (the test
    /// feeds a known-distinctive pattern and greps the banner output).
    private var regexTimeoutBanner: some View {
        let pages = searchState.regexTimeoutPages.sorted()
        let headline = Self.regexTimeoutBannerHeadline(pages: pages)
        return HStack(alignment: .top, spacing: ResectaTokens.Spacing.sm) {
            Image(systemName: "clock.badge.exclamationmark")
                .foregroundStyle(.secondary)
            Text(headline)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: ResectaTokens.Spacing.xs)
        }
        .padding(.horizontal, ResectaTokens.Spacing.md)
        .padding(.vertical, ResectaTokens.Spacing.xs)
        .background(Color.orange.opacity(0.08))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(headline)
    }

    /// Banner headline copy. Pages are 0-indexed internally;
    /// rendered as 1-based page numbers for the user.
    static func regexTimeoutBannerHeadline(pages: [Int]) -> String {
        let oneBased = pages.map { $0 + 1 }
        let list = formatPageList(oneBased)
        let pageNoun = oneBased.count == 1 ? "page" : "pages"
        return "The active regex pattern timed out on \(pageNoun) \(list). Results may be incomplete."
    }

    // MARK: - ST-83 OCR-Skip Banner

    /// Surfaces when one or more pages exceeded the OCR pixel caps during
    /// the active scan, so OCR never ran there. Same shape as the
    /// regex-timeout banner above; copy names only page numbers, never
    /// document content. Pinned by `OCRSkipBannerTests`.
    private var ocrSkipBanner: some View {
        let pages = searchState.ocrSkippedPages.sorted()
        let headline = Self.ocrSkipBannerHeadline(pages: pages)
        return HStack(alignment: .top, spacing: ResectaTokens.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            Text(headline)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: ResectaTokens.Spacing.xs)
        }
        .padding(.horizontal, ResectaTokens.Spacing.md)
        .padding(.vertical, ResectaTokens.Spacing.xs)
        .background(Color.orange.opacity(0.08))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(headline)
    }

    /// ST-83 banner headline. Pages are 0-indexed internally; rendered
    /// as 1-based page numbers for the user. Mechanism description only.
    static func ocrSkipBannerHeadline(pages: [Int]) -> String {
        let oneBased = pages.map { $0 + 1 }
        let list = formatPageList(oneBased)
        let pageNoun = oneBased.count == 1 ? "Page \(list) was" : "Pages \(list) were"
        return "\(pageNoun) too large to scan for text — image content there was not searched."
    }

    /// English-list formatter for page numbers. "3" / "3 and 5"
    /// / "3, 5, and 7". Caller passes 1-based numbers.
    static func formatPageList(_ pages: [Int]) -> String {
        switch pages.count {
        case 0:  return ""
        case 1:  return "\(pages[0])"
        case 2:  return "\(pages[0]) and \(pages[1])"
        default:
            let leading = pages.dropLast().map(String.init).joined(separator: ", ")
            return "\(leading), and \(pages.last!)"
        }
    }

    // MARK: - Scope Picker

    private var scopePicker: some View {
        Picker("Scope", selection: $searchState.navigationScope) {
            Text("This page").tag(SearchNavigationScope.currentPage)
            Text("Whole document").tag(SearchNavigationScope.wholeDocument)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, ResectaTokens.Spacing.md)
        .padding(.vertical, ResectaTokens.Spacing.xxs)
        .accessibilityLabel("Navigation scope")
    }

    // MARK: - Keyboard Shortcuts (J / K / Space / Return)

    /// Mirrors the Cmd+G hidden-Button pattern at the search-bar level —
    /// invisible buttons whose `.keyboardShortcut(...)` is what the
    /// hardware keyboard activates. iPhone (no keyboard) renders nothing.
    private var keyboardShortcutButtons: some View {
        Group {
            Button {
                searchState.navigateToPrevious(currentPageIndex: documentState.currentPageIndex)
                navigateToCurrentResult()
            } label: { EmptyView() }
                .accessibilityLabel("Previous match")
                .keyboardShortcut("j", modifiers: [])

            Button {
                searchState.navigateToNext(currentPageIndex: documentState.currentPageIndex)
                navigateToCurrentResult()
            } label: { EmptyView() }
                .accessibilityLabel("Next match")
                .keyboardShortcut("k", modifiers: [])

            Button {
                searchState.toggleSelectionForCurrentMatch()
                // Conditional dismiss: the space-key toggle is user selection work.
                searchState.userModifiedSelections = true
            } label: { EmptyView() }
                .accessibilityLabel("Toggle selection for current match")
                .keyboardShortcut(" ", modifiers: [])

            Button {
                onApplyShortcut()
            } label: { EmptyView() }
                .accessibilityLabel("Apply selected matches")
                .keyboardShortcut(.return, modifiers: [])
                .disabled(!applyShortcutEnabled)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(false)
    }

    private func navigateToCurrentResult() {
        guard let result = searchState.currentResult else { return }
        documentState.currentPageIndex = result.pageIndex
        if selectedDetent == .large {
            selectedDetent = .medium
        }
    }

    // MARK: - Results List

    private var resultsList: some View {
        let isMultiTerm = searchState.searchModeType == .multiTerm && searchState.searchTerms.count > 1
        let useTermGrouping = isMultiTerm && searchState.groupByTerm

        // ScrollViewReader composes with the `.plain` List so the
        // anchored-row contract can scroll to a tapped row's
        // ID after the detent transition. SwiftUI's List uses `ForEach`
        // identity as the scroll target — `result.id` (UUID) carries
        // through to the proxy without explicit `.id(...)` modifiers.
        return ScrollViewReader { proxy in
            list(useTermGrouping: useTermGrouping,
                 isMultiTerm: isMultiTerm,
                 proxy: proxy)
        }
    }

    /// Inner `List` body extracted from
    /// `resultsList` so the surrounding modifiers
    /// (`.coordinateSpace`, `.onPreferenceChange`, `.pencilCircleSelect`)
    /// can compose without ballooning the type-checker budget on the
    /// already-large `resultsList` builder.
    @ViewBuilder
    private func list(
        useTermGrouping: Bool,
        isMultiTerm: Bool,
        proxy: ScrollViewProxy
    ) -> some View {
        let inner = List {
                if useTermGrouping {
                    // Group by search term. The
                    // header names the conjunction when AND mode is active
                    // so the counts read correctly (every listed page has
                    // all terms).
                    let terms = searchState.resultsByTerm.keys.sorted()
                    let conjunctionSuffix = searchState.options.multiTermConjunction
                        ? " on pages with all terms" : ""
                    ForEach(terms, id: \.self) { term in
                        if let termResults = searchState.resultsByTerm[term] {
                            Section("\"\(term)\" — \(termResults.count) match\(termResults.count == 1 ? "" : "es")\(conjunctionSuffix)") {
                                ForEach(termResults) { result in
                                    resultRow(for: result, showTermLabel: false)
                                }
                            }
                        }
                    }
                } else {
                    // Default: Group by page
                    let pages = searchState.resultsByPage.keys.sorted()
                    ForEach(pages, id: \.self) { page in
                        Section("Page \(page + 1)") {
                            if let pageResults = searchState.resultsByPage[page] {
                                ForEach(pageResults) { result in
                                    resultRow(for: result, showTermLabel: isMultiTerm)
                                }
                            }
                        }
                    }
                }
            }
        .listStyle(.plain)
        .onChange(of: pendingAnchorID, initial: false) { (_: UUID?, newID: UUID?) in
            anchorTappedRow(newID: newID, proxy: proxy)
        }

        // Pencil circle-to-select. The named
        // coordinate space scopes per-row geometry into the List
        // boundary so the Pencil overlay reads frames in the same
        // space as the gesture path. `.onPreferenceChange` collects
        // per-row frames written via `.trackRowFrameForPencilSelect`
        // into `rowFrames`; the overlay consumes that map at
        // gesture-end via `enclosedRowIDs(loop:rowFrames:)`. The
        // gesture is Pencil-only (filtered by
        // `allowedTouchTypes` on the recognizer); finger drags pass
        // through to the List's native scroll. The
        // `#available(iOS 26, *)` gate inside
        // `PencilCircleSelectModifier` insulates future iOS-version
        // gesture-API swaps.
        inner
            .coordinateSpace(name: PencilCircleSelectCoordinateSpace.name)
            .onPreferenceChange(RowFramesPreferenceKey.self) { newFrames in
                rowFrames = newFrames
            }
            .pencilCircleSelect(rowFrames: rowFrames) { enclosed in
                for id in enclosed {
                    searchState.toggleSelection(for: id)
                }
                // Conditional dismiss: a Pencil circle-select is user selection work.
                if !enclosed.isEmpty {
                    searchState.userModifiedSelections = true
                }
            }
            // UXF-05 (ts2-04): at the medium detent the list's viewport
            // can shrink to a sliver; without clipping, row content
            // painted past the list frame under the footer — a
            // false affordance whose taps hit the footer. Clip so rows
            // never draw outside the list's own bounds.
            .clipped()
    }

    /// Consumed by the `.onChange` on `resultsList`'s
    /// ScrollViewReader. Extracted from the closure body both for type-check
    /// budget (the wrapping body has many @State observers) and so the
    /// scroll + reset routine can be unit-tested via the proxy seam in
    /// future iterations. Reset to nil after scrolling so re-tapping the
    /// same row re-triggers the anchor.
    @MainActor
    private func anchorTappedRow(newID: UUID?, proxy: ScrollViewProxy) {
        guard let newID else { return }
        // `.stateChange` shorthand can't infer through `Anim.resolved`'s
        // SwiftUI `Animation` parameter — spelled out
        // (same fix as the DisclosureGroup wrap).
        withAnimation(ResectaTokens.Anim.resolved(ResectaTokens.Anim.stateChange, reduceMotion: reduceMotion)) {
            proxy.scrollTo(newID, anchor: .top)
        }
        Task { @MainActor in
            pendingAnchorID = nil
        }
    }

    /// Safe binding for a search result by ID. Falls back to the snapshot
    /// if the result has been removed between render passes. The set
    /// side is the row circle — a user gesture — so it also flips the
    /// conditional-dismiss touched tracker.
    private func safeBinding(for id: UUID, fallback: SearchResult) -> Binding<SearchResult> {
        Binding(
            get: {
                searchState.results.first(where: { $0.id == id }) ?? fallback
            },
            set: { _ in
                searchState.toggleSelection(for: id)
                searchState.userModifiedSelections = true
            }
        )
    }

    @ViewBuilder
    private func resultRow(for result: SearchResult, showTermLabel: Bool) -> some View {
        let row = SearchResultRow(
            result: safeBinding(for: result.id, fallback: result),
            isCurrent: searchState.currentResult?.id == result.id,
            isApplied: searchState.appliedResultIDs.contains(result.id),
            showTermLabel: showTermLabel,
            // OCR rows grade against the live OCR floor; PII rows use
            // the shared absolute bands (the dormant per-run threshold
            // input retired with the row-family unification).
            ocrFloor: searchState.minimumOCRConfidence,
            // Regex source-capsule gate — mode + rationale signal.
            searchMode: searchState.searchModeType,
            onNavigate: {
                searchState.currentResultIndex = searchState.index(of: result.id)
                documentState.currentPageIndex = result.pageIndex
                // Tap-on-row drops to compact so the
                // PDF gets max area; the chevron / J/K nav path stays
                // at large → medium per the prior contract. Set
                // `pendingAnchorID` BEFORE the detent transition fires
                // so the `.onChange` on `resultsList`'s ScrollViewReader
                // proxy snaps the tapped row to the top.
                pendingAnchorID = result.id
                if selectedDetent != .compactFloat {
                    selectedDetent = .compactFloat
                }
            },
            onShowRationale: {
                onRequestShowRationale(result.id)
            }
        )
        .contextMenu {
            // Reverse-rationale popover for PII rows with a
            // populated rationale. Stays gated on piiCategory since
            // the popover speaks PII-specific language; non-PII rows
            // would show empty rationale signals.
            if result.piiCategory != nil {
                Button {
                    onRequestWhy(result)
                } label: {
                    Label("Why this match?", systemImage: "questionmark.circle")
                }
            }
        }

        row
            .trackRowFrameForPencilSelect(id: result.id)
    }

    // MARK: - Empty State
    //
    // Mode-specific actionable copy. Mechanism-description
    // discipline. The pre-scan / post-scan-zero / pre-search /
    // no-match / no-recents discriminator drives the headline,
    // description, and (multi-term only) recall-chip surface.
    // `WU20Strings` static functions are mechanism-description
    // copy. Outcome promises (e.g., "no PII found",
    // "all clear") are forbidden.

    private var emptyState: some View {
        let context = currentEmptyStateContext()
        // Effective count: an empty chip selection means the next run
        // scans everything, so the detector count reflects that.
        let piiCount = searchState.effectiveScanCategories.count
        return ContentUnavailableView {
            Label(
                WU20Strings.headline(for: context),
                systemImage: WU20Strings.headlineSymbol(for: context)
            )
        } description: {
            VStack(alignment: .center, spacing: ResectaTokens.Spacing.sm) {
                // Interface-level role line for the Search side,
                // above the per-mode caption. The Scan side's role
                // sentence lives inside its description string.
                if WU20Strings.showsSearchRoleSubtitle(for: context) {
                    Text(WU20Strings.searchRoleSubtitle)
                }
                // Markdown-bold markers only parse through the
                // LocalizedStringKey overload of `Text(_:)`; a plain
                // String variable hits the verbatim overload and renders
                // the asterisks literally (screenshot evidence) — the
                // explicit `.init` routes back to the markdown-aware path.
                Text(.init(WU20Strings.description(for: context)))
                if context == .piiScanPreScan,
                   let secondary = WU20Strings.piiScanPreScanSecondary(
                       enabledPIICategoryCount: piiCount
                   ) {
                    Text(.init(secondary))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if context == .multiTermPreSearchWithRecents {
                    multiTermRecallChips
                }
                // Text/regex pre-search recents chips,
                // parallel to the multiTerm recall pattern above.
                if context == .textPreSearch,
                   !searchState.recentTextQueries.isEmpty {
                    queryRecallChips(
                        queries: searchState.recentTextQueries,
                        accessibilityPrefix: WU20Strings.queryRecallAccessibilityPrefix
                    )
                }
                if context == .regexPreSearch,
                   !searchState.recentRegexQueries.isEmpty {
                    queryRecallChips(
                        queries: searchState.recentRegexQueries,
                        accessibilityPrefix: WU20Strings.queryRecallAccessibilityPrefix
                    )
                }
            }
        }
    }

    /// Derive the per-mode discriminator from the current
    /// SearchState shape. Pure function — pinned by EmptyStateTests
    /// so the discriminator stays in sync with the copy table.
    private func currentEmptyStateContext() -> WU20Strings.EmptyContext {
        WU20Strings.context(
            mode: searchState.searchModeType,
            queryText: searchState.queryText,
            multiTermTerms: searchState.searchTerms,
            recentMultiTermSets: searchState.recentMultiTermSets,
            currentSearchPage: searchState.currentSearchPage,
            totalCount: searchState.totalCount,
            enabledPIICategoryCount: searchState.effectiveScanCategories.count
        )
    }

    /// Tappable recall chips for the multi-term empty state.
    /// Each chip displays the term set joined with " + "; tap restores
    /// `searchState.searchTerms` to that set and re-triggers via
    /// `onTriggerSearch`.
    private var multiTermRecallChips: some View {
        VStack(alignment: .center, spacing: ResectaTokens.Spacing.xs) {
            Text(WU20Strings.recentSearchesHeader)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: ResectaTokens.Spacing.xs) {
                ForEach(Array(searchState.recentMultiTermSets.enumerated()), id: \.offset) { _, recall in
                    Button {
                        searchState.searchTerms = recall
                        onTriggerSearch()
                    } label: {
                        Text(WU20Strings.recallChipLabel(terms: recall))
                            .font(.caption2)
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(
                        WU20Strings.recallChipAccessibilityLabel(terms: recall)
                    )
                }
            }
        }
    }

    // MARK: - Text/Regex Recent Query Chips

    /// Tappable recall chips for text and regex pre-search empty states.
    /// Mirrors the multiTermRecallChips pattern. Tapping a chip sets
    /// `searchState.queryText` to the tapped value and re-triggers search
    /// via `onTriggerSearch()`. Chip labels carry `.privacySensitive()`
    /// (a recent query may contain PII).
    @ViewBuilder
    private func queryRecallChips(queries: [String], accessibilityPrefix: String) -> some View {
        VStack(alignment: .center, spacing: ResectaTokens.Spacing.xs) {
            Text(WU20Strings.recentSearchesHeader)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: ResectaTokens.Spacing.xs) {
                ForEach(Array(queries.enumerated()), id: \.offset) { _, query in
                    Button {
                        searchState.queryText = query
                        onTriggerSearch()
                    } label: {
                        Text(query)
                            .font(.caption2)
                            .lineLimit(1)
                            .privacySensitive()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("\(accessibilityPrefix): \(query)")
                }
            }
        }
    }

    // MARK: - Filtered Out State

    private var filteredOutState: some View {
        ContentUnavailableView {
            Label(
                WU20Strings.filteredOutHeadline,
                systemImage: "line.3.horizontal.decrease.circle"
            )
        } description: {
            Text(WU20Strings.filteredOutDescription)
        }
    }

    // MARK: - Coverage Snapshot Share

    /// Build counts-only export metadata + invoke the system
    /// share sheet via `MatchExportService.shareCoverageSnapshot`. The
    /// payload is structurally counts-only (no per-match data);
    /// the existing share surface stays unchanged.
    private func shareCoverageSnapshot(report: CoverageReport) {
        guard let presenter = MatchExportService.topViewController() else { return }
        let metadata = ExportMetadata(
            appVersion: Bundle.main.appVersion,
            presetName: "Default",
            perCategoryOverrides: [:],
            documentName: "document",
            totalMatches: report.candidateCountByCategory.values.reduce(0, +),
            appliedMatches: report.appliedCount
        )
        // shareCoverageSnapshot is now async (it awaits the
        // off-MainActor write). Spawn from this MainActor view method; the
        // Task inherits MainActor isolation so `presenter` (non-Sendable)
        // never crosses an actor boundary.
        Task { @MainActor in
            await MatchExportService.shareCoverageSnapshot(
                report: report,
                metadata: metadata,
                toastManager: toastManager,
                from: presenter
            )
        }
    }
}

// MARK: - Saturation Banner Strings
//
// Mechanism-description action labels — describe the affordance the
// user invokes, not an outcome promise.
// Kept off `Legal.xcstrings` because they are
// operational copy, not legal/marketing copy. Pinned by
// `SaturationBannerTests`.

enum WU23Strings {
    static let headline = "\u{2265} 10,000 matches \u{2014} refine query"
    static let addWholeWord = "Add whole-word filter"
    static let toggleCaseSensitive = "Toggle case-sensitive"
    static let scopeToCurrentPage = "Scope to current page"
}

// MARK: - Empty State Strings
//
// Mode-specific actionable copy. Mechanism-description
// discipline. Outcome promises (e.g., "no PII found", "all clear",
// "your document is clean", "nothing to redact") are forbidden.
// Every branch describes the engine's
// mechanism, not a verdict on the document. Pinned by
// `EmptyStateTests`.

enum WU20Strings {

    /// Discriminator for the per-mode empty-state branches. Drives
    /// headline / description / chip-row visibility from a single
    /// pure function so tests can pin the per-context copy without
    /// instantiating the SwiftUI view.
    enum EmptyContext: Equatable {
        case textPreSearch
        case textNoMatch
        case regexPreSearch
        case regexNoMatch
        case multiTermPreSearchNoRecents
        case multiTermPreSearchWithRecents
        case multiTermNoMatch
        case piiScanPreScan
        case piiScanPostScanZero(detectorCount: Int)
    }

    /// Pure-function context discriminator. Tested directly by
    /// `EmptyStateTests`; the view-side helper just forwards.
    static func context(
        mode: SearchModeType,
        queryText: String,
        multiTermTerms: [String],
        recentMultiTermSets: [[String]],
        currentSearchPage: Int,
        totalCount: Int,
        enabledPIICategoryCount: Int
    ) -> EmptyContext {
        switch mode {
        case .text:
            return queryText.isEmpty ? .textPreSearch : .textNoMatch
        case .regex:
            return queryText.isEmpty ? .regexPreSearch : .regexNoMatch
        case .multiTerm:
            if multiTermTerms.isEmpty {
                return recentMultiTermSets.isEmpty
                    ? .multiTermPreSearchNoRecents
                    : .multiTermPreSearchWithRecents
            }
            return .multiTermNoMatch
        case .piiScan:
            // Post-scan zero-result requires `currentSearchPage > 0`
            // (the scan ran) and `totalCount == 0` (no matches).
            if currentSearchPage > 0 && totalCount == 0 {
                return .piiScanPostScanZero(detectorCount: enabledPIICategoryCount)
            }
            return .piiScanPreScan
        }
    }

    /// Headline per branch.
    static func headline(for context: EmptyContext) -> String {
        switch context {
        case .textPreSearch:
            return "Text search"
        case .textNoMatch:
            return "No matches"
        case .regexPreSearch:
            return "Regex search"
        case .regexNoMatch:
            return "No matches"
        case .multiTermPreSearchNoRecents:
            return "Multi-term search"
        case .multiTermPreSearchWithRecents:
            return "Multi-term search"
        case .multiTermNoMatch:
            return "No matches"
        case .piiScanPreScan:
            // UXF-02 — pre-scan headline must not read as a verdict.
            // "Not scanned yet" states the actual condition; the
            // description below carries the Scan CTA.
            return "Not scanned yet"
        case .piiScanPostScanZero:
            return "Scan complete"
        }
    }

    static func headlineSymbol(for context: EmptyContext) -> String {
        switch context {
        case .textPreSearch, .multiTermPreSearchNoRecents,
             .multiTermPreSearchWithRecents, .regexPreSearch:
            return "magnifyingglass"
        case .textNoMatch, .regexNoMatch, .multiTermNoMatch:
            return "doc.text.magnifyingglass"
        case .piiScanPreScan:
            return "shield.lefthalf.filled"
        case .piiScanPostScanZero:
            return "checkmark.shield"
        }
    }

    /// Description per branch. Mechanism-description copy — describes
    /// the engine path or the affordance, not a verdict.
    static func description(for context: EmptyContext) -> String {
        switch context {
        case .textPreSearch:
            return "Type a word, phrase, or pattern to match against the document text."
        case .textNoMatch:
            return "No occurrences in the document for the active query. Try a broader term or change the search options."
        case .regexPreSearch:
            return "Enter a regular expression to match against the document text. Example: \\d{3}-\\d{2}-\\d{4} for SSN-style sequences."
        case .regexNoMatch:
            return "The active pattern produced no matches. Adjust the pattern or the search options."
        case .multiTermPreSearchNoRecents:
            return "Type a term above and press Return to add it. Each term searches the document independently."
        case .multiTermPreSearchWithRecents:
            return "Type a term above and press Return to add it, or recall a recent term set below."
        case .multiTermNoMatch:
            return "No occurrences in the document for any of the active terms."
        case .piiScanPreScan:
            // Carries the Scan interface's role sentence (moved here
            // from the scan toolbar; the Search interface's counterpart
            // is `searchRoleSubtitle` below). The copy states the
            // mechanism on its own terms: text detectors, on-device,
            // whole-document default, text content only — plus the
            // rationale-visibility half of the role: every result can
            // show the reasoning behind it.
            return "Runs the on-device PII text detectors across the whole document \u{2014} text content only. Results show why each item was flagged. Tap **Scan Document** above to run it."
        case .piiScanPostScanZero(let detectorCount):
            let suffix = detectorCount == 1 ? "" : "s"
            return "\(detectorCount) detector\(suffix) matched 0 candidates above threshold."
        }
    }

    // MARK: Search-interface role line

    /// One-line role sentence for the Search interface, rendered above
    /// the per-mode caption on the pre-search empty states (the Scan
    /// interface's counterpart is folded into the `piiScanPreScan`
    /// description above). States the literal-match contract: matches
    /// follow the query and its options; nothing is inferred beyond
    /// them. Pinned by `EmptyStateTests`.
    static let searchRoleSubtitle =
        "Matches exactly what you ask for \u{2014} nothing more, nothing inferred."

    /// True for the Search-side pre-search contexts that mount the
    /// role line. Pure predicate consumed by the empty state and
    /// pinned by `EmptyStateTests`. No-match branches stay
    /// role-line-free (they carry result feedback), and the Scan-side
    /// branches have their own role copy.
    static func showsSearchRoleSubtitle(for context: EmptyContext) -> Bool {
        switch context {
        case .textPreSearch, .regexPreSearch,
             .multiTermPreSearchNoRecents, .multiTermPreSearchWithRecents:
            return true
        case .textNoMatch, .regexNoMatch, .multiTermNoMatch,
             .piiScanPreScan, .piiScanPostScanZero:
            return false
        }
    }

    // MARK: PII Scan secondary description

    /// Secondary description line for the `piiScanPreScan` empty state.
    /// Returned only when `enabledPIICategoryCount > 0`; nil otherwise.
    /// States the active detector count; the selection affordance is
    /// the category chip row itself, and the retired Confidence
    /// slider's sentence retired with it (UXF-23 discipline: never
    /// name an affordance the view doesn't have). Mechanism-
    /// description, not an outcome promise. Pinned by `EmptyStateTests`.
    static func piiScanPreScanSecondary(enabledPIICategoryCount: Int) -> String? {
        guard enabledPIICategoryCount > 0 else { return nil }
        return "Detectors active: \(enabledPIICategoryCount)."
    }

    // MARK: Multi-term recall chips

    static let recentSearchesHeader = "Recent searches"

    /// Chip label joins terms with `\u{00A0}+\u{00A0}` (non-breaking
    /// spaces around the plus sign) so the chip width doesn't break
    /// awkwardly mid-set at smaller widths.
    static func recallChipLabel(terms: [String]) -> String {
        terms.joined(separator: "\u{00A0}+\u{00A0}")
    }

    /// Spelled-out accessibility label for the recall chip; uses
    /// "and" between terms for VoiceOver pacing.
    static func recallChipAccessibilityLabel(terms: [String]) -> String {
        let joined = terms.joined(separator: " and ")
        return "Recall recent search: \(joined)"
    }

    /// Accessibility prefix used for text/regex recent-query recall chips
    /// The chip label itself is `.privacySensitive()`
    /// but the prefix is combined into the accessibility label so
    /// VoiceOver names the action.
    static let queryRecallAccessibilityPrefix = "Recall recent search"

    // MARK: Filtered-out state

    static let filteredOutHeadline = "No results match current filters"
    static let filteredOutDescription = "Your active filters hide all candidates. Adjust source, confidence, or category filters to see results."
}
