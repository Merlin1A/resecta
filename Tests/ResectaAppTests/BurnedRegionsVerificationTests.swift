import Testing
import Foundation
import CoreGraphics
@testable import ResectaApp
@testable import RedactionEngine

// Verification checks the regions the run burned, as burned into each
// page (clamped to the page, boxes under the size floor dropped), never
// the editor's live regions as they stand when verification starts. A
// live region that differs from the burned set, here one added on a page
// the run did not burn, must not reach the checks: a report that credits
// a box the file does not have reads as covered when it is not.
// `beforeVerificationLoadsSeam` changes the live regions as verification
// starts; `verificationRegionsSeam` observes what the checks receive.

@Suite("Verification reads the burned regions", .tags(.coordination))
@MainActor
struct BurnedRegionsVerificationTests {

    private func region(_ rect: CGRect) -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: rect, source: .manual)
    }

    @Test("A live region added as verification starts, and a box the burn dropped, never reach the checks",
          .timeLimit(.minutes(2)))
    func verificationReceivesTheBurnedSet() async throws {
        let coord = makeLoadedCoordinator(document: makeMultiPagePDFDocument(pages: 2))
        let burned = region(CGRect(x: 0.1, y: 0.8, width: 0.8, height: 0.05))
        let underTheFloor = region(CGRect(x: 0.5, y: 0.5, width: 0.0005, height: 0.0005))
        coord.redactionState.addRegion(burned, page: 0, undoManager: nil)
        coord.redactionState.addRegion(underTheFloor, page: 0, undoManager: nil)
        let unburned = region(CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.1))

        coord.beforeVerificationLoadsSeam = { [weak coord] in
            // A live change the run did not burn, made without the edit
            // path's output reset (the gap a mid-run undo or redo opened).
            coord?.redactionState.regions[1] = [unburned]
        }
        var received: [Int: [RedactionRegion]]?
        coord.verificationRegionsSeam = { received = $0 }

        coord.runFullPipeline(documentOverride: .secureRasterization)
        let task = try #require(coord.documentState.activePipelineTask, "the run started")
        await task.value

        let regions = try #require(received, "verification ran its checks (else it failed earlier: simulator resources)")
        #expect(regions[1] == nil, "a region on a page the run did not burn reached the checks")
        #expect(regions[0]?.map(\.id) == [burned.id],
                "page 1's checks receive the burned box only, not the one under the size floor")
    }
}
