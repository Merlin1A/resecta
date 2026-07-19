import Testing
import SwiftUI
import UIKit
import RedactionEngine
@testable import ResectaApp

// q10 / UXF-01 — in-process regression guards for the SearchState
// cache-in-getter observation crash, hosted over the REAL results List.
//
// The crash: the search-sheet apply runs
// `appliedResultIDs.formUnion`, whose `didSet` calls
// `invalidateFilterCaches()`; the next List body evaluation recomputes a
// grouping getter (`resultsByPage` / `resultsByTerm` / `resultsByCategory`)
// and WRITES its backing cache var mid-body-evaluation. With those vars
// observation-wrapped, the write fired `ObservationRegistrar.willSet` inside
// the in-flight GraphHost transaction → `AG::precondition_failure` (SIGABRT).
// The fix marks the 8 backing cache/key vars (and RedactionState's
// `_cachedEffectiveCount`) `@ObservationIgnored`.
//
// These tests host `SearchResultsSection` — the exact view the crash lived
// in — inside a scene-attached key UIWindow, pump the run loop so the
// hosted List evaluates, then replay the confirm handler's mutation
// (`appliedResultIDs.formUnion`, SearchAndRedactSheet's Mark-for-Redaction
// action) and pump again, asserting the regrouped getters stay consistent
// for every branch.
//
// SCOPE HONESTY (verified by stash-revert on 2026-07-04): this hosted
// harness does NOT reproduce the pre-fix SIGABRT — the abort needs the
// production graph topology (sheet + toolbar + sibling observers inside one
// GraphHost transaction), and the pre-fix source ran these tests green. The
// crash itself is pinned red-on-old by `SearchMarkForRedactionUITests`
// (page + term branches through the real app flow). What THIS suite adds:
// grouping-consistency checks across the List's branches, and the
// cache-hit dependency-registration contract below. (s07's state-level
// SearchRedactIntegrationTests stayed green under the bug — a state-level
// test cannot pin it; these at least put a live hosted List body over the
// getters.)
//
// UP-5 deleted the category-grouped List branch (and its `.category` case
// here); piiScan results always group by page now. `resultsByCategory`
// itself stays (chips + "Select where…" consume it) — its cache vars keep
// the same @ObservationIgnored treatment, exercised through the surviving
// branches' shared invalidation path.

@Suite("Search results List observation crash (q10)", .tags(.search))
@MainActor
struct SearchResultsListObservationCrashTests {

    /// The grouping branches the List renders
    /// (`SearchResultsSection.list(useTermGrouping:isMultiTerm:...)`).
    enum GroupingBranch: String, CaseIterable, Sendable {
        case page, term
    }

    @Test("Mark-for-Redaction mutation under a live List body does not crash", arguments: GroupingBranch.allCases)
    func formUnionUnderLiveListBody(branch: GroupingBranch) async throws {
        let searchState = makeSearchState(for: branch)
        let host = hostResultsSection(searchState: searchState)

        // Commit an initial body evaluation so the observation graph holds a
        // live dependency set over the grouping getter this branch reads.
        host.window.layoutIfNeeded()
        pumpRunLoop()

        // Replay the toolbar Apply handler's state mutation
        // (SearchAndRedactSheet: appliedResultIDs.formUnion(selectedIDs)).
        // didSet → invalidateFilterCaches() → the next body evaluation
        // recomputes and writes the branch's cache (the crash site in the
        // production topology — see the scope-honesty note above).
        let selectedIDs = Set(searchState.results.filter(\.isSelected).map(\.id))
        #expect(!selectedIDs.isEmpty)
        searchState.appliedResultIDs.formUnion(selectedIDs)

        host.window.layoutIfNeeded()
        pumpRunLoop()

        // Surviving the pump IS the regression assertion. Sanity-check the
        // regrouped getters so a silent grouping regression can't hide here.
        switch branch {
        case .page:
            #expect(searchState.resultsByPage.keys.sorted() == [0, 1])
        case .term:
            #expect(searchState.resultsByTerm.keys.sorted() == ["alpha", "beta"])
        }
        #expect(searchState.appliedResultIDs == selectedIDs)

        host.window.isHidden = true
    }

