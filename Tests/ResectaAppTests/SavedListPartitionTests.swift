import Testing
import Foundation
// PIICategory (the full default detector set) lives in the engine.
import RedactionEngine
@testable import ResectaApp

// Typed saved lists: the bookmark entry point lists entries for the
// ACTIVE interface only — Search lists text / regex / multi-term
// shapes, Scan lists saved scans. One store and one file underneath;
// the partition is a read-side filter on each entry's persisted mode
// (whose frozen wire value carries interface identity), so the schema
// is untouched and nothing migrates. Recall stays same-interface by
// construction: the list only offers the active interface's entries.

@Suite("Saved-list partition (typed per interface)")
@MainActor
struct SavedListPartitionTests {

    private func entry(_ name: String, mode: SearchModeType) -> SavedSearch {
        SavedSearch(name: name, mode: mode, queryText: mode == .piiScan ? nil : "q")
    }

    @Test("Search side lists text/regex/multiTerm; Scan side lists scan entries")
    func partitionByInterface() {
        let all = [
            entry("t", mode: .text),
            entry("s1", mode: .piiScan),
            entry("r", mode: .regex),
            entry("m", mode: .multiTerm),
            entry("s2", mode: .piiScan),
        ]

        let searchSide = SavedSearchListSheet.visibleEntries(all, interface: .search)
        #expect(searchSide.map(\.name) == ["t", "r", "m"],
                "store order is preserved within the partition")
        #expect(searchSide.allSatisfy { $0.mode.interface == .search })

        let scanSide = SavedSearchListSheet.visibleEntries(all, interface: .scan)
        #expect(scanSide.map(\.name) == ["s1", "s2"])
        #expect(scanSide.allSatisfy { $0.mode == .piiScan })
    }

    @Test("An empty partition is empty even when the other side has entries")
    func emptyPartitionIndependent() {
        let all = [entry("t", mode: .text)]
        #expect(SavedSearchListSheet.visibleEntries(all, interface: .scan).isEmpty)
        #expect(SavedSearchListSheet.visibleEntries([], interface: .search).isEmpty)
    }

    @Test("List chrome is interface-aware and names the other side honestly")
    func chromePerInterface() {
        #expect(SavedSearchListSheet.sectionHeader(for: .search) == "Saved Searches")
        #expect(SavedSearchListSheet.sectionHeader(for: .scan) == "Saved Scans")
        #expect(SavedSearchListSheet.emptyStateTitle(for: .search) == "No Saved Searches")
        #expect(SavedSearchListSheet.emptyStateTitle(for: .scan) == "No Saved Scans")
        // The empty states point at the other side so a user whose
        // entries "vanished" learns where they are listed.
        #expect(SavedSearchListSheet.emptyStateDescription(for: .search).contains("Scan side"))
        #expect(SavedSearchListSheet.emptyStateDescription(for: .scan).contains("Search side"))
        #expect(SavedSearchListSheet.saveCurrentLabel(for: .search) == "Save current search…")
        #expect(SavedSearchListSheet.saveCurrentLabel(for: .scan) == "Save current scan…")
    }

    @Test("Save-prompt chrome follows the interface whose shape it captures")
    func savePromptChromePerInterface() {
        #expect(SavedSearchListSheet.savePromptTitle(for: .search) == "Save Current Search")
        #expect(SavedSearchListSheet.savePromptTitle(for: .scan) == "Save Current Scan")
        #expect(SavedSearchListSheet.savePromptMessage(for: .search)
                == "Saves the current query shape — mode, query text, and filter settings. Never document content or results.")
        #expect(SavedSearchListSheet.savePromptMessage(for: .scan)
                == "Saves the current scan shape — selected categories and options. Never document content or results.")
    }

    @Test("Recall round-trip stays interface-correct for both entry kinds")
    func recallRoundTripPerInterface() {
        // A scan entry recalls into the Scan interface's machinery.
        let scanEntry = SavedSearch(
            name: "weekly", mode: .piiScan,
            enabledPIICategories: [.ssn, .email])
        let state = SearchState()
        state.searchModeType = .piiScan
        SavedSearchListSheet.apply(scanEntry, to: state)
        #expect(state.searchModeType == .piiScan)
        #expect(state.searchModeType.interface == .scan)
        // D-63/UT-05: with the category strip dark (the shipped 1.0
        // state, and this test process — no reveal arg), recall keeps
        // the full default set; the narrowed field persists but is
        // not applied. The dedicated no-narrow pin below carries the
        // full contract.
        #expect(state.enabledPIICategories == Set(PIICategory.allCases))
        #expect(state.isProgrammaticModeChange == false,
                "same-mode recall must not arm the programmatic flag — the hub's mode-switch handler is its only consumer and would never reset a stale true")

        // A text entry recalls into Search, arming the programmatic flag
        // only because the mode actually changes (text ← piiScan here).
        let textEntry = SavedSearch(name: "needle", mode: .text, queryText: "needle")
        SavedSearchListSheet.apply(textEntry, to: state)
        #expect(state.searchModeType == .text)
        #expect(state.searchModeType.interface == .search)
        #expect(state.queryText == "needle")
        #expect(state.isProgrammaticModeChange == true)
    }

    @Test("Recall does not narrow detectors while the category strip is dark (D-63/UT-05)")
    func recallDoesNotNarrowWhileStripDark() {
        // Premise guard: this process launches without the DEBUG
        // reveal arg, so the strip is dark — the shipped 1.0 state.
        #expect(!SearchState.scanCategoryStripEnabled,
                "test process unexpectedly running with --showRetiredSheetControls — this pin exercises the shipped flag-dark path")

        let narrowed = SavedSearch(
            name: "ssn-only", mode: .piiScan,
            enabledPIICategories: [.ssn],
            caseSensitive: true,
            includeOCR: false)
        let state = SearchState()
        state.searchModeType = .piiScan

        SavedSearchListSheet.apply(narrowed, to: state)

        // The hazard (E6): a narrowed set silently restricting the
        // next scan with zero UI readout. While dark, recall keeps
        // the full default set…
        #expect(state.enabledPIICategories == Set(PIICategory.allCases),
                "recall narrowed the detector set while the chips strip is dark — the next scan would silently skip detectors with no UI readout")
        // …and the persisted field itself is untouched (schema and
        // codec unchanged — restore revives with the flag).
        #expect(narrowed.enabledPIICategories == [.ssn])
        // The rest of the shape still restores exactly as before.
        #expect(state.options.caseSensitive == true)
        #expect(state.options.includeOCR == false)
    }

    @Test("Capture is interface-correct by construction — the active mode is the entry's list key")
    func captureFollowsActiveInterface() {
        let state = SearchState()
        state.searchModeType = .piiScan
        let captured = SavedSearchListSheet.capture(from: state, name: "mine")
        #expect(captured.mode == .piiScan)
        #expect(SavedSearchListSheet.visibleEntries([captured], interface: .scan).count == 1)
        #expect(SavedSearchListSheet.visibleEntries([captured], interface: .search).isEmpty)
    }
}
