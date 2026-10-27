import Testing
import Foundation
import CoreGraphics
@testable import ResectaApp
@testable import RedactionEngine

// A Stop, or leaving the app, in the moment after the redacted copy is
// built and before verification reports its first layer. The copy is
// complete and its run's inputs are recorded, and the undo history was
// cleared when the copy was registered — so the Stop must keep the copy
// and land on the results as a skipped verification, never discard it.
// The DEBUG seam `beforeVerificationLoadsSeam` fires on the run's task as
// verification starts, before its detached loads; Stop is taken from it.

@Suite("Stop after the redacted copy is built", .tags(.coordination))
@MainActor
struct StopAfterTheCopyTests {

    private func addRegion(to coord: PipelineCoordinator) {
        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.1, y: 0.8, width: 0.8, height: 0.05),
            source: .manual)
        coord.redactionState.addRegion(region, page: 0, undoManager: nil)
    }

    @Test("A Stop as verification starts keeps the built copy and shows the results as skipped",
          .timeLimit(.minutes(2)))
    func stopAsVerificationStartsKeepsTheCopy() async throws {
        let coord = makeLoadedCoordinator()
        addRegion(to: coord)
        var seamFired = false
        coord.beforeVerificationLoadsSeam = { [weak coord] in
            guard let coord else { return }
            seamFired = true
            coord.documentState.cancelActivePipeline(redactionState: coord.redactionState)
        }

        coord.runFullPipeline(documentOverride: .secureRasterization)
        let task = try #require(coord.documentState.activePipelineTask, "the run started")
        await task.value

        #expect(seamFired, "the run reached verification (else it failed earlier: simulator resources)")
        let output = try #require(coord.redactionState.outputURL, "the built copy was discarded by the Stop")
        #expect(FileManager.default.fileExists(atPath: output.path), "the copy's file is gone")
        guard case .verified(let report) = coord.documentState.phase else {
            Issue.record("expected the results, got \(coord.documentState.phaseKind)")
            return
        }
        #expect(report.skipReason == .cancelled, "the results name the Stop as the cause")
        #expect(coord.redactionState.isVerificationStale == false,
                "the copy carries every region on screen: it is current for its run")
        #expect(coord.redactionState.lastRunInputs != nil, "the run's inputs stay beside the copy")
    }
}
