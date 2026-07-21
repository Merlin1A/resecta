import SwiftUI
import RedactionEngine

// Saved-searches recall UI. The store
// (`SavedSearchStore`) shipped in V1.0 with no consuming surface;
// this sheet adds list / recall / rename / delete / save affordances.
//
// The list is typed per interface: opened from the Search interface it
// lists text / regex / multi-term entries; opened from Scan it lists
// saved scans. One store and one file underneath — the partition is a
// read-side filter on each entry's persisted mode (whose wire value
// carries interface identity), so nothing migrates and capture stays
// interface-correct by construction (it saves the active shape).
//
// Presented through the hub's single `.sheet(item:)` slot as
// `SearchModal.savedSearches` (F-5 single-modal contract). The capture
// monitor arrives as a `let` per the 37b56c9 injection pattern — never an
// @Environment read inside a view that re-lays-out during sheet dismissal.

struct SavedSearchListSheet: View {
    let searchState: SearchState
    let captureMonitor: ScreenCaptureMonitor
    /// Hub-owned recall: applies the shape to `searchState`, triggers the
    /// search, and dismisses this sheet.
    let onRecall: (SavedSearch) -> Void

    @Environment(SavedSearchStore.self) private var savedSearchStore
    @Environment(\.dismiss) private var dismiss

    @State private var renameTarget: SavedSearch?
    @State private var renameText: String = ""
    @State private var showSavePrompt = false
    @State private var savePromptName: String = ""
    /// H-74 — collision feedback for the save / rename prompts. When
    /// the store rejects a duplicate name the alert re-presents with
    /// this message in place of its standard body (the UXF-04
    /// saved-regex prompt's proven re-present pattern).
    @State private var savePromptError: String?
    @State private var renameError: String?
    /// UXF-33 / ST-94: swipe-Delete asks for confirmation before the
    /// store removal (app-standard destructive-confirm idiom — same
    /// shape as Settings' Reset dialogs).
    @State private var deleteTarget: SavedSearch?

    /// The interface whose entries this list shows — the active one.
    /// Stable for the sheet's lifetime (no user path changes the
    /// interface while this modal is up).
    private var activeInterface: SearchInterface {
        searchState.searchModeType.interface
    }

    private var visibleSearches: [SavedSearch] {
        Self.visibleEntries(
            savedSearchStore.savedSearches, interface: activeInterface)
    }

