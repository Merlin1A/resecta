import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

@Suite("RedactionState search-origin apply concurrency", .tags(.search))
@MainActor
struct RedactionStateApplyConcurrencyTests {

    @Test("Large apply completes without freezing — heavy prepare runs off-main")
    func largeApplyCompletes() async {
        let state = RedactionState()
        let search = SearchState()

        // Seed 100 prior regions on page 0 so the overlap test has real work.
        for i in 0..<100 {
            let region = RedactionRegion(
                id: UUID(),
                normalizedRect: CGRect(x: 0.001 * Double(i), y: 0.5, width: 0.0005, height: 0.005),
                source: .manual
            )
            state.regions[0, default: []].append(region)
        }

        // 500 selected search results across 5 pages, none overlapping any prior region.
        var results: [SearchResult] = []
        for page in 0..<5 {
            for i in 0..<100 {
                let yOffset = 0.001 * Double(i)
                results.append(SearchResult(
                    pageIndex: page,
                    normalizedRect: CGRect(x: 0.1, y: 0.001 + yOffset, width: 0.05, height: 0.005),
                    matchedText: "match-\(page)-\(i)",
                    contextSnippet: "...",
                    source: .textLayer,
                    term: "needle",
                    isSelected: true
                ))
            }
        }
        search.results = results
        state.activeSearch = search

        let outcome = await state.applyFindings(.selectedSearchResults, undoManager: nil)

        #expect(outcome?.applied == 500)
        #expect(outcome?.skippedOverlaps == 0)
        #expect(state.regions.values.flatMap { $0 }.count == 600) // 100 prior + 500 new
    }

    @Test("Two serial apply calls — second sees first's regions and skips them as overlaps")
    func serialApplyKeepsAuditConsistent() async {
        let state = RedactionState()
        let search = SearchState()
        var results: [SearchResult] = []
        for i in 0..<50 {
            results.append(SearchResult(
                pageIndex: i % 10,
                normalizedRect: CGRect(
                    x: 0.1,
                    y: 0.001 * Double(i),
                    width: 0.05,
                    height: 0.0005
                ),
                matchedText: "m-\(i)",
                contextSnippet: "...",
                source: .textLayer,
                term: "needle",
                isSelected: true
            ))
        }
        search.results = results
        state.activeSearch = search

        // Back-to-back awaits on a MainActor-isolated state: the second
        // call sees the first's regions and skips them as overlaps.
        let resA = await state.applyFindings(.selectedSearchResults, undoManager: nil)
        let resB = await state.applyFindings(.selectedSearchResults, undoManager: nil)

        let applied = (resA?.applied ?? 0) + (resB?.applied ?? 0)
        let skipped = (resA?.skippedOverlaps ?? 0) + (resB?.skippedOverlaps ?? 0)
        #expect(applied + skipped == 100)
        #expect(state.appliedMatchAudit.count == applied)
    }

    /// `total` selected text-layer results spread over ten pages, none
    /// overlapping another, so a first apply creates one region per
    /// result and any later apply over the same set skips every result.
    private func selectedResults(total: Int) -> [SearchResult] {
        (0..<total).map { i in
            SearchResult(
                pageIndex: i % 10,
                normalizedRect: CGRect(
                    x: 0.1,
                    y: 0.001 * Double(i),
                    width: 0.05,
                    height: 0.0005
                ),
                matchedText: "m-\(i)",
                contextSnippet: "...",
                source: .textLayer,
                term: "needle",
                isSelected: true
            )
        }
    }

