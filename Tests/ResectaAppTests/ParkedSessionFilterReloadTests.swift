import Testing
import Foundation
@testable import ResectaApp

// A search session parked while Settings is open comes back reading the
// stored filter shape: Reset to Defaults in Settings removes it, so the
// restored session's filters read their defaults rather than the values
// it held before.
@Suite("Parked session filter reload", .tags(.search))
@MainActor
struct ParkedSessionFilterReloadTests {

    @Test("A reload after the stored shape was removed restores the default filters")
    func reloadAfterResetReadsTheDefaults() {
        let (defaults, _) = makeScratchDefaults()
        let state = SearchState(defaults: defaults)
        state.sourceFilter = .ocrOnly
        state.sortOrder = .pageAscending
        defaults.removeObject(forKey: SearchState.lastFilterKey)  // Reset to Defaults

        state.reloadFilterShape()

        #expect(state.sourceFilter == .all)
        #expect(state.sortOrder == .discoveryOrder)
    }
}
