import SwiftUI
import RedactionEngine

// Results list + empty / filtered-out states +
// row helpers + live preview row + scope picker + keyboard shortcuts.
// Lifted from `SearchAndRedactSheet.swift`; behavior unchanged.
// The "Add to selection" predicate Menu moved out
// of the results-header zone into `SearchFooterSection`, the surface's
// single selection authority; it was later removed entirely —
// selection is per row or the footer's Select All.

struct SearchResultsSection: View {
    @Bindable var searchState: SearchState
    @Environment(DocumentState.self) private var documentState
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
    /// Result navigation is ONE seam on the hub (`focusWalk(on:parking:)`,
    /// `+Walk.swift`) — the row tap and the J/K keyboard buttons call
    /// back through this with the result id instead of a section-side
    /// copy of the page write + scroll request + detent rule. The Bool
    /// is the seam's `parking` — J/K pass `false` (the list stays
    /// readable while a keyboard user steps: large → medium only); the
    /// row tap, like the hub's chevrons / ⌘G, passes `true` and parks
    /// the sheet at the compact float.
    let onFocusWalk: (UUID, Bool) -> Void

    /// Anchored-row contract — when
    /// tap-on-row drops the sheet to compact, the row the user tapped
    /// must remain topmost in the (much shorter) results list. The tap
    /// handler writes `result.id` here; an `.onChange` on the wrapping
    /// `ScrollViewReader` consumes the value and routes it through
    /// `proxy.scrollTo(_:anchor:)` then resets to nil so the same row
    /// can be re-anchored later.
    @State private var pendingAnchorID: UUID?

