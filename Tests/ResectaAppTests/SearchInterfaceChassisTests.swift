import Testing
import Foundation
import CoreGraphics
@testable import ResectaApp
@testable import RedactionEngine

// Two-interface chassis — the pure state contracts under the sheet's
// Scan · Search switcher:
//
// 1. Interface identity is a DERIVATION over `searchModeType` (the
//    scan mode IS the Scan interface's machinery), so persistence,
//    launch args, and saved-search recall need no second field.
// 2. The switcher's Search segment restores the LAST Search-side mode,
//    not a hard `.text` reset.
// 3. The toolbar Scan button's one-tap contract rides a one-shot
//    `pendingAutoRunScan` flag with a single consume site.
// 4. An empty category-chip selection means scan EVERYTHING
//    (`effectiveScanCategories`).
// 5. The retired per-run confidence slider no longer filters results —
//    `minimumPIIConfidence` is schema-compat state, not a filter input.

@Suite("Search interface chassis")
@MainActor
struct SearchInterfaceChassisTests {

    // MARK: - Interface derivation

    @Test("Every mode derives its interface: scan mode → Scan, the rest → Search")
    func interfaceDerivation() {
        #expect(SearchModeType.piiScan.interface == .scan)
        #expect(SearchModeType.text.interface == .search)
        #expect(SearchModeType.regex.interface == .search)
        #expect(SearchModeType.multiTerm.interface == .search)
    }

    @Test("Interface display names are the locked pair")
    func interfaceDisplayNames() {
        #expect(SearchInterface.scan.displayName == "Scan")
        #expect(SearchInterface.search.displayName == "Search")
    }

    @Test("The Search-side mode list excludes the scan mode and keeps picker order")
    func searchModeListExcludesScan() {
        #expect(SearchModeContainer.searchModes == [.text, .regex, .multiTerm])
        #expect(!SearchModeContainer.searchModes.contains(.piiScan))
    }

    // MARK: - Last Search-side mode (switcher round-trip)

    @Test("lastSearchSideMode defaults to text and tracks Search-side sets only")
    func lastSearchSideModeTracking() {
        let state = SearchState(defaults: UserDefaults(suiteName: "chassis-\(UUID().uuidString)")!)
        #expect(state.lastSearchSideMode == .text)

        state.searchModeType = .regex
        #expect(state.lastSearchSideMode == .regex)

        // Entering the Scan interface must not clobber the memory —
        // this is what makes the switcher's round-trip restore work.
        state.searchModeType = .piiScan
        #expect(state.lastSearchSideMode == .regex)

        state.searchModeType = .multiTerm
        #expect(state.lastSearchSideMode == .multiTerm)
    }

    // MARK: - One-tap auto-run flag

    @Test("pendingAutoRunScan defaults false and clear() drops an unconsumed arm")
    func pendingAutoRunScanLifecycle() {
        let state = SearchState(defaults: UserDefaults(suiteName: "chassis-\(UUID().uuidString)")!)
        #expect(!state.pendingAutoRunScan)

        state.pendingAutoRunScan = true
        state.clear()
        #expect(!state.pendingAutoRunScan,
                "An armed-but-unconsumed auto-run must not leak into the next sheet session.")
    }

    // MARK: - Empty selection = scan everything

    @Test("effectiveScanCategories maps an empty chip selection to the full set")
    func effectiveScanCategoriesEmptyMeansEverything() {
        let state = SearchState(defaults: UserDefaults(suiteName: "chassis-\(UUID().uuidString)")!)

        // Default: all enabled — effective set is identity.
        #expect(state.effectiveScanCategories == Set(PIICategory.allCases))

        // A narrowed selection passes through unchanged.
        state.enabledPIICategories = [.ssn, .email]
        #expect(state.effectiveScanCategories == [.ssn, .email])

        // Deselecting everything means scan everything — the one-tap
        // contract needs no configuration, so no selection maps to the
        // full category set rather than a no-op scan.
        state.enabledPIICategories = []
        #expect(state.effectiveScanCategories == Set(PIICategory.allCases))
    }

    // MARK: - Retired confidence post-filter

    @Test("minimumPIIConfidence no longer filters results (slider retired; preset is the one engine control)")
    func minimumPIIConfidenceDoesNotFilter() {
        let state = SearchState(defaults: UserDefaults(suiteName: "chassis-\(UUID().uuidString)")!)
        state.results = [
            makeResult(piiCategory: .ssn, piiConfidence: 0.55),
            makeResult(piiCategory: .email, piiConfidence: 0.95),
        ]
        state.minimumPIIConfidence = 0.90

        // Pre-chassis behavior filtered the 0.55 row out; every
        // above-threshold result the engine returns is now listed.
        #expect(state.filteredResults.count == 2)
        #expect(state.filteredCount == 2)
    }

    // MARK: - Helpers

    private func makeResult(
        piiCategory: PIICategory? = nil,
        piiConfidence: Double? = nil
    ) -> SearchResult {
        SearchResult(
            pageIndex: 0,
            normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.04),
            matchedText: "x",
            contextSnippet: "...",
            source: .textLayer,
            term: "x",
            isSelected: false,
            piiCategory: piiCategory,
            piiConfidence: piiConfidence
        )
    }
}
