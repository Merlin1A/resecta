import Foundation
import RedactionEngine

// Selection rules and actions every surface calls (the toolbar's menus,
// Command-A and Escape, the long-press menu).

extension RedactionState {

    /// The one Select All on Page gate (both menus, the long-press menu,
    /// Command-A): the page holds a region not yet selected.
    func canSelectAllOnPage(_ page: Int) -> Bool {
        (regions[page] ?? []).contains { !selectedRegionIDs.contains($0.id) }
    }

    /// The one Select All on Page action: every region on the page, and
    /// only those.
    func selectAllOnPage(_ page: Int) {
        selectedRegionIDs = Set((regions[page] ?? []).map(\.id))
    }

    /// The one Deselect All action; an empty selection is not written.
    func deselectAllRegions() {
        guard !selectedRegionIDs.isEmpty else { return }
        selectedRegionIDs = []
    }
}
