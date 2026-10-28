import Foundation
import RedactionEngine

// The occurrence rule of the search sheet. A match that runs onto a second
// line is returned as one result per line it touches, the lines sharing
// one occurrence id. The sheet shows it as ONE row — its lead piece, the
// first of its lines in `results` order — and the row's tick, the counts,
// the walk and the apply read every line of it. The per-line lists
// (`filteredResults`, `resultsByPage`) are unchanged: the canvas draws
// each line's highlight from them, so both lines stay highlighted and
// boxed. A result that does not wrap is its own occurrence.

extension SearchState {

    /// The occurrence `result` is a line of: its occurrence id, or its own
    /// id for a result that does not wrap.
    static func occurrenceKey(_ result: SearchResult) -> UUID {
        result.occurrenceID ?? result.id
    }

    /// One row per occurrence: the lead piece of each, in `results` order.
    static func occurrenceRows(_ results: [SearchResult]) -> [SearchResult] {
        var seen = Set<UUID>()
        return results.filter { seen.insert(occurrenceKey($0)).inserted }
    }

    /// How many occurrences `results` hold.
    static func occurrenceCount(_ results: [SearchResult]) -> Int {
        Set(results.map(occurrenceKey)).count
    }

    /// The selection every result takes under `predicate`, per occurrence:
    /// the lead piece's answer, so no occurrence is left half selected.
    static func occurrenceSelection(
        _ results: [SearchResult], where predicate: (SearchResult) -> Bool
    ) -> [UUID: Bool] {
        var decided: [UUID: Bool] = [:]
        for result in results where decided[occurrenceKey(result)] == nil {
            decided[occurrenceKey(result)] = predicate(result)
        }
        return decided
    }

    /// Every line of the occurrence the result `id` is a line of (the
    /// result alone when it does not wrap); empty for an unknown id.
    func pieces(of id: UUID) -> [SearchResult] {
        guard let result = results.first(where: { $0.id == id }) else { return [] }
        let key = Self.occurrenceKey(result)
        return results.filter { Self.occurrenceKey($0) == key }
    }

    /// How many occurrences the results with these ids are lines of.
    func occurrenceCount(ofIDs ids: Set<UUID>) -> Int {
        Self.occurrenceCount(results.filter { ids.contains($0.id) })
    }

    /// The result rows grouped by page, filters applied: one row per
    /// occurrence, on its lead piece's page. (`resultsByTerm` groups the
    /// rows the same way; `resultsByPage` keeps every line for the canvas.)
    var rowsByPage: [Int: [SearchResult]] {
        Dictionary(grouping: Self.occurrenceRows(filteredResults), by: \.pageIndex)
    }

    /// 0-based position of the current result's occurrence among every
    /// occurrence; nil with no current result.
    var currentOccurrenceIndex: Int? {
        guard let current = currentResult else { return nil }
        let key = Self.occurrenceKey(current)
        return Self.occurrenceRows(results).firstIndex { Self.occurrenceKey($0) == key }
    }

    /// Occurrences none of whose lines produced a region or was already
    /// covered by one — the matches a clear loses.
    var unappliedOccurrenceCount: Int {
        let done = appliedResultIDs.union(coveredResultIDs)
        let touched = Set(results.filter { done.contains($0.id) }.map(Self.occurrenceKey))
        return Self.occurrenceCount(results) - touched.count
    }

    /// `count` (regions or results) less the extra lines of the wrapped
    /// matches among `ids`: a match on two lines counts once. Unchanged
    /// when nothing among `ids` wraps.
    func countingOccurrences(_ count: Int, ids: Set<UUID>) -> Int {
        count - (results.count { ids.contains($0.id) } - occurrenceCount(ofIDs: ids))
    }

    /// The Marked notice's counts for an apply, by occurrence.
    func markedCounts(_ outcome: RedactionState.ApplyOutcome?) -> (applied: Int, alreadyCovered: Int) {
        guard let outcome else { return (0, 0) }
        return (countingOccurrences(outcome.applied, ids: outcome.appliedResultIDs),
                countingOccurrences(outcome.skippedOverlaps, ids: outcome.coveredResultIDs))
    }
}