    /// RedactionState carries the structurally identical pattern:
    /// `effectiveRegionCount` writes `_cachedEffectiveCount` on a miss. With
    /// the cache var `@ObservationIgnored`, the getter must register its
    /// tracking dependency through the observed `regions` read on EVERY
    /// access — including cache hits — or views stop updating on region
    /// mutations. Pin both halves: cache-hit reads still fire onChange, and
    /// the recomputed count is correct.
    @Test("effectiveRegionCount cache hit still registers regions dependency")
    func effectiveRegionCountTracksRegionsOnCacheHit() async {
        let redactionState = RedactionState()
        redactionState.addRegion(
            makeRegion(x: 0.1), page: 0, undoManager: nil)

        // Prime the cache so the tracked read below is a cache HIT.
        #expect(redactionState.effectiveRegionCount == 1)

        // willSet fires synchronously inside addRegion's regions mutation,
        // so the confirmation resolves before the closure returns.
        await confirmation("onChange fires for a cache-hit read") { fired in
            withObservationTracking {
                _ = redactionState.effectiveRegionCount
            } onChange: {
                fired()
            }
            redactionState.addRegion(
                makeRegion(x: 0.3), page: 0, undoManager: nil)
        }

        #expect(redactionState.effectiveRegionCount == 2)
    }

    // MARK: - Hosting

    private struct Host {
        let window: UIWindow
        let controller: UIHostingController<AnyView>
    }

    /// Host the real `SearchResultsSection` in a key window so List body
    /// evaluations run inside genuine SwiftUI graph transactions.
    private func hostResultsSection(searchState: SearchState) -> Host {
        let section = SearchResultsSection(
            searchState: searchState,
            selectedDetent: .constant(.large),
            onRequestWhy: { _ in },
            onApplyShortcut: {},
            applyShortcutEnabled: true,
            onRequestShowRationale: { _ in },
            onTriggerSearch: {},
            onRecallQuery: { _ in }
        )
        .environment(DocumentState())
        .environment(RedactionState())
        .environment(SettingsState())
        .environment(ToastQueueManager())

        let controller = UIHostingController(rootView: AnyView(section))
        // Attach to the test host's REAL window scene — a bare
        // UIWindow(frame:) never joins the render loop in a scene-based
        // app, and the crash lives in the live GraphHost transaction, not
        // in offscreen layout.
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        let window: UIWindow
        if let scene {
            window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        }
        window.rootViewController = controller
        window.makeKeyAndVisible()
        return Host(window: window, controller: controller)
    }

    /// Give the SwiftUI render loop a chance to commit the pending update
    /// transaction (the crash fires inside that commit, not at mutation time).
    private func pumpRunLoop(_ interval: TimeInterval = 0.25) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: interval))
    }

    // MARK: - Seeding

    /// Build a SearchState whose mode + grouping flags drive the requested
    /// List branch, with pre-selected synthetic results (the confirm handler
    /// operates on `isSelected` rows).
    private func makeSearchState(for branch: GroupingBranch) -> SearchState {
        let state = SearchState(defaults: UserDefaults(suiteName: "q10-observation-\(branch.rawValue)")!)
        switch branch {
        case .page:
            state.searchModeType = .text
            state.results = [
                makeResult(pageIndex: 0, term: "alpha"),
                makeResult(pageIndex: 1, term: "alpha"),
            ]
        case .term:
            state.searchModeType = .multiTerm
            state.searchTerms = ["alpha", "beta"]
            state.groupByTerm = true
            state.results = [
                makeResult(pageIndex: 0, term: "alpha"),
                makeResult(pageIndex: 0, term: "beta"),
            ]
        }
        return state
    }

    private func makeResult(
        pageIndex: Int,
        term: String
    ) -> SearchResult {
        SearchResult(
            pageIndex: pageIndex,
            normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.04),
            matchedText: "synthetic",
            contextSnippet: "…synthetic context…",
            source: .textLayer,
            term: term,
            isSelected: true
        )
    }

    private func makeRegion(x: CGFloat) -> RedactionRegion {
        RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: x, y: 0.1, width: 0.1, height: 0.05),
            source: .manual
        )
    }
}
