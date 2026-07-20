import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// design 04 §4.6 — Persist Text/Regex Recents + Last-Used Filter Settings
// All tests use a scratch UserDefaults suite so they don't pollute
// UserDefaults.standard and can run in isolation without shared-state
// hazards. Suite name is cleaned up in a defer block per test.

// MARK: - Helpers

/// Create a scratch UserDefaults suite and return it + a cleanup closure.
private func makeScratchDefaults() -> (UserDefaults, suiteName: String) {
    let name = UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    return (defaults, name)
}

// MARK: - SearchRecentsTests

@Suite("SearchRecents — design 04 §4.6")
@MainActor
struct SearchRecentsTests {

    // MARK: textQueryRecordedOnTrigger

    @Test("With persistence opted in, text queries record most-recent-first + dedupe move-to-front")
    func textQueryRecordedOnTrigger() {
        let (defaults, suiteName) = makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Persistence is opt-in (default OFF); this test covers the
        // opted-in write-through path.
        defaults.set(true, forKey: "search.recents.enabled.v1")
        let state = SearchState(defaults: defaults)
        state.recordRecentQuery("foo", mode: .text)
        state.recordRecentQuery("bar", mode: .text)
        // "foo" again — should move to front
        state.recordRecentQuery("foo", mode: .text)

        #expect(state.recentTextQueries == ["foo", "bar"])
        // Regex list must not be contaminated by text queries.
        #expect(state.recentRegexQueries.isEmpty)
        // Persisted to UserDefaults.
        let stored = defaults.array(forKey: "search.recents.text.v1") as? [String]
        #expect(stored == ["foo", "bar"])
    }

    // MARK: recentsCapAt10

    @Test("Recents cap at 10; oldest entry dropped when 11 queries recorded")
    func recentsCapAt10() {
        let (defaults, suiteName) = makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = SearchState(defaults: defaults)
        for i in 1...11 {
            state.recordRecentQuery("q\(i)", mode: .text)
        }
        // Cap is 10; "q1" (oldest) must be dropped.
        #expect(state.recentTextQueries.count == 10)
        #expect(!state.recentTextQueries.contains("q1"))
        // Most-recent ("q11") must be first.
        #expect(state.recentTextQueries.first == "q11")
    }

    // MARK: privacyToggleKeepsRecentsInMemory

    @Test("Privacy toggle (search.recents.enabled.v1 = false) keeps recents in-memory only")
    func privacyToggleKeepsRecentsInMemory() {
        let (defaults, suiteName) = makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: "search.recents.enabled.v1")
        let state = SearchState(defaults: defaults)
        state.recordRecentQuery("sensitive-term", mode: .text)
        state.recordRecentQuery("another-pattern", mode: .regex)