    var body: some View {
        NavigationStack {
            List {
                if visibleSearches.isEmpty {
                    Section {
                        ContentUnavailableView(
                            Self.emptyStateTitle(for: activeInterface),
                            systemImage: "bookmark",
                            description: Text(Self.emptyStateDescription(for: activeInterface))
                        )
                        .listRowBackground(Color.clear)
                    }
                } else {
                    Section(Self.sectionHeader(for: activeInterface)) {
                        ForEach(visibleSearches) { search in
                            savedSearchRow(search)
                        }
                    }
                }

                // Save entry point — always visible while the sheet is open
                // (design §4.1), pre-filled with a generated name. Saves
                // the active interface's shape, so the new entry always
                // lands in the list the user is looking at.
                Section {
                    Button {
                        savePromptName = Self.generatedName(for: searchState)
                        savePromptError = nil
                        showSavePrompt = true
                    } label: {
                        Label(Self.saveCurrentLabel(for: activeInterface), systemImage: "plus.circle")
                    }
                    .accessibilityLabel(Self.saveCurrentLabel(for: activeInterface))
                }
            }
            .navigationTitle("Saved Searches")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Rename Saved Search", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            ), presenting: renameTarget) { search in
                TextField("Name", text: $renameText)
                Button("Rename") {
                    let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty,
                       !savedSearchStore.rename(id: search.id, to: trimmed) {
                        // H-74 — duplicate name: re-present with the
                        // collision message instead of dismissing.
                        renameError = Self.duplicateNameMessage
                        renameTarget = search
                    } else {
                        renameError = nil
                        renameTarget = nil
                    }
                }
                // Blank names can't commit — without the gate the alert
                // auto-dismisses on Rename and the no-op reads as done.
                .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel", role: .cancel) {
                    renameError = nil
                    renameTarget = nil
                }
            } message: { _ in
                Text(renameError
                     ?? "The new name is capped at \(SavedSearch.nameLengthCap) characters.")
            }
            .alert(Self.savePromptTitle(for: activeInterface), isPresented: $showSavePrompt) {
                TextField("Name", text: $savePromptName)
                Button("Save") {
                    let trimmed = savePromptName.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    if savedSearchStore.add(Self.capture(from: searchState, name: trimmed)) {
                        savePromptError = nil
                    } else {
                        // H-74 — duplicate name: re-present with the
                        // collision message (UXF-04 re-present pattern)
                        // instead of silently appending a twin row.
                        savePromptError = Self.duplicateNameMessage
                        showSavePrompt = true
                    }
                }
                // Blank names can't commit — a Save that auto-dismisses
                // while saving nothing reads as success.
                .disabled(savePromptName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel", role: .cancel) { savePromptError = nil }
            } message: {
                Text(savePromptError ?? Self.savePromptMessage(for: activeInterface))
            }
            // UXF-33: destructive confirm for swipe-Delete, mirroring
            // the app-wide confirmation-dialog pattern (Settings
            // Reset-to-Defaults / Redact N instances). Title comes from
            // `deleteConfirmTitle(for:)` so the copy is pinned by test.
            .confirmationDialog(
                Self.deleteConfirmTitle(for: deleteTarget),
                isPresented: Binding(
                    get: { deleteTarget != nil },
                    set: { if !$0 { deleteTarget = nil } }
                ),
                titleVisibility: .visible,
                presenting: deleteTarget
            ) { search in
                Button("Delete", role: .destructive) {
                    savedSearchStore.remove(id: search.id)
                    deleteTarget = nil
                }
                Button("Cancel", role: .cancel) { deleteTarget = nil }
            } message: { _ in
                Text("The saved search is removed from this device.")
            }
        }
        // S7 §4.1: saved query previews may themselves be PII — this sheet
        // presents modally above the search sheet's shield swap, so it
        // carries its own (SEC-3 extension, same rationale as C10).
        .shieldedSheetContent(monitor: captureMonitor)
    }

    // MARK: - Row

    @ViewBuilder
    private func savedSearchRow(_ search: SavedSearch) -> some View {
        Button {
            onRecall(search)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(search.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                HStack(spacing: ResectaTokens.Spacing.xs) {
                    Text(search.mode.displayName)
                        .font(.caption2.bold())
                        .padding(.horizontal, ResectaTokens.Spacing.sm)
                        .padding(.vertical, ResectaTokens.Spacing.xxs)
                        .background(ResectaTokens.BrandTeal.tint.opacity(0.15), in: Capsule())
                    if let preview = Self.queryPreview(for: search) {
                        Text(preview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            // The saved query text may itself be PII.
                            .privacySensitive()
                    }
                }
                if let filters = Self.filterSummary(for: search) {
                    Text(filters)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .accessibilityLabel("Saved search \(search.name), \(search.mode.displayName) mode")
        .swipeActions(edge: .trailing) {
            Button("Delete", role: .destructive) {
                deleteTarget = search
            }
            .accessibilityLabel("Delete saved search \(search.name)")
        }
        .swipeActions(edge: .leading) {
            Button("Rename") {
                renameText = search.name
                renameTarget = search
            }
            .tint(ResectaTokens.BrandTeal.tint)
            .accessibilityLabel("Rename saved search \(search.name)")
        }
    }

    // MARK: - Testable static seams (S6 testable-static pattern)

    /// The typed-list partition: entries whose persisted mode belongs
    /// to `interface`. One store underneath; the mode's frozen wire
    /// value carries interface identity, so no second field exists and
    /// nothing migrates. Order is preserved (the store's append order).
    static func visibleEntries(
        _ all: [SavedSearch],
        interface: SearchInterface
    ) -> [SavedSearch] {
        all.filter { $0.mode.interface == interface }
    }

    /// Per-interface list chrome. Functional minimum only: the labels
    /// must not claim the other interface's entries are absent from the
    /// store — they are listed on their own side.
    static func sectionHeader(for interface: SearchInterface) -> String {
        interface == .scan ? "Saved Scans" : "Saved Searches"
    }

    static func emptyStateTitle(for interface: SearchInterface) -> String {
        interface == .scan ? "No Saved Scans" : "No Saved Searches"
    }

    static func emptyStateDescription(for interface: SearchInterface) -> String {
        interface == .scan
            ? "Save a scan to reuse its category and option setup later. Text searches are listed on the Search side."
            : "Save a search to reuse it later on this or other documents. Saved scans are listed on the Scan side."
    }

    static func saveCurrentLabel(for interface: SearchInterface) -> String {
        interface == .scan ? "Save current scan…" : "Save current search…"
    }

    /// H-74 — collision message for a rejected duplicate name (save and
    /// rename prompts). Mechanism description, no outcome promise.
    static let duplicateNameMessage =
        "That name is already in use — choose a different name."

    /// Save-prompt chrome follows the interface whose shape the save
    /// captures: the Scan side names categories and options, the
    /// Search side names query text and filters — the prompt never
    /// describes the other interface's shape.
    static func savePromptTitle(for interface: SearchInterface) -> String {
        interface == .scan ? "Save Current Scan" : "Save Current Search"
    }

    static func savePromptMessage(for interface: SearchInterface) -> String {
        interface == .scan
            ? "Saves the current scan shape — selected categories and options. Never document content or results."
            : "Saves the current query shape — mode, query text, and filter settings. Never document content or results."
    }

    /// Apply a saved shape to the live `SearchState` (recall). The
    /// programmatic-mode-change flag is armed only when the mode actually
    /// changes — the hub's `.onChange(of: searchModeType)` handler is the
    /// sole consumer and resets it; arming it without a mode change would
    /// leave a stale `true` that mis-classifies the next USER transition.
    /// `thresholdVector` is intentionally NOT part of the shape
    /// (session state, not query shape — codec whitelist).
    static func apply(_ saved: SavedSearch, to searchState: SearchState) {
        searchState.isProgrammaticModeChange = searchState.searchModeType != saved.mode
        searchState.searchModeType = saved.mode
        searchState.queryText = saved.queryText ?? ""
        // Blank/whitespace terms never match anything and, under
        // conjunction, one such term zeroes the whole AND search (no
        // page can carry a hit for it). The typing UI can't produce
        // them; the decode boundary can (version-skewed or edited
        // blobs), so filter here.
        searchState.searchTerms = (saved.searchTerms ?? []).filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        // Post-scan display filters are session state, not query shape:
        // a recall into the SAME mode never passes through the
        // mode-switch `.onChange` (which resets them for cross-mode
        // transitions), and a stale category filter from the previous
        // session would silently hide the recalled run's results —
        // every Scan→Scan recall is same-mode.
        searchState.piiCategoryFilter = nil
        searchState.sortOrder = .discoveryOrder
        // D-63/UT-05: category restore only while the chips strip is
        // live — with the strip dark there is no UI that shows or
        // undoes a narrowed detector set, so recall must not silently
        // narrow what the next scan runs. The persisted
        // `enabledPIICategories` field is untouched (schema and codec
        // unchanged; capture still writes it) and restore revives with
        // the flag. Pinned by `SavedListPartitionTests`. DC-212.
        if SearchState.scanCategoryStripEnabled,
           let categories = saved.enabledPIICategories {
            searchState.enabledPIICategories = categories
        }
        searchState.options.caseSensitive = saved.caseSensitive
        searchState.options.wholeWord = saved.wholeWord
        searchState.options.stripDigitSeparators = saved.stripDigitSeparators
        searchState.options.normalizeSmartPunctuation = saved.normalizeSmartPunctuation
        searchState.options.foldDiacritics = saved.foldDiacritics
        searchState.options.includeOCR = saved.includeOCR
        searchState.options.multiTermConjunction = saved.multiTermConjunction
        searchState.sourceFilter = saved.sourceFilter
        searchState.minimumOCRConfidence = saved.minimumOCRConfidence
        searchState.minimumPIIConfidence = saved.minimumPIIConfidence
    }

    /// Capture the current query shape as a `SavedSearch`. Persists shape
    /// only — never matched text, page indices, or other document-derived
    /// state (codec whitelist).
    static func capture(from searchState: SearchState, name: String) -> SavedSearch {
        SavedSearch(
            name: name,
            mode: searchState.searchModeType,
            queryText: searchState.queryText.isEmpty ? nil : searchState.queryText,
            searchTerms: searchState.searchTerms.isEmpty ? nil : searchState.searchTerms,
            enabledPIICategories: searchState.searchModeType == .piiScan
                ? searchState.enabledPIICategories : nil,
            caseSensitive: searchState.options.caseSensitive,
            wholeWord: searchState.options.wholeWord,
            sourceFilter: searchState.sourceFilter,
            minimumOCRConfidence: searchState.minimumOCRConfidence,
            minimumPIIConfidence: searchState.minimumPIIConfidence,
            stripDigitSeparators: searchState.options.stripDigitSeparators,
            normalizeSmartPunctuation: searchState.options.normalizeSmartPunctuation,
            foldDiacritics: searchState.options.foldDiacritics,
            includeOCR: searchState.options.includeOCR,
            multiTermConjunction: searchState.options.multiTermConjunction
        )
    }

    /// UXF-33: delete-confirm dialog title. Names the saved search being
    /// removed (the name is user-typed and already visible in the list
    /// row). Nil-tolerant so the dialog modifier can evaluate it while
    /// no target is armed.
    static func deleteConfirmTitle(for search: SavedSearch?) -> String {
        guard let search else { return "Delete saved search?" }
        return "Delete “\(search.name)”?"
    }

    /// Pre-filled save-prompt name (design §4.1).
    static func generatedName(for searchState: SearchState) -> String {
        switch searchState.searchModeType {
        case .piiScan:
            return "\(SearchModeType.piiScan.displayName) – \(Date.now.formatted(date: .abbreviated, time: .shortened))"
        case .multiTerm:
            let terms = searchState.searchTerms.prefix(3).joined(separator: ", ")
            return "Terms: \(String(terms.prefix(30)))"
        case .text, .regex:
            return "\(searchState.searchModeType.displayName): \(String(searchState.queryText.prefix(30)))"
        }
    }

    /// Truncated secondary-row preview: query text (40 chars) or the
    /// first three terms.
    static func queryPreview(for saved: SavedSearch) -> String? {
        if let query = saved.queryText, !query.isEmpty {
            return String(query.prefix(40))
        }
        if let terms = saved.searchTerms, !terms.isEmpty {
            return terms.prefix(3).joined(separator: ", ")
        }
        return nil
    }

    /// Tertiary filter line — shown only when the shape departs from the
    /// defaults (design §4.1: avoid clutter at the default state).
    static func filterSummary(for saved: SavedSearch) -> String? {
        var parts: [String] = []
        if saved.sourceFilter != .all {
            parts.append("Source: \(saved.sourceFilter.rawValue)")
        }
        if saved.minimumOCRConfidence > 0 {
            parts.append("OCR ≥\(Int(saved.minimumOCRConfidence * 100))%")
        }
        // Legacy-only display: the per-run confidence slider is
        // retired, so no live UI can produce a non-default value —
        // this chip fires only for entries saved before the
        // retirement, where it still honestly describes the saved
        // shape. The schema keeps the field (frozen v2).
        if saved.mode == .piiScan && saved.minimumPIIConfidence != 0.50 {
            parts.append("Confidence ≥\(Int(saved.minimumPIIConfidence * 100))%")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