    /// Reduce Motion gate for any animation introduced
    /// by the saturation banner (currently a no-op — the banner appears
    /// inside the existing show/hide branching of `livePreviewRow`).
    /// Threaded through so future per-button feedback stays guarded.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // When results render, the List is the section's
        // root and the section's own fixed chrome rides its top
        // safe-area inset (under the hub's sheet-chrome inset), so
        // the List's UIKit frame binds at the sheet top for
        // cooperative scroll↔detent arbitration (chrome
        // HEIGHT above the list unbinds it, not chrome species). The
        // empty / in-flight / filtered-out states keep plain stacked
        // chrome — nothing scrolls there.
        Group {
            if searchState.searchModeType == .piiScan
                && searchState.results.isEmpty
                && searchState.isSearching {
                // Scan in flight, nothing yet to list: an auto-run
                // starts before the user has seen any result, so the
                // surface names what is happening instead of rendering
                // a blank list. The toolbar's progress row above
                // carries the page/count numbers — this state
                // deliberately repeats none of them.
                VStack(spacing: 0) {
                    sectionTopChrome
                    scanInFlightState
                }
            } else if searchState.results.isEmpty && !searchState.isSearching {
                VStack(spacing: 0) {
                    sectionTopChrome
                    emptyState
                }
            } else if searchState.filteredCount == 0 && !searchState.results.isEmpty && !searchState.isSearching {
                VStack(spacing: 0) {
                    sectionTopChrome
                    filteredOutState
                }
            } else {
                resultsList
                    .safeAreaInset(edge: .top, spacing: 0) {
                        sectionTopChrome
                    }
            }
        }
        .background { keyboardShortcutButtons }
    }

    /// Everything that used to sit above the results list as fixed
    /// VStack chrome — banners, live preview, Select-Where — riding
    /// the list's top safe-area inset under the hub's sheet chrome.
    /// Opaque background — rows scroll UNDER
    /// the inset region.
    private var sectionTopChrome: some View {
        VStack(spacing: 0) {
            // Per-page regex-timeout banner. Surfaces
            // when `DocumentSearcher`'s timeout sink fired for one or more
            // pages during the active scan. Copy NEVER echoes pattern text —
            // only generic active-pattern phrasing — so a
            // pasted PII-like regex can't leak via the banner.
            if !searchState.regexTimeoutPages.isEmpty {
                SearchRegexTimeoutBanner(searchState: searchState)
            }

            // Per-page OCR-skip banner. Surfaces when
            // `DocumentSearcher`'s OCR-skip sink fired for one or more
            // pages during the active scan: those pages exceeded the OCR
            // pixel caps, so their image content was never text-scanned.
            if !searchState.ocrSkippedPages.isEmpty {
                SearchOCRSkipBanner(searchState: searchState)
            }

            // Live preview row (counts + saturation/invalid signal).
            livePreviewRow

            // The "Add to selection" Menu that closed
            // this stack now rides the footer beside Select All — the
            // freed full-width row returns to the results viewport.
        }
        .background(.background)
    }

    // MARK: - Live Preview Row

    @ViewBuilder
    private var livePreviewRow: some View {
        if !searchState.queryText.isEmpty,
           searchState.searchModeType != .piiScan,
           let preview = searchState.livePreview {
            if preview.saturated {
                SearchSaturationBanner(searchState: searchState, onTriggerSearch: onTriggerSearch)
            } else {
                HStack(spacing: ResectaTokens.Spacing.xs) {
                    if preview.regexInvalid {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        // Small error TEXT routes through the
                        // measured text tier; the glyph above stays on
                        // the system-color tier.
                        Text("Regex: invalid")
                            .font(.caption)
                            .foregroundStyle(ResectaTokens.SemanticColor.failText)
                    } else {
                        Image(systemName: "eye")
                            .foregroundStyle(.secondary)
                        Text(Self.previewCountLine(
                            pageMatches: preview.currentPageMatches.count,
                            committedTotal: searchState.hasCompletedRunSinceClear
                                ? searchState.totalCount : nil))
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

    /// The live preview is page-scoped, so its
    /// `totalCount` ≡ the current-page count and the former
    /// "Total: \(preview.totalCount)" contradicted the footer on any
    /// multi-page-match query ("Matches this page: 1 · Total: 1" beside
    /// "3 found"). The document-wide total belongs to the committed
    /// full search: render it only when a committed run exists; the
    /// honest page count stands alone otherwise.
    static func previewCountLine(pageMatches: Int, committedTotal: Int?) -> String {
        var line = "Matches this page: \(pageMatches)"
        if let committedTotal {
            line += " \u{00B7} Total: \(committedTotal)"
        }
        return line
    }

    // MARK: - Keyboard Shortcuts (J / K / Space / Return)

    /// Mirrors the Cmd+G hidden-Button pattern at the search-bar level —
    /// invisible buttons whose `.keyboardShortcut(...)` is what the
    /// hardware keyboard activates. iPhone (no keyboard) renders nothing.
    private var keyboardShortcutButtons: some View {
        Group {
            Button {
                searchState.walkToPrevious(fromPage: documentState.currentPageIndex)
                if let id = searchState.currentResult?.id { onFocusWalk(id, false) }
            } label: { EmptyView() }
                .accessibilityLabel("Previous match")
                .keyboardShortcut("j", modifiers: [])

            Button {
                searchState.walkToNext(fromPage: documentState.currentPageIndex)
                if let id = searchState.currentResult?.id { onFocusWalk(id, false) }
            } label: { EmptyView() }
                .accessibilityLabel("Next match")
                .keyboardShortcut("k", modifiers: [])

            Button {
                searchState.toggleSelectionForCurrentMatch()
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
                            Section {
                                ForEach(termResults) { result in
                                    // By-term sections are
                                    // the one page-UNSECTIONED list, so the
                                    // rows carry the page label here.
                                    resultRow(for: result, showTermLabel: false, showsPageLabel: true)
                                }
                            } header: {
                                // The header echoes the term the user typed.
                                Text("\"\(term)\" — \(termResults.count) match\(termResults.count == 1 ? "" : "es")\(conjunctionSuffix)")
                                    .privacySensitive()
                            }
                        }
                    }
                } else {
                    // Default: Group by page. Every `ResultSortOrder`
                    // keeps these page sections (`resultsByPage` groups
                    // the sorted list by page), so the section header
                    // carries the page and no row shows `p.N`.
                    let pages = searchState.resultsByPage.keys.sorted()
                    ForEach(pages, id: \.self) { page in
                        Section("Page \(page + 1)") {
                            if let pageResults = searchState.resultsByPage[page] {
                                ForEach(pageResults) { result in
                                    resultRow(for: result, showTermLabel: isMultiTerm, showsPageLabel: false)
                                }
                            }
                        }
                    }
                }
            }
        .listStyle(.plain)
        // Stable handle for the cooperative-arbitration XCUI
        // pins' in-list drags — the results-list sibling of
        // `scanReviewList`.
        .accessibilityIdentifier("searchResultsList")
        .onChange(of: pendingAnchorID, initial: false) { (_: UUID?, newID: UUID?) in
            anchorTappedRow(newID: newID, proxy: proxy)
        }
        // The list FOLLOWS the walk — every
        // step of the current result (chevron / ⌘G / J/K) re-anchors
        // the current row at the top, the way the row tap does. The
        // row-tap path writes the same id in the same tick, so the
        // consumer above fires once (harmless).
        .onChange(of: searchState.currentResult?.id, initial: false) { (_: UUID?, newID: UUID?) in
            if let newID { pendingAnchorID = newID }
        }
        // The section is UNMOUNTED at the compact float (the sheet
        // body renders only the handle) and re-instantiated on expand
        // with fresh @State — anchoring on appear is what makes
        // "grabber-up lands on the current row" true.
        .onAppear {
            if let id = searchState.currentResult?.id { pendingAnchorID = id }
        }

        inner
            // At the medium detent the list's viewport
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
    /// conditional-dismiss touched tracker. The get routes
    /// through `SearchState.result(for:)` — O(1) via the version-keyed
    /// index map instead of the former per-call linear scan (re-hit
    /// several times per row body); removed-id and fallback semantics
    /// are unchanged.
    private func safeBinding(for id: UUID, fallback: SearchResult) -> Binding<SearchResult> {
        Binding(
            get: {
                searchState.result(for: id) ?? fallback
            },
            set: { _ in
                searchState.toggleSelection(for: id)
            }
        )
    }

    @ViewBuilder
    private func resultRow(
        for result: SearchResult,
        showTermLabel: Bool,
        showsPageLabel: Bool
    ) -> some View {
        let row = SearchResultRow(
            result: safeBinding(for: result.id, fallback: result),
            isCurrent: searchState.currentResult?.id == result.id,
            isApplied: searchState.appliedResultIDs.contains(result.id),
            showTermLabel: showTermLabel,
            showsPageLabel: showsPageLabel,
            // OCR rows grade against the live OCR floor; PII rows use
            // the shared absolute bands (the dormant per-run threshold
            // input retired with the row-family unification).
            ocrFloor: searchState.minimumOCRConfidence,
            // Regex source-capsule gate — mode + rationale signal.
            searchMode: searchState.searchModeType,
            onNavigate: {
                // The tap routes through the hub's one walk seam
                // (index write · page write · centred readability
                // framing · the compact drop, so the PDF gets max
                // area). Set `pendingAnchorID` BEFORE the seam's detent
                // transition fires so the `.onChange` on `resultsList`'s
                // ScrollViewReader proxy snaps the tapped row to the top.
                pendingAnchorID = result.id
                onFocusWalk(result.id, true)
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
    }

    // MARK: - Empty State
    //
    // Mode-specific actionable copy. Mechanism-description
    // discipline. The pre-scan / post-scan-zero / pre-search /
    // no-match / no-recents discriminator drives the headline,
    // description, and (multi-term only) recall-chip surface.
    // `SearchEmptyStateCopy` static functions are mechanism-description
    // copy. Outcome promises (e.g., "no PII found",
    // "all clear") are forbidden.

    private var emptyState: some View {
        let context = currentEmptyStateContext()
        return ContentUnavailableView {
            Label(
                SearchEmptyStateCopy.headline(for: context),
                systemImage: SearchEmptyStateCopy.headlineSymbol(for: context)
            )
        } description: {
            VStack(alignment: .center, spacing: ResectaTokens.Spacing.sm) {
                // Interface-level role line for the Search side,
                // above the per-mode caption. The Scan side's role
                // sentence lives inside its description string.
                if SearchEmptyStateCopy.showsSearchRoleSubtitle(for: context) {
                    Text(SearchEmptyStateCopy.searchRoleSubtitle)
                }
                // Markdown-bold markers only parse through the
                // LocalizedStringKey overload of `Text(_:)`; a plain
                // String variable hits the verbatim overload and renders
                // the asterisks literally (screenshot evidence) — the
                // explicit `.init` routes back to the markdown-aware path.
                Text(.init(SearchEmptyStateCopy.description(for: context)))
                if context == .multiTermPreSearchWithRecents {
                    multiTermRecallChips
                }
            }
        } actions: {
            // Failed-start recovery: the retry lives here as an inline
            // action, since the copy no longer names any other control.
            if context == .piiScanStartFailed {
                scanAgainButton
            }
        }
    }

    /// Inline retry for the failed-start state. Routes through the
    /// same trigger as the chips-row re-run control. The in-flight
    /// belt mirrors that control's gate; structurally this state only
    /// renders while no run is in flight.
    private var scanAgainButton: some View {
        Button {
            onTriggerSearch()
        } label: {
            Label("Scan Again", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.borderedProminent)
        .disabled(searchState.isSearching)
    }

    /// Scan-run in-flight surface — rendered in place of the results
    /// list while a Scan-interface run has produced nothing to list
    /// yet. Carries the interface's role sentence (its primary home:
    /// read exactly while the user waits); the vestigial pre-scan
    /// state keeps the same sentence as residue. Page/count numbers
    /// stay on the toolbar's progress row alone.
    private var scanInFlightState: some View {
        ContentUnavailableView {
            Label(SearchEmptyStateCopy.scanInFlightHeadline, systemImage: "doc.viewfinder")
        } description: {
            VStack(alignment: .center, spacing: ResectaTokens.Spacing.sm) {
                Text(SearchEmptyStateCopy.piiScanRoleSentence)
                ProgressView()
            }
        }
    }

    /// The per-mode discriminator from the current SearchState shape —
    /// the session's own read (`SearchState.emptyStateContext`, shared
    /// with the parked strip's status line). Pure — pinned by
    /// EmptyStateTests so the discriminator stays in sync with the
    /// copy table.
    private func currentEmptyStateContext() -> SearchEmptyStateCopy.EmptyContext {
        searchState.emptyStateContext
    }

    /// Tappable recall chips for the multi-term empty state.
    /// Each chip displays the term set joined with " + "; tap restores
    /// `searchState.searchTerms` to that set and re-triggers via
    /// `onTriggerSearch`.
    private var multiTermRecallChips: some View {
        VStack(alignment: .center, spacing: ResectaTokens.Spacing.xs) {
            Text(SearchEmptyStateCopy.recentSearchesHeader)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: ResectaTokens.Spacing.xs) {
                ForEach(Array(searchState.recentMultiTermSets.enumerated()), id: \.offset) { _, recall in
                    Button {
                        searchState.searchTerms = recall
                        onTriggerSearch()
                    } label: {
                        Text(SearchEmptyStateCopy.recallChipLabel(terms: recall))
                            .font(.caption2)
                            .lineLimit(1)
                            // The recalled terms are the user's own query text.
                            .privacySensitive()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(
                        SearchEmptyStateCopy.recallChipAccessibilityLabel(terms: recall)
                    )
                }
            }
        }
    }

    // MARK: - Filtered Out State

    /// Clears every filter that can hide a result row: the source, the
    /// OCR confidence floor, the category chips and the applied state.
    static func showAll(on searchState: SearchState) {
        searchState.sourceFilter = .all
        searchState.minimumOCRConfidence = 0
        searchState.piiCategoryFilter = nil
        searchState.appliedFilter = .all
    }

    private var filteredOutState: some View {
        ContentUnavailableView {
            Label(
                SearchEmptyStateCopy.filteredOutHeadline,
                systemImage: "line.3.horizontal.decrease.circle"
            )
        } description: {
            Text(SearchEmptyStateCopy.filteredOutDescription)
        } actions: {
            Button(SearchEmptyStateCopy.showAllButton) {
                Self.showAll(on: searchState)
            }
        }
    }
}
