import SwiftUI
import RedactionEngine

// Per-interface option blocks under the two-interface chassis:
// Search side = mode picker (Text/Regex/Multi-term via
// `SearchModeContainer`) + standard options; Scan side = pre-scan
// category chips + OCR options (no mode picker). Plus post-scan
// PII category filter chips, multi-term chip list, and live
// progress / count display.
// Lifted from `SearchAndRedactSheet.swift`.
//
// Case/whole-word/OCR toggles wrap in a
// `DisclosureGroup("Options")` collapsed by default (Hybrid
// IA). OCR slider + source filter visibility now follows
// `searchState.options.includeOCR` (was `hasOCRResults`); disabled with
// "Awaiting OCR results" caption when Include OCR is on but no OCR
// results have arrived yet. Post-scan filter chips moved
// into a single chip-row substrate (`chipRowSubstrate`) — the
// integration point for downstream chip-adding work.
// The chip-row substrate gains an applied-state
// filter chip (All / Applied / Unapplied) that mounts after the PII
// category chips inside the same `chipRowSubstrate` HStack.
// The sort `Menu` migrates from
// `SearchFooterSection` to a chip-row consumer in
// `chipRowSubstrate`. Footer drops the Menu; the chip surfaces
// whenever results exist (any mode) and tints accent when the user
// has departed from the default `.discoveryOrder`.

struct SearchToolbarSection: View {
    @Bindable var searchState: SearchState
    @Environment(SavedRegexStore.self) private var savedRegexStore
    // UXF-14 — per-page text-layer classification feeds the disabled-OCR
    // caption: when no page classifies `.sparse`/`.none`, no OCR leg will
    // run and "Awaiting OCR results" would promise something that never
    // arrives.
    @Environment(DocumentState.self) private var documentState
    @Binding var duplicateTermMessage: String?
    let onTriggerSearch: () -> Void
    /// UXF-04: "Save current..." requests the naming prompt from the
    /// hosting sheet. The demonstrated no-op had two parts: the menu
    /// item was ordered after the 10 built-ins, which pushes it past
    /// the top of the screen where it draws clipped and taps never
    /// land (fixed by ordering it first, nearest the menu anchor); and
    /// the naming alert now lives at the sheet root instead of on this
    /// section's VStack.
    let onRequestSaveCurrentRegex: () -> Void