        // In-memory recall still works for the session…
        #expect(state.recentTextQueries == ["sensitive-term"])
        #expect(state.recentRegexQueries == ["another-pattern"])
        // …but nothing reaches UserDefaults.
        #expect(defaults.object(forKey: "search.recents.text.v1") == nil)
        #expect(defaults.object(forKey: "search.recents.regex.v1") == nil)
    }

    // MARK: defaultIsPrivate

    @Test("Absent preference key means OFF: recents stay in-memory, nothing persisted")
    func defaultIsPrivate() {
        let (defaults, suiteName) = makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // No enabled key written — the shipping default.
        let state = SearchState(defaults: defaults)
        state.recordRecentQuery("query-one", mode: .text)
        state.recordRecentQuery("\\d{3}", mode: .regex)

        #expect(state.recentTextQueries == ["query-one"])
        #expect(state.recentRegexQueries == ["\\d{3}"])
        #expect(defaults.object(forKey: "search.recents.text.v1") == nil)
        #expect(defaults.object(forKey: "search.recents.regex.v1") == nil)
    }

    // MARK: oneTimeDeletion

    @Test("deletePersistedRecentsOnce removes both lists exactly once")
    func oneTimeDeletionRemovesListsOnce() {
        let (defaults, suiteName) = makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Lists persisted by an earlier build, preference never set.
        defaults.set(["old-query"], forKey: "search.recents.text.v1")
        defaults.set(["old-\\d{2}"], forKey: "search.recents.regex.v1")

        SearchState.deletePersistedRecentsOnce(defaults: defaults)
        #expect(defaults.object(forKey: "search.recents.text.v1") == nil)
        #expect(defaults.object(forKey: "search.recents.regex.v1") == nil)

        // Lists recorded AFTER the user opts back in must survive the
        // next launch's call — the flag guard is load-bearing.
        defaults.set(true, forKey: "search.recents.enabled.v1")
        let state = SearchState(defaults: defaults)
        state.recordRecentQuery("new-query", mode: .text)
        SearchState.deletePersistedRecentsOnce(defaults: defaults)
        #expect(defaults.array(forKey: "search.recents.text.v1") as? [String] == ["new-query"])
    }

    @Test("deletePersistedRecentsOnce runs unconditionally — even with persistence opted in")
    func oneTimeDeletionIgnoresPreference() {
        let (defaults, suiteName) = makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // User had opted in on an earlier build; the one-shot deletion
        // still clears the previously persisted lists.
        defaults.set(true, forKey: "search.recents.enabled.v1")
        defaults.set(["kept-on"], forKey: "search.recents.text.v1")

        SearchState.deletePersistedRecentsOnce(defaults: defaults)
        #expect(defaults.object(forKey: "search.recents.text.v1") == nil)
    }

    // MARK: clearSearchHistoryClearsAll

    @Test("clearRecentSearchHistory empties recents arrays, multiTerm ring, and UserDefaults keys")
    func clearSearchHistoryClearsAll() {
        let (defaults, suiteName) = makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Opt in so the persisted keys exist and the clear has both
        // stores (memory + disk) to empty.
        defaults.set(true, forKey: "search.recents.enabled.v1")
        let state = SearchState(defaults: defaults)
        state.recordRecentQuery("alpha", mode: .text)
        state.recordRecentQuery("beta", mode: .regex)
        state.recordMultiTermSearch(terms: ["x", "y"])

        #expect(!state.recentTextQueries.isEmpty)
        #expect(!state.recentRegexQueries.isEmpty)
        #expect(!state.recentMultiTermSets.isEmpty)

        state.clearRecentSearchHistory()

        #expect(state.recentTextQueries.isEmpty)
        #expect(state.recentRegexQueries.isEmpty)
        #expect(state.recentMultiTermSets.isEmpty)
        // UserDefaults keys must be gone.
        #expect(defaults.object(forKey: "search.recents.text.v1") == nil)
        #expect(defaults.object(forKey: "search.recents.regex.v1") == nil)
    }

    // MARK: recentsNeverContainMatchedText (adversarial)

    @Test("Adversarial: recents store query string only, never matched-text content")
    func recentsNeverContainMatchedText() {
        let (defaults, suiteName) = makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = SearchState(defaults: defaults)
        // Simulate a query and a result with different matched text.
        let queryText = "myQuery"
        let matchedText = "this-is-document-content-123-456-789"
        state.recordRecentQuery(queryText, mode: .text)

        #expect(!state.recentTextQueries.contains(matchedText))
        #expect(!state.recentRegexQueries.contains(matchedText))
        // The stored query is exactly the query string, nothing else.
        #expect(state.recentTextQueries == [queryText])
    }

    // MARK: recentsNotWipedByClear

    @Test("clear() and clearResults() do not wipe recents (design 04 §4.6 / [D-28] carve-out)")
    func recentsNotWipedByClear() {
        let (defaults, suiteName) = makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = SearchState(defaults: defaults)
        state.recordRecentQuery("persistent-query", mode: .text)
        state.recordRecentQuery("\\d{3}", mode: .regex)

        // clearResults() must not touch recents.
        state.clearResults()
        #expect(state.recentTextQueries == ["persistent-query"])
        #expect(state.recentRegexQueries == ["\\d{3}"])

        // clear() (sheet dismiss) must also not touch recents.
        state.clear()
        #expect(state.recentTextQueries == ["persistent-query"])
        #expect(state.recentRegexQueries == ["\\d{3}"])
    }

    // MARK: regexQueriesStoreInRegexList

    @Test("Regex queries are stored in recentRegexQueries, not recentTextQueries")
    func regexQueriesStoreInRegexList() {
        let (defaults, suiteName) = makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = SearchState(defaults: defaults)
        state.recordRecentQuery("\\d{4}", mode: .regex)

        #expect(state.recentRegexQueries == ["\\d{4}"])
        #expect(state.recentTextQueries.isEmpty)
    }

    // MARK: emptyQueryIsNoOp

    @Test("Recording an empty query is a no-op")
    func emptyQueryIsNoOp() {
        let (defaults, suiteName) = makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = SearchState(defaults: defaults)
        state.recordRecentQuery("", mode: .text)
        state.recordRecentQuery("", mode: .regex)

        #expect(state.recentTextQueries.isEmpty)
        #expect(state.recentRegexQueries.isEmpty)
    }

    // MARK: unsupportedModesAreNoOp

    @Test("Modes other than .text/.regex are no-ops for recents recording")
    func unsupportedModesAreNoOp() {
        let (defaults, suiteName) = makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = SearchState(defaults: defaults)
        state.recordRecentQuery("anything", mode: .multiTerm)
        state.recordRecentQuery("anything", mode: .piiScan)

        #expect(state.recentTextQueries.isEmpty)
        #expect(state.recentRegexQueries.isEmpty)
    }

    // MARK: persistenceRoundTripAcrossInstances

    @Test("With persistence opted in, recents persist across SearchState instances sharing the same UserDefaults suite")
    func persistenceRoundTripAcrossInstances() {
        let (defaults, suiteName) = makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: "search.recents.enabled.v1")
        let first = SearchState(defaults: defaults)
        first.recordRecentQuery("term-one", mode: .text)
        first.recordRecentQuery("pattern-one", mode: .regex)

        // Create a new instance reading from the same suite.
        let second = SearchState(defaults: defaults)
        #expect(second.recentTextQueries == ["term-one"])
        #expect(second.recentRegexQueries == ["pattern-one"])
    }
}

