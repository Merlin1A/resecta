import SwiftUI
import RedactionEngine

// Saved-searches recall UI. The store
// (`SavedSearchStore`) shipped in V1.0 with no consuming surface;
// this sheet adds list / recall / rename / delete / save affordances.
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
    /// UXF-33 / ST-94: swipe-Delete asks for confirmation before the
    /// store removal (app-standard destructive-confirm idiom — same
    /// shape as Settings' Reset dialogs).
    @State private var deleteTarget: SavedSearch?

    var body: some View {
        NavigationStack {
            List {
                if savedSearchStore.savedSearches.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No Saved Searches",
                            systemImage: "bookmark",
                            description: Text("Save a search to reuse it later on this or other documents.")
                        )
                        .listRowBackground(Color.clear)
                    }
                } else {
                    Section("Saved Searches") {
                        ForEach(savedSearchStore.savedSearches) { search in
                            savedSearchRow(search)
                        }
                    }
                }

                // Save entry point — always visible while the sheet is open
                // (design §4.1), pre-filled with a generated name.
                Section {
                    Button {
                        savePromptName = Self.generatedName(for: searchState)
                        showSavePrompt = true
                    } label: {
                        Label("Save current search…", systemImage: "plus.circle")
                    }
                    .accessibilityLabel("Save current search")
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
                    if !trimmed.isEmpty {
                        savedSearchStore.rename(id: search.id, to: trimmed)
                    }
                    renameTarget = nil
                }
                Button("Cancel", role: .cancel) { renameTarget = nil }
            } message: { _ in
                Text("The new name is capped at \(SavedSearch.nameLengthCap) characters.")
            }
            .alert("Save Current Search", isPresented: $showSavePrompt) {
                TextField("Name", text: $savePromptName)
                Button("Save") {
                    let trimmed = savePromptName.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    savedSearchStore.add(Self.capture(from: searchState, name: trimmed))
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Saves the current query shape — mode, query text, and filter settings. Never document content or results.")
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
        searchState.searchTerms = saved.searchTerms ?? []
        if let categories = saved.enabledPIICategories {
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
            return "PII Scan – \(Date.now.formatted(date: .abbreviated, time: .shortened))"
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
        if saved.mode == .piiScan && saved.minimumPIIConfidence != 0.50 {
            parts.append("Confidence ≥\(Int(saved.minimumPIIConfidence * 100))%")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