    // The concurrent guard: two `async let` applies of the same selected
    // set with no sheet-level gate in front of them, probing the method's
    // own concurrency contract. `applyFindings` serializes its callers —
    // an apply waits for the in-flight apply to commit before it reads
    // `regions` — so the later apply's overlap test sees the earlier
    // apply's regions and skips every match. Three invariants follow:
    // conservation (both calls account for every selected match),
    // audit↔region consistency (one audit row per created region), and
    // no duplication (each match applied exactly once, by exactly one of
    // the two calls).
    @Test("Concurrent apply does not duplicate regions; audit stays consistent")
    func concurrentApplyDoesNotDuplicateRegions() async {
        let state = RedactionState()
        let search = SearchState()
        let total = 50
        search.results = selectedResults(total: total)
        state.activeSearch = search

        // Launch both applies concurrently against the same activeSearch.
        async let a = state.applyFindings(.selectedSearchResults, undoManager: nil)
        async let b = state.applyFindings(.selectedSearchResults, undoManager: nil)
        let (ra, rb) = await (a, b)

        let applied = (ra?.applied ?? 0) + (rb?.applied ?? 0)
        let skipped = (ra?.skippedOverlaps ?? 0) + (rb?.skippedOverlaps ?? 0)
        let regionCount = state.regions.values.flatMap { $0 }.count

        // Conservation: each of the two calls processed all `total` selected
        // matches (applied or skipped-as-overlap).
        #expect(applied + skipped == 2 * total,
                "both calls must account for every selected match")
        // Audit↔region consistency: exactly one audit row per created region
        // (no prior regions were seeded, so all regions are search-sourced),
        // and the audit count equals the combined applied count.
        #expect(state.appliedMatchAudit.count == regionCount,
                "appliedMatchAudit must have one entry per created region")
        #expect(state.appliedMatchAudit.count == applied,
                "audit count must equal the combined applied count")

        // No duplication — the load-bearing property. Serialized applies
        // give exactly one winner: whichever apply runs first creates every
        // region; the other skips every match as already covered.
        #expect(regionCount == total,
                "concurrent apply must not duplicate regions (each match applied once)")
        #expect([ra?.applied ?? 0, rb?.applied ?? 0].sorted() == [0, total],
                "exactly one of the two applies creates the regions")
        #expect([ra?.skippedOverlaps ?? 0, rb?.skippedOverlaps ?? 0].sorted() == [0, total],
                "the other apply skips every match as an overlap")
    }

    // The same contract over three callers: the serialization is a queue,
    // not a two-party hand-off, so one apply creates the regions and the
    // other two skip every match.
    @Test("Three concurrent applies — one creates the regions, two skip every match")
    func threeConcurrentAppliesSerialize() async {
        let state = RedactionState()
        let search = SearchState()
        let total = 40
        search.results = selectedResults(total: total)
        state.activeSearch = search

        async let a = state.applyFindings(.selectedSearchResults, undoManager: nil)
        async let b = state.applyFindings(.selectedSearchResults, undoManager: nil)
        async let c = state.applyFindings(.selectedSearchResults, undoManager: nil)
        let (ra, rb, rc) = await (a, b, c)
        let outcomes = [ra, rb, rc].compactMap { $0 }
        #expect(outcomes.count == 3, "no apply is refused")

        let applied = outcomes.map(\.applied)
        let skipped = outcomes.map(\.skippedOverlaps)
        #expect(applied.reduce(0, +) + skipped.reduce(0, +) == 3 * total,
                "all three calls must account for every selected match")
        #expect(applied.sorted() == [0, 0, total],
                "exactly one of the three applies creates the regions")
        #expect(skipped.sorted() == [0, total, total],
                "the other two skip every match as an overlap")
        #expect(state.regions.values.flatMap { $0 }.count == total,
                "each match is applied exactly once")
        #expect(state.appliedMatchAudit.count == total,
                "one audit row per created region")
    }
}

// D06-F1 — the search-origin apply records the `regionVersion` it produces as a
// monotonic high-water-mark (`lastAppliedSearchRegionVersion`) so the Search &
// Redact sheet can skip clearing the applied markers for the apply's own
// region bump (vs a real undo/redo). See `SearchAndRedactSheet.shouldClearAppliedMarkers`.
@Suite("RedactionState applied-version high-water-mark (D06-F1)", .tags(.search))
@MainActor
struct RedactionStateAppliedVersionTests {

    private func selectedResult(matchedText: String = "m-0") -> SearchResult {
        SearchResult(
            pageIndex: 0,
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.05, height: 0.01),
            matchedText: matchedText,
            contextSnippet: "...",
            source: .textLayer,
            term: "needle",
            isSelected: true
        )
    }

    @Test("Search-origin apply records the produced regionVersion as the high-water-mark")
    func applyRecordsHighWaterMark() async {
        let state = RedactionState()
        let search = SearchState()
        search.results = [selectedResult()]
        state.activeSearch = search

        // Pre-apply: counter at its initial 0, high-water-mark at the -1 sentinel.
        #expect(state.regionVersion == 0)
        #expect(state.lastAppliedSearchRegionVersion == -1)

        let outcome = await state.applyFindings(.selectedSearchResults, undoManager: nil)

        // The apply created one region, advanced regionVersion by exactly 1,
        // and recorded that post-bump value as the high-water-mark.
        #expect(outcome?.applied == 1)
        #expect(state.regionVersion == 1)
        #expect(state.lastAppliedSearchRegionVersion == state.regionVersion)
    }

    @Test("apply records the version that keeps its markers; a later bump clears them")
    func appliedMarkerStateContract() async {
        let state = RedactionState()
        let search = SearchState()
        let result = selectedResult()
        search.results = [result]
        state.activeSearch = search

        _ = await state.applyFindings(.selectedSearchResults, undoManager: nil)
        // Mirror SearchAndRedactSheet's apply path: the applied result IDs are
        // unioned into searchState in the same MainActor tick as the bump.
        search.appliedResultIDs.formUnion([result.id])

        // The apply's own bump must NOT clear the markers it just populated.
        #expect(
            SearchAndRedactSheet.shouldClearAppliedMarkers(
                newVersion: state.regionVersion,
                lastAppliedVersion: state.lastAppliedSearchRegionVersion,
                isEmpty: search.appliedResultIDs.isEmpty
            ) == false
        )

        // A later, larger regionVersion bump (a real undo/redo) DOES clear them.
        #expect(
            SearchAndRedactSheet.shouldClearAppliedMarkers(
                newVersion: state.regionVersion + 1,
                lastAppliedVersion: state.lastAppliedSearchRegionVersion,
                isEmpty: search.appliedResultIDs.isEmpty
            ) == true
        )
    }
}
