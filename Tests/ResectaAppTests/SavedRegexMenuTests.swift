import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// Saved-regex inline menu (Regex mode). Menu lives next to the regex
// warning in `SearchToolbarSection.standardSearchOptions`; tapping a
// saved entry inserts its pattern into `searchState.queryText`,
// "Save current..." opens an alert that flushes via
// `savedRegexStore.add(label:pattern:)` after
// `RegexSentinelCheck.validate(_:)`. Pure-function contracts pinned
// here keep the menu's predicates + strings testable without hosting
// the SwiftUI view.

@Suite("Saved regex inline menu")
struct SavedRegexMenuTests {

    private static func makeSuite(_ function: String = #function) -> UserDefaults {
        let name = "app.resecta.tests.SavedRegexMenu.\(function).\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return suite
    }

    // MARK: - Static contracts

    @Test("Save current menu item label pins the SAFE-classified copy")
    func saveCurrentRegexMenuItemLabel() {
        #expect(SearchToolbarSection.saveCurrentRegexMenuItem == "Save current...")
    }

    @Test("Saved section header label pins the SAFE-classified copy")
    func savedRegexSectionHeaderLabel() {
        #expect(SearchToolbarSection.savedRegexSectionHeader == "Saved...")
    }

    // MARK: - canSaveCurrentRegex

    @Test("canSaveCurrentRegex is false when query text is empty")
    func canSaveCurrentDisabledOnEmptyQuery() {
        #expect(SearchToolbarSection.canSaveCurrentRegex(savedCount: 0, queryText: "") == false)
        #expect(SearchToolbarSection.canSaveCurrentRegex(savedCount: 0, queryText: "   ") == false)
        #expect(SearchToolbarSection.canSaveCurrentRegex(savedCount: 5, queryText: "\t") == false)
    }

    @Test("canSaveCurrentRegex is false at the user-saved cap")
    @MainActor
    func canSaveCurrentDisabledAtCap() {
        #expect(SearchToolbarSection.canSaveCurrentRegex(
            savedCount: SavedRegexStore.userSavedCap,
            queryText: "abc"
        ) == false)
        #expect(SearchToolbarSection.canSaveCurrentRegex(
            savedCount: SavedRegexStore.userSavedCap + 1,
            queryText: "abc"
        ) == false)
    }

    @Test("canSaveCurrentRegex is true below cap with non-empty pattern")
    @MainActor
    func canSaveCurrentEnabledBelowCap() {
        #expect(SearchToolbarSection.canSaveCurrentRegex(savedCount: 0, queryText: "abc") == true)
        #expect(SearchToolbarSection.canSaveCurrentRegex(savedCount: 50, queryText: "ab") == true)
        #expect(SearchToolbarSection.canSaveCurrentRegex(
            savedCount: SavedRegexStore.userSavedCap - 1,
            queryText: "x"
        ) == true)
    }

    // MARK: - savedRegexCapMessage

    @Test("Cap message is non-nil at cap with the cap value embedded")
    @MainActor
    func capMessageAtCap() {
        let message = SearchToolbarSection.savedRegexCapMessage(
            savedCount: SavedRegexStore.userSavedCap
        )
        #expect(message != nil)
        #expect(message?.contains("\(SavedRegexStore.userSavedCap)") == true)
        #expect(message?.contains("cap") == true)
    }

    @Test("Cap message is nil below cap")
    @MainActor
    func capMessageBelowCap() {
        #expect(SearchToolbarSection.savedRegexCapMessage(savedCount: 0) == nil)
        #expect(SearchToolbarSection.savedRegexCapMessage(savedCount: 50) == nil)
        #expect(SearchToolbarSection.savedRegexCapMessage(
            savedCount: SavedRegexStore.userSavedCap - 1
        ) == nil)
    }

    // MARK: - Insert flow

    @Test("Inserting a saved regex sets queryText to the pattern verbatim")
    @MainActor
    func insertFlowSetsQueryText() {
        // Mirror the menu's insert action: tap a SavedRegex item, the
        // closure runs `searchState.queryText = regex.pattern`. The
        // existing TextField `.onChange` handler in SearchAndRedactSheet
        // then debounces a search at the new query.
        let state = SearchState()
        state.searchModeType = .regex
        let regex = SavedRegex(label: "Birth date", pattern: #"\b\d{1,2}/\d{1,2}/\d{4}\b"#)

        state.queryText = regex.pattern

        #expect(state.queryText == #"\b\d{1,2}/\d{1,2}/\d{4}\b"#)
    }

    @Test("Inserting overwrites a prior queryText so each pick is independent")
    @MainActor
    func insertFlowOverwritesPriorQuery() {
        let state = SearchState()
        state.searchModeType = .regex
        state.queryText = "old-pattern"
        let regex = SavedRegex(label: "Phone", pattern: #"\d{3}-\d{4}"#)

        state.queryText = regex.pattern

        #expect(state.queryText == #"\d{3}-\d{4}"#)
    }

    // MARK: - Save flow (against SavedRegexStore)

    @Test("Save appends to the app-wide SavedRegexStore under the user's label")
    @MainActor
    func saveAppendsToStore() {
        let suite = Self.makeSuite()
        let store = SavedRegexStore(defaults: suite)
        let initialUserCount = store.userSavedRegexes.count

        let added = store.add(label: "ZIP", pattern: #"\b\d{5}\b"#)

        #expect(added == true)
        #expect(store.userSavedRegexes.count == initialUserCount + 1)
        #expect(store.userSavedRegexes.last?.label == "ZIP")
        #expect(store.userSavedRegexes.last?.pattern == #"\b\d{5}\b"#)
    }

    @Test("Save respects the userSavedCap — predicate blocks the alert at cap")
    @MainActor
    func saveRespectsCap() {
        let suite = Self.makeSuite()
        let store = SavedRegexStore(defaults: suite)
        // Pre-fill the user list to the cap via successive add() calls
        // (each pattern must be unique label-wise to clear the dedupe
        // check inside `add`).
        for i in 0..<SavedRegexStore.userSavedCap {
            _ = store.add(label: "label-\(i)", pattern: "p\(i)\\d")
        }
        #expect(store.userSavedRegexes.count == SavedRegexStore.userSavedCap)

        // Predicate blocks the alert when the user list is at cap.
        #expect(SearchToolbarSection.canSaveCurrentRegex(
            savedCount: store.userSavedRegexes.count,
            queryText: "x"
        ) == false)
        #expect(SearchToolbarSection.savedRegexCapMessage(
            savedCount: store.userSavedRegexes.count
        ) != nil)

        // The store also refuses one more add at cap.
        let refused = store.add(label: "extra", pattern: "extra\\d")
        #expect(refused == false)
    }
}
