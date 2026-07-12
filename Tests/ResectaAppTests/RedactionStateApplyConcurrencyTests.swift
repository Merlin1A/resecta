import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

@Suite("RedactionState.applySearchResults concurrency", .tags(.search))
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

        let outcome = await state.applySearchResults(undoManager: nil)

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

        // Production serializes apply via the parent sheet's `isApplying`
        // gate (Group 3, N-3). Mirror that here — back-to-back awaits on
        // a MainActor-isolated state observe the same contract: the
        // second call sees the first's regions and skips them as
        // overlaps.
        let resA = await state.applySearchResults(undoManager: nil)
        let resB = await state.applySearchResults(undoManager: nil)

        let applied = (resA?.applied ?? 0) + (resB?.applied ?? 0)
        let skipped = (resA?.skippedOverlaps ?? 0) + (resB?.skippedOverlaps ?? 0)
        #expect(applied + skipped == 100)
        #expect(state.appliedMatchAudit.count == applied)
    }

    // CAT-225: the suite lived in *ApplyConcurrencyTests* but every test ran a
    // serial path. This is the missing concurrent guard: two `async let`
    // applies of the same selected set. Production serializes apply via the
    // Search & Redact sheet's `isApplying` gate (Group 3, N-3), so this is an
    // ungated probe of the method's own concurrency contract. The deterministic
    // invariants — conservation (both calls account for every selected match)
    // and audit↔region consistency (one audit row per created region) — hold
    // regardless of interleaving. The load-bearing property is no-duplication:
    // a second apply must not re-add a match the first already committed.
    @Test("Concurrent apply does not duplicate regions; audit stays consistent")
    func concurrentApplyDoesNotDuplicateRegions() async {
        let state = RedactionState()
        let search = SearchState()
        let total = 50
        var results: [SearchResult] = []
        for i in 0..<total {
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

        // Launch both applies concurrently against the same activeSearch.
        async let a = state.applySearchResults(undoManager: nil)
        async let b = state.applySearchResults(undoManager: nil)
        let (ra, rb) = await (a, b)

        let applied = (ra?.applied ?? 0) + (rb?.applied ?? 0)
        let skipped = (ra?.skippedOverlaps ?? 0) + (rb?.skippedOverlaps ?? 0)
        let regionCount = state.regions.values.flatMap { $0 }.count

        // Conservation: each of the two calls processed all `total` selected
        // matches (applied or skipped-as-overlap). Holds under any interleaving.
        #expect(applied + skipped == 2 * total,
                "both calls must account for every selected match")
        // Audit↔region consistency: exactly one audit row per created region
        // (no prior regions were seeded, so all regions are search-sourced),
        // and the audit count equals the combined applied count. Both hold
        // under any interleaving, including the duplicating one below.
        #expect(state.appliedMatchAudit.count == regionCount,
                "appliedMatchAudit must have one entry per created region")
        #expect(state.appliedMatchAudit.count == applied,
                "audit count must equal the combined applied count")

        // No-duplication is the load-bearing property — and it does NOT hold
        // today. Each apply snapshots existing regions on the MainActor
        // (RedactionState.swift:851) *before* its off-main prepare, and the
        // write-back appends the prepared set with no re-check against live
        // regions (:862-869). With two async-let applies the second snapshots
        // before the first commits, so it re-adds every match → regionCount
        // becomes 2*total. Production never reaches this: the Search & Redact
        // sheet's `isApplying` gate serializes apply (Group 3, N-3). Per the
        // F18 protocol a revealed race is logged as a deferred-work ledger entry
        // (CAT-NEW-s18-1), not resolved here. isIntermittent because the
        // duplicating interleaving is scheduler-dependent.
        withKnownIssue(
            "CAT-NEW-s18-1: ungated concurrent apply duplicates regions via a stale pre-commit snapshot; production serializes via isApplying. Deferred to REPLAN.",
            isIntermittent: true
        ) {
            #expect(regionCount == total,
                    "concurrent apply must not duplicate regions (each match applied once)")
        }
    }
}

// D06-F1 — `applySearchResults` records the `regionVersion` it produces as a
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

    @Test("applySearchResults records the produced regionVersion as the high-water-mark")
    func applyRecordsHighWaterMark() async {
        let state = RedactionState()
        let search = SearchState()
        search.results = [selectedResult()]
        state.activeSearch = search

        // Pre-apply: counter at its initial 0, high-water-mark at the -1 sentinel.
        #expect(state.regionVersion == 0)
        #expect(state.lastAppliedSearchRegionVersion == -1)

        let outcome = await state.applySearchResults(undoManager: nil)

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

        _ = await state.applySearchResults(undoManager: nil)
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