// MARK: - LastFilterPersistenceTests

@Suite("LastFilterPersistence — design 04 §4.6")
@MainActor
struct LastFilterPersistenceTests {

    // MARK: filterRestoredOnNextSheetOpen

    @Test("Last-used filter shape restores on next SearchState init (after debounce)")
    func filterRestoredOnNextSheetOpen() async {
        let (defaults, suiteName) = makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = SearchState(defaults: defaults)
        first.sourceFilter = .textOnly
        first.sortOrder = .pageAscending
        first.minimumOCRConfidence = 0.75

        // Wait for the 500 ms debounce to flush.
        try? await Task.sleep(for: .milliseconds(700))

        // Construct a new instance — must restore the filter shape.
        let second = SearchState(defaults: defaults)
        #expect(second.sourceFilter == .textOnly)
        #expect(second.sortOrder == .pageAscending)
        #expect(second.minimumOCRConfidence == 0.75)

        // appliedFilter is intentionally NOT restored (document-specific).
        #expect(second.appliedFilter == .all)
    }

    // MARK: appliedFilterNotRestored

    @Test("appliedFilter is never persisted (document-specific per §4.6)")
    func appliedFilterNotRestored() async {
        let (defaults, suiteName) = makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = SearchState(defaults: defaults)
        first.appliedFilter = .applied

        // Wait for any debounce that might (incorrectly) flush appliedFilter.
        try? await Task.sleep(for: .milliseconds(700))

        let second = SearchState(defaults: defaults)
        #expect(second.appliedFilter == .all)
    }

    // MARK: - BH-B-06 whitespace hygiene

    @Test("BH-B-06: whitespace-only queries are never recorded (no blank recents chip)")
    func whitespaceOnlyQueryNotRecorded() {
        let (defaults, suiteName) = makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = SearchState(defaults: defaults)
        state.recordRecentQuery("   ", mode: .text)
        state.recordRecentQuery("\n\t ", mode: .regex)
        #expect(state.recentTextQueries.isEmpty)
        #expect(state.recentRegexQueries.isEmpty)
        // A whitespace-PADDED query is a real (verbatim) query and
        // stays recallable.
        state.recordRecentQuery(" acct ", mode: .text)
        #expect(state.recentTextQueries == [" acct "])
    }

    @Test("BH-B-06: the debounce auto-run floor counts trimmed characters")
    func debounceFloorCountsTrimmedCharacters() {
        #expect(SearchAndRedactSheet.queryQualifiesForAutoRun("   ") == false)
        #expect(SearchAndRedactSheet.queryQualifiesForAutoRun("  a b  ") == true)
        #expect(SearchAndRedactSheet.queryQualifiesForAutoRun(" ab ") == false,
                "2 trimmed chars stays under the ≥3 floor — explicit Return only")
        #expect(SearchAndRedactSheet.queryQualifiesForAutoRun("abc") == true)
        #expect(SearchAndRedactSheet.queryQualifiesForAutoRun("") == false)
    }
}
