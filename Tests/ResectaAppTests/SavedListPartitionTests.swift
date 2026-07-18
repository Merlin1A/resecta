import Testing
import Foundation
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
        #expect(state.enabledPIICategories == [.ssn, .email])
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
