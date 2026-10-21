import Testing
import Foundation
import CoreGraphics
@testable import ResectaApp
@testable import RedactionEngine

// A Stop that lands after the last page is appended, while the output is
// being finalized: the run is no longer the active one, so its later
// reports are dropped and its cancellation recovery is skipped — the
// promoted output must not be left behind in the session directory.
// The DEBUG seam `beforeOutputPromotionSeam` fires on the run's task just
// before the promotion; Stop is taken from it.

@Suite("Stop during the finalize", .tags(.coordination))
@MainActor
struct StopDuringFinalizeTests {

    private func addRegion(to coord: PipelineCoordinator) {
        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.1, y: 0.8, width: 0.8, height: 0.05),
            source: .manual)
        coord.redactionState.addRegion(region, page: 0, undoManager: nil)
    }

    @Test("A Stop taken after the last page is appended leaves no promoted output in the session directory",
          .timeLimit(.minutes(2)))
    func stopAfterTheLastPageLeavesNoOrphan() async throws {
        let coord = makeLoadedCoordinator()
        addRegion(to: coord)
        var seamFired = false
        coord.beforeOutputPromotionSeam = { [weak coord] in
            guard let coord else { return }
            seamFired = true
            coord.documentState.cancelActivePipeline(redactionState: coord.redactionState)
        }

        coord.runFullPipeline(documentOverride: .secureRasterization)
        let task = try #require(coord.documentState.activePipelineTask, "the run started")
        await task.value

        #expect(seamFired, "the run reached the promotion (else it failed earlier: simulator resources)")
        let sessionDirectory = try coord.tempExportDirectory.childURL(named: "probe").deletingLastPathComponent()
        let promoted = (try? FileManager.default.contentsOfDirectory(atPath: sessionDirectory.path))?
            .filter { $0.hasPrefix("redacted_") } ?? []
        #expect(promoted.isEmpty, "a promoted output survived the Stop: \(promoted)")
        #expect(coord.redactionState.outputURL == nil)
        #expect(coord.documentState.phaseKind == .editing)
    }
}
