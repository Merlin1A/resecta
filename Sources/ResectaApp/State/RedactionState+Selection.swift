import Foundation
import RedactionEngine

// Selection rules read by more than one surface.

extension RedactionState {

    /// The one Select All on Page gate (both menus, the long-press menu,
    /// Command-A): the page holds a region not yet selected.
    func canSelectAllOnPage(_ page: Int) -> Bool {
        (regions[page] ?? []).contains { !selectedRegionIDs.contains($0.id) }
    }
}
