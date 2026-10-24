import Testing
import Foundation
@testable import ResectaApp

// Test-only invariants of the region state, checked at the end of every
// mutation case in the selection suites: the selection holds only live
// region ids, and the region-to-page index matches the regions exactly.

extension RedactionState {

    func checkInvariants(sourceLocation: SourceLocation = #_sourceLocation) {
        var index: [UUID: Int] = [:]
        for (page, pageRegions) in regions {
            for region in pageRegions { index[region.id] = page }
        }
        #expect(selectedRegionIDs.isSubset(of: Set(index.keys)),
                "the selection holds only live region ids", sourceLocation: sourceLocation)
        #expect(regionPageIndex == index,
                "the region-to-page index matches the regions", sourceLocation: sourceLocation)
    }
}
