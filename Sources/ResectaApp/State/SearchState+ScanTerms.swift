import Foundation
import RedactionEngine

extension SearchState {
    // MARK: - PII Scan Configuration

    /// Categories the next scan actually requests. An empty chip
    /// selection means scan EVERYTHING: the one-tap contract needs no
    /// configuration, so no selection maps to the full category set
    /// rather than a no-op scan. Consumed by `buildSearchMode()`, the
    /// coverage report, and the empty-state detector count so all
    /// three surfaces describe the same run.
    var effectiveScanCategories: Set<PIICategory> {
        enabledPIICategories.isEmpty ? Set(PIICategory.allCases) : enabledPIICategories
    }

    /// Drop the session's filter caches. Called from the local didSet
    /// paths above when the inputs that key `_FilterCacheKey` change.
    /// The id→index map keys on `resultVersion` alone and survives.
    func invalidateFilterCaches() {
        _filterCache.invalidateFilters()
    }

    // MARK: - Multi-term

    static let recentMultiTermSetsCap = 5

    /// Record a multi-term term set into the
    /// in-memory ring. No-op for empty `terms`. Existing matching
    /// entries move to the front (most-recent-first); the ring is
    /// capped at `recentMultiTermSetsCap`, dropping the oldest.
    func recordMultiTermSearch(terms: [String]) {
        guard !terms.isEmpty else { return }
        if let existing = recentMultiTermSets.firstIndex(of: terms) {
            recentMultiTermSets.remove(at: existing)
        }
        recentMultiTermSets.insert(terms, at: 0)
        if recentMultiTermSets.count > Self.recentMultiTermSetsCap {
            recentMultiTermSets = Array(recentMultiTermSets.prefix(Self.recentMultiTermSetsCap))
        }
    }

    // MARK: - Retired recents purge

    /// The persisted text/regex recents feature is excised; only the
    /// in-memory multi-term ring above remains. This sweep removes the
    /// feature's four retired storage keys from existing installs at
    /// every launch — unconditional and idempotent, with no marker key
    /// (a marker would itself be residue). The key strings live here as
    /// literals because this function is deliberately their last home.
    static func purgeRetiredRecentsStorage(defaults: UserDefaults = .standard) {
        for key in [
            "search.recents.enabled.v1",
            "search.recents.text.v1",
            "search.recents.regex.v1",
            "search.recents.oneTimeDeletion.v1",
        ] {
            defaults.removeObject(forKey: key)
        }
    }
}