    // Initialized to `optionsCollapsedByDefault` (false). The
    // contract is pinned by `SearchToolbarSectionTests`.
    @State private var optionsExpanded: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: ResectaTokens.Spacing.xs) {
            if searchState.searchModeType == .piiScan {
                // Scan interface: no mode picker — category chips +
                // OCR options (the mode picker is a Search-side
                // second-level control).
                scanOptions
            } else {
                // Search interface: mode picker + standard options
                // for text/regex/multi-term.
                SearchModeContainer(searchState: searchState)
                standardSearchOptions
            }

            // Chip-row substrate. Future chip groups append chips here
            // without re-architecting the surface.
            if anyChipsToShow {
                chipRowSubstrate
            }

            // Progress + live result count
            if searchState.isSearching {
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
        }
        .padding(.vertical, ResectaTokens.Spacing.xs)
        // The "Save current..." naming alert moved to the sheet root
        // (`SearchAndRedactSheet`) — see `onRequestSaveCurrentRegex`.
    }

    // MARK: - Standard Search Options

    private var standardSearchOptions: some View {
        VStack(spacing: ResectaTokens.Spacing.xs) {
            // Option toggles wrapped in a collapsible disclosure.
            // Disclosure animation respects Reduce Motion via
            // `Anim.resolved(_:reduceMotion:)`.
            DisclosureGroup("Options", isExpanded: $optionsExpanded) {
                HStack(spacing: ResectaTokens.Spacing.md) {
                    Toggle("Case Sensitive", isOn: $searchState.options.caseSensitive)
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .accessibilityLabel("Case sensitive search")

                    Toggle("Whole Word", isOn: $searchState.options.wholeWord)
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .accessibilityLabel("Whole word matching")

                    Toggle("Include OCR", isOn: $searchState.options.includeOCR)
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .accessibilityLabel("Include scanned page text")

                    Spacer()
                }
                .padding(.top, ResectaTokens.Spacing.xs)

                // Normalization extensions row.
                // The two length-changing options are hidden in regex
                // mode: the engine excludes them there (a transformed
                // pattern changes meaning; see SearchOptions), so a
                // visible-but-inert toggle would misstate the mechanism.
                HStack(spacing: ResectaTokens.Spacing.md) {
                    if searchState.searchModeType != .regex {
                        Toggle("Ignore digit separators", isOn: $searchState.options.stripDigitSeparators)
                            .toggleStyle(.button)
                            .controlSize(.small)
                            .accessibilityLabel("Ignore digit separators")
                            .accessibilityHint("Matches 123456789 when the document has 123-45-6789")
                    }

                    Toggle("Normalize quotes and dashes", isOn: $searchState.options.normalizeSmartPunctuation)
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .accessibilityLabel("Normalize quotes and dashes")
                        .accessibilityHint("Treats curly quotes and em-dashes as their plain equivalents")

                    if searchState.searchModeType != .regex {
                        Toggle("Match regardless of accents", isOn: $searchState.options.foldDiacritics)
                            .toggleStyle(.button)
                            .controlSize(.small)
                            .accessibilityLabel("Match regardless of accents")
                            .accessibilityHint("Matches Munoz when the document has Muñoz")
                    }

                    Spacer()
                }
                .padding(.top, ResectaTokens.Spacing.xs)
            }
            .padding(.horizontal, ResectaTokens.Spacing.md)
            .animation(
                ResectaTokens.Anim.resolved(ResectaTokens.Anim.stateChange, reduceMotion: reduceMotion),
                value: optionsExpanded
            )

            // Source filter + OCR confidence threshold. Visible
            // whenever the user has Include OCR on;
            // disabled with caption when no OCR results have arrived yet.
            // Extracted into `ocrControlsRow` so PII Scan mode
            // reuses the same component.
            ocrControlsRow

            // Page-level conjunction toggle. OR is
            // the historical default; flipping re-triggers so the result
            // list reflects the new combination immediately. The re-run
            // fires from the toggle's own set (a user gesture) rather
            // than from value observation: the conjunction now round-trips
            // through saved searches, and an observation-based re-trigger
            // would fire a duplicate scan alongside a recall's own
            // trigger whenever the recalled value differs.
            if searchState.searchModeType == .multiTerm {
                HStack {
                    Toggle("All terms must match", isOn: Binding(
                        get: { searchState.options.multiTermConjunction },
                        set: { newValue in
                            searchState.options.multiTermConjunction = newValue
                            if !searchState.searchTerms.isEmpty {
                                onTriggerSearch()
                            }
                        }
                    ))
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .accessibilityLabel("All terms must match")
                        .accessibilityHint("When enabled, results come only from pages where every term has a match")
                    Spacer()
                }
                .padding(.horizontal, ResectaTokens.Spacing.md)
            }

            // Multi-term chips
            if searchState.searchModeType == .multiTerm && !searchState.searchTerms.isEmpty {
                multiTermChips
            }

            // Duplicate term feedback (auto-clears after 2s)
            if let msg = duplicateTermMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, ResectaTokens.Spacing.md)
                    .transition(.opacity)
                    .onAppear {
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            duplicateTermMessage = nil
                        }
                    }
            }

            // Regex warning + saved-regex menu
            if searchState.searchModeType == .regex {
                HStack(spacing: ResectaTokens.Spacing.xs) {
                    savedRegexMenu
                    Text("Regex patterns can match unintended text. Review all matches before redacting.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                }
                .padding(.horizontal, ResectaTokens.Spacing.md)
            }

            // Fixed-layout regex error callout.
            // Container is always rendered in regex mode at the
            // `regexErrorCalloutMinHeight` floor so the toolbar
            // height does not reflow when the engine flips
            // `searchState.regexError` between nil and a string. The
            // error contents fade via `.opacity` rather than via
            // conditional `if let`, keeping the search field +
            // chip-row geometry stable while the user types an
            // invalid pattern. Predicate + height live on
            // `SearchToolbarSection+Contracts.swift` so the layout
            // contract is unit-tested.
            if searchState.searchModeType == .regex {
                regexErrorCallout
            }

            // Short term warning
            if searchState.queryText.count > 0 && searchState.queryText.count < 3
                && searchState.searchModeType != .multiTerm {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("Short terms may produce many results.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Search Anyway") {
                        onTriggerSearch()
                    }
                    .controlSize(.small)
                    // Same in-flight gate as every other trigger control
                    // in this sheet; rapid re-taps must not race a
                    // second setup past the not-yet-assigned task.
                    .disabled(searchState.isSearching)
                }
                .padding(.horizontal, ResectaTokens.Spacing.md)
            }
        }
    }

    // MARK: - Regex Error Callout

    /// Fixed-layout error surface for the regex validation path. The
    /// container is always allocated when the user is in regex mode so
    /// the toolbar height stays put as `searchState.regexError` flips
    /// between nil and a message — `.opacity` drives visibility and
    /// VoiceOver gating instead of `if let` presence/absence. Reuses
    /// the standard `.systemRed` semantic color so the callout reads
    /// consistently with iOS form-validation conventions.
    private var regexErrorCallout: some View {
        let error = searchState.regexError
        let visible = Self.regexErrorCalloutShouldShow(error: error)
        return HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(error ?? "")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, ResectaTokens.Spacing.md)
        .frame(minHeight: Self.regexErrorCalloutMinHeight, alignment: .leading)
        .opacity(visible ? 1 : 0)
        // The callout surfaces the engine's
        // verbatim NSError text, which can echo fragments of the
        // submitted pattern — and the pattern may itself be PII.
        .privacySensitive()
        .accessibilityHidden(!visible)
        .accessibilityLabel(visible ? "Regex error: \(error ?? "")" : "")
        .animation(
            ResectaTokens.Anim.resolved(ResectaTokens.Anim.stateChange, reduceMotion: reduceMotion),
            value: visible
        )
    }

    // MARK: - Scan Options

    private var scanOptions: some View {
        VStack(spacing: ResectaTokens.Spacing.xs) {
            // The role subtitle moved from here into
            // the pre-scan empty state
            // (`WU20Strings.description(for: .piiScanPreScan)`).
            //
            // The per-run Confidence slider that lived here is retired:
            // Settings' Detection Sensitivity preset is the one
            // engine-level control, and the confidence sort +
            // Select-where ≥75/≥90 predicates are the review-side
            // confidence tools.

            // Category chips — pre-scan detector selection over
            // `enabledPIICategories` — plus the trailing re-run
            // affordance. Toggling narrows the NEXT run; runs stay
            // trigger-driven (no auto re-run on chip change).
            scanChipsRow

            // An empty selection means the next run scans everything —
            // say so where the chips would otherwise read as "nothing".
            if searchState.enabledPIICategories.isEmpty {
                HStack {
                    Text("No categories selected \u{2014} the next scan runs all detectors.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, ResectaTokens.Spacing.md)
            }

            // The whole OCR block (toggle + controls row) renders
            // only when a page can actually route to OCR; on all-`.rich`
            // documents the engine never runs OCR, so the controls carry
            // no information there. Fail-open on an unknown map.
            if Self.piiScanOCRBlockShouldShow(
                anyPageAwaitsOCR: documentState.textLayerStatus.values
                    .contains { $0 != .rich },
                statusKnown: !documentState.textLayerStatus.isEmpty
            ) {
                // Include OCR toggle for the scan run
                HStack {
                    Toggle("Include OCR Pages", isOn: $searchState.options.includeOCR)
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .accessibilityLabel("Include scanned page text")
                    Spacer()
                }
                .padding(.horizontal, ResectaTokens.Spacing.md)

                // Mirror the source-filter + OCR
                // confidence slider into the Scan interface. Reuses
                // the same `ocrControlsRow` component so the gating helpers
                // (`ocrControlsShouldShow`, `ocrSliderShouldBeDisabled`,
                // `awaitingOCRResultsCaption`) stay canonical across modes.
                ocrControlsRow
            }
        }
    }

    // MARK: - Scan Category Chips (pre-scan selection)

    /// Chips row: the scrolling category chips plus the compact re-run
    /// button pinned at the trailing edge (chips scroll beside it).
    /// The re-run affordance replaces the retired persistent
    /// "Scan Document" capsule — entry auto-run is how scans start;
    /// this button covers re-running after narrowing categories.
    private var scanChipsRow: some View {
        HStack(spacing: 0) {
            scanCategoryChips
            rescanButton
                .padding(.trailing, ResectaTokens.Spacing.md)
        }
    }

    /// Compact re-run control for the Scan interface. Inherits the
    /// retired run button's accessibility label — the stable-label
    /// policy: existing UI-test queries and VoiceOver habits keep
    /// resolving to the surface's one run control.
    private var rescanButton: some View {
        Button {
            onTriggerSearch()
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        // An empty chip selection does not disable the run — it means
        // scan everything (`effectiveScanCategories`).
        .disabled(searchState.isSearching)
        .accessibilityLabel("Scan document for PII")
    }

    /// Pre-scan detector-selection chips over the full category set.
    /// Distinct from `piiCategoryFilterChips` (post-scan result
    /// filtering): these choose what the NEXT run requests. Toggling
    /// routes through the chip's action (a user gesture) — never
    /// value observation — and deliberately does NOT re-trigger the
    /// scan; runs stay trigger-driven. Rendered through `FilterChip`
    /// (the one chip component), category-tinted.
    private var scanCategoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ResectaTokens.Spacing.xs) {
                ForEach(PIICategory.allCases, id: \.self) { category in
                    let isEnabled = searchState.enabledPIICategories.contains(category)
                    FilterChip(
                        label: category.rawValue,
                        systemImage: category.symbolName,
                        tint: SearchResultRow.categoryColor(category),
                        isSelected: isEnabled
                    ) {
                        if isEnabled {
                            searchState.enabledPIICategories.remove(category)
                        } else {
                            searchState.enabledPIICategories.insert(category)
                        }
                    }
                    .accessibilityLabel("\(category.rawValue) detector")
                    .accessibilityValue(isEnabled ? "enabled" : "disabled")
                    .accessibilityHint("Applies to the next scan")
                }
            }
            .padding(.horizontal, ResectaTokens.Spacing.md)
        }
        .accessibilityIdentifier("scanCategoryChips")
    }

    // MARK: - OCR Controls (shared by standardSearchOptions + piiScanOptions)

    /// Shared source filter + OCR confidence slider.
    /// Visibility gate via `ocrControlsShouldShow(includeOCR:)`; disabled
    /// state via `ocrSliderShouldBeDisabled(hasOCRResults:)`. Caption
    /// text comes from `awaitingOCRResultsCaption`. Used by both
    /// `standardSearchOptions` (text/regex/multi-term) and
    /// `piiScanOptions` (PII Scan).
    @ViewBuilder
    private var ocrControlsRow: some View {
        if Self.ocrControlsShouldShow(includeOCR: searchState.options.includeOCR) {
            let isDisabled = Self.ocrSliderShouldBeDisabled(
                hasOCRResults: searchState.hasOCRResults
            )
            HStack(spacing: ResectaTokens.Spacing.md) {
                Picker("Source", selection: $searchState.sourceFilter) {
                    ForEach(SourceFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Filter by source")

                if searchState.sourceFilter != .textOnly {
                    HStack(spacing: 4) {
                        Text("OCR ≥\(Int(searchState.minimumOCRConfidence * 100))%")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .trailing)
                        Slider(value: $searchState.minimumOCRConfidence, in: 0...1, step: 0.05)
                            .frame(maxWidth: 120)
                            .accessibilityLabel("Minimum OCR confidence")
                    }
                }
            }
            .padding(.horizontal, ResectaTokens.Spacing.md)
            .disabled(isDisabled)

            if isDisabled {
                // UXF-14 — the caption is conditional: "awaiting" only
                // when at least one page will actually route to OCR.
                let caption = Self.ocrDisabledCaption(
                    anyPageAwaitsOCR: documentState.textLayerStatus.values
                        .contains { $0 != .rich }
                )
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, ResectaTokens.Spacing.md)
                    // The caption is a full sentence that may open with
                    // an acronym ("OCR not needed …") — lowercasing it
                    // produced "ocr not needed" in the spoken label.
                    .accessibilityLabel("OCR controls disabled: \(caption)")
            }
        }
    }

    // MARK: - Chip-Row Substrate

    /// Whether any chip group has content to render. Each chip group's
    /// gate stays specific so future chip groups append OR-clauses without
    /// destabilizing the substrate.
    private var anyChipsToShow: Bool {
        // PII category chips — gate on hasPIIResults.
        // Applied filter chip — gate on any results landing.
        searchState.hasPIIResults
            || !searchState.results.isEmpty
    }

    /// Single horizontally-scrolling row hosting all post-scan filter
    /// chips. Established as the integration substrate;
    /// downstream additions append chip groups inside the inner
    /// HStack without altering the substrate's shape.
    ///
    /// Visual order:
    /// - PII category filter chips (post-scan, PII Scan mode)
    /// - Applied-only filter chip (post-scan, all modes)
    /// - Sort header chip (post-scan, all modes)
    /// - Profile-thresholds chip (pending)
    /// - Saturation-scope chip (pending)
    /// - Selective PII chips stay in `piiScanOptions` (pre-scan disclosure)
    private var chipRowSubstrate: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ResectaTokens.Spacing.xs) {
                if searchState.hasPIIResults {
                    piiCategoryFilterChips
                }
                if !searchState.results.isEmpty {
                    // The applied-state chip renders only once it
                    // can do something: after the first apply, or while a
                    // non-default filter is active (so an active filter
                    // can never strand invisibly). Kills the
                    // double-"All" chip row pre-apply. Sort chip's
                    // visibility is unchanged.
                    if Self.appliedFilterChipShouldShow(
                        hasAppliedResults: !searchState.appliedResultIDs.isEmpty,
                        activeFilter: searchState.appliedFilter
                    ) {
                        appliedFilterChip
                    }
                    sortChip
                }
                // Downstream chip groups inserted here.
            }
            .padding(.horizontal, ResectaTokens.Spacing.md)
        }
    }

    // MARK: - Applied Filter Chip

    /// Applied-state filter chip — `Menu` styled to match the existing
    /// substrate capsules (PII category chips). Tapping a Menu option
    /// drives `searchState.appliedFilter`; the field's `didSet` invokes
    /// `invalidateFilterCaches()` so `filteredResults` recomputes on
    /// next read. Capsule renders accent-tinted whenever a non-`.all`
    /// state is active. Strings classified SAFE.
    @ViewBuilder
    private var appliedFilterChip: some View {
        let active = searchState.appliedFilter
        let isFiltered = active != .all
        Menu {
            ForEach(AppliedFilter.allCases, id: \.self) { state in
                Button {
                    searchState.appliedFilter = state
                } label: {
                    if active == state {
                        Label(state.rawValue, systemImage: "checkmark")
                    } else {
                        Text(state.rawValue)
                    }
                }
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "checkmark.circle")
                    .font(.caption2)
                Text(active.rawValue)
                    .font(.caption2)
            }
            .padding(.horizontal, ResectaTokens.Spacing.sm)
            .padding(.vertical, ResectaTokens.Spacing.xxs)
            .background(isFiltered ? ResectaTokens.BrandTeal.tint.opacity(0.2) : Color.clear, in: Capsule())
            .overlay(Capsule().strokeBorder(isFiltered ? ResectaTokens.BrandTeal.tint : Color.secondary.opacity(0.3)))
        }
        .accessibilityLabel(Self.appliedFilterChipAccessibilityLabel(active: active))
    }

    // MARK: - Sort Chip

    /// Sort chip — `Menu` styled to match the chip-row substrate
    /// capsules. Was a `Menu` inside `SearchFooterSection` previously;
    /// migrating here puts the active sort next to the active filter
    /// chips at the top of the result list. The chip's binding sets
    /// `searchState.sortOrder` directly; the field's existing `didSet`
    /// invalidates filter caches so `filteredResults` recomputes with
    /// the new sort. Capsule renders accent-tinted whenever the user
    /// has departed from the default `.discoveryOrder`. Sort labels
    /// come from the existing `ResultSortOrder` rawValues — no new
    /// strings introduced.
    @ViewBuilder
    private var sortChip: some View {
        let active = searchState.sortOrder
        let isCustomSort = active != .discoveryOrder
        Menu {
            ForEach(ResultSortOrder.allCases, id: \.self) { order in
                Button {
                    searchState.sortOrder = order
                } label: {
                    if active == order {
                        Label(order.rawValue, systemImage: "checkmark")
                    } else {
                        Text(order.rawValue)
                    }
                }
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.caption2)
                Text(Self.sortChipLabel(active: active))
                    .font(.caption2)
            }
            .padding(.horizontal, ResectaTokens.Spacing.sm)
            .padding(.vertical, ResectaTokens.Spacing.xxs)
            .background(isCustomSort ? ResectaTokens.BrandTeal.tint.opacity(0.2) : Color.clear, in: Capsule())
            .overlay(Capsule().strokeBorder(isCustomSort ? ResectaTokens.BrandTeal.tint : Color.secondary.opacity(0.3)))
        }
        .accessibilityLabel(Self.sortChipAccessibilityLabel(active: active))
    }

    // MARK: - PII Category Filter Chips (Post-Scan)

    /// Chip group consumed by `chipRowSubstrate`. Returns the chip
    /// content only (no enclosing ScrollView) so future chip groups compose
    /// alongside it inside the substrate's single HStack. Rendered
    /// through `FilterChip` (the one chip component).
    @ViewBuilder
    private var piiCategoryFilterChips: some View {
        // "All" chip
        FilterChip(
            label: "All",
            isSelected: searchState.piiCategoryFilter == nil
        ) {
            searchState.piiCategoryFilter = nil
        }

        // Per-category chips with counts
        let counts = searchState.categoryCounts
        ForEach(PIICategory.allCases.filter { counts[$0] != nil }, id: \.self) { category in
            let count = counts[category] ?? 0
            let isActive = searchState.piiCategoryFilter?.contains(category) ?? true
            FilterChip(
                label: category.rawValue,
                // Show the count only when the user has narrowed the
                // filter; at the default "All" state the count
                // duplicates info already visible elsewhere.
                count: searchState.piiCategoryFilter != nil ? count : nil,
                systemImage: category.symbolName,
                tint: SearchResultRow.categoryColor(category),
                isSelected: isActive
            ) {
                if searchState.piiCategoryFilter == nil {
                    // Switch from "All" to single category
                    searchState.piiCategoryFilter = [category]
                } else if searchState.piiCategoryFilter?.contains(category) == true {
                    searchState.piiCategoryFilter?.remove(category)
                    if searchState.piiCategoryFilter?.isEmpty == true {
                        searchState.piiCategoryFilter = nil
                    }
                } else {
                    searchState.piiCategoryFilter?.insert(category)
                }
            }
            .accessibilityLabel("\(category.rawValue), \(count) match\(count == 1 ? "" : "es")")
        }
    }

    // MARK: - Multi-Term Chips

    private var multiTermChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ResectaTokens.Spacing.xs) {
                ForEach(searchState.searchTerms, id: \.self) { term in
                    let count = searchState.resultsByTerm[term]?.count ?? 0
                    HStack(spacing: 4) {
                        Text("\(term) (\(count))")
                            .font(.caption)
                            .monospacedDigit()
                            .privacySensitive()
                        Button {
                            searchState.searchTerms.removeAll { $0 == term }
                            onTriggerSearch()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .disabled(searchState.isSearching)
                    }
                    .padding(.horizontal, ResectaTokens.Spacing.sm)
                    .padding(.vertical, ResectaTokens.Spacing.xxs)
                    .background(.quaternary, in: Capsule())
                    .opacity(count == 0 ? 0.6 : 1.0)
                    .accessibilityLabel("\(term), \(count) match\(count == 1 ? "" : "es")")
                }
            }
            .padding(.horizontal, ResectaTokens.Spacing.md)
        }
    }

    // MARK: - Saved Regex Menu (Regex mode)

    /// Saved-regex inline menu. Shown next to the regex warning in
    /// Regex mode. Tapping a saved entry inserts its pattern into
    /// `searchState.queryText` (which fires the existing `.onChange`
    /// debounce on the regex `TextField`). "Save current..." renders
    /// FIRST (see the UXF-04 note on `onRequestSaveCurrentRegex`) and
    /// asks the hosting sheet to present the naming prompt; the sheet
    /// sentinel-validates and commits via
    /// `savedRegexStore.add(label:pattern:)`.
    @ViewBuilder
    private var savedRegexMenu: some View {
        let savedRegexes = savedRegexStore.regexes
        let savedCount = savedRegexStore.userSavedRegexes.count
        let canSave = Self.canSaveCurrentRegex(
            savedCount: savedCount,
            queryText: searchState.queryText
        )
        Menu {
            // UXF-04: "Save current..." goes FIRST so it renders nearest
            // the menu's bottom anchor. Placed after the built-ins
            // section it was the menu's top row, which overflows the
            // screen with 10+ saved entries — the row draws clipped
            // outside the menu container and taps on it never land
            // (the demonstrated silent no-op).
            Button {
                onRequestSaveCurrentRegex()
            } label: {
                Text(Self.saveCurrentRegexMenuItem)
            }
            .disabled(!canSave)
            // CL-QP1-07: say WHY "Save current..." is disabled at the
            // 100-entry cap instead of disabling silently (the library
            // view already surfaces the same message inline).
            if let capMessage = Self.savedRegexCapMessage(savedCount: savedCount) {
                Text(capMessage)
            }
            if !savedRegexes.isEmpty {
                Section(Self.savedRegexSectionHeader) {
                    ForEach(savedRegexes) { regex in
                        Button {
                            searchState.queryText = regex.pattern
                        } label: {
                            // Saved labels are user-typed or built-in
                            // localization keys; not document-derived,
                            // so `.privacySensitive()` would over-redact.
                            Text(SavedRegexLibraryView.displayLabel(for: regex))
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "doc.text.below.ecg")
                .imageScale(.medium)
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Saved regex menu")
    }
}

// Pure-function contracts (the toolbar's static helpers) live
// in `SearchToolbarSection+Contracts.swift` so this file stays under
// the M-6 700-LOC cap. Code extending the contracts edits the
// sibling file directly; the test pins reference `SearchToolbarSection.<name>`
// which Swift resolves across extensions in the same module.
