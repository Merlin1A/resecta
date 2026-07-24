import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// design 04 §4.6 — Last-Used Filter Settings persistence, plus the
// WA-01 pins for the launch sweep that purges the excised
// persisted-recents feature's retired storage keys.
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

    // MARK: - BH-B-06 debounce floor

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

// MARK: - RetiredRecentsPurgeTests

@Suite("RetiredRecentsPurge — WA-01")
@MainActor
struct RetiredRecentsPurgeTests {

    private static let retiredKeys = [
        "search.recents.enabled.v1",
        "search.recents.text.v1",
        "search.recents.regex.v1",
        "search.recents.oneTimeDeletion.v1",
    ]

    // MARK: purgeRemovesAllFourSeededLegacyKeys

    @Test("Seeded legacy container: the sweep removes all four retired recents keys")
    func purgeRemovesAllFourSeededLegacyKeys() {
        let (defaults, suiteName) = makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // A container shaped like an install that used the feature:
        // preference on, both lists populated, one-shot marker set.
        defaults.set(true, forKey: "search.recents.enabled.v1")
        defaults.set(["delia", "deli", "del"], forKey: "search.recents.text.v1")
        defaults.set(["\\d{3}"], forKey: "search.recents.regex.v1")
        defaults.set(true, forKey: "search.recents.oneTimeDeletion.v1")

        SearchState.purgeRetiredRecentsStorage(defaults: defaults)

        for key in Self.retiredKeys {
            #expect(defaults.object(forKey: key) == nil, "\(key) must be purged")
        }
    }

    // MARK: purgeIsIdempotentAndScoped

    @Test("Fresh container: the sweep is an idempotent no-op and leaves search.lastFilter.v1 alone")
    func purgeIsIdempotentAndScoped() {
        let (defaults, suiteName) = makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // The live lastFilter feature shares the "search." key prefix —
        // the sweep must not touch it.
        let filterData = Data("{}".utf8)
        defaults.set(filterData, forKey: "search.lastFilter.v1")

        SearchState.purgeRetiredRecentsStorage(defaults: defaults)
        SearchState.purgeRetiredRecentsStorage(defaults: defaults)

        for key in Self.retiredKeys {
            #expect(defaults.object(forKey: key) == nil)
        }
        #expect(defaults.data(forKey: "search.lastFilter.v1") == filterData)
    }
}
