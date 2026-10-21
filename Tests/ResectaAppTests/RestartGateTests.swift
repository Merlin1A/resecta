import Testing
import Foundation
import CoreGraphics
@testable import ResectaApp
@testable import RedactionEngine

// The resume banner's Restart (and every other programmatic entry) runs the
// pipeline through `runFullPipeline`, which tears the live search session
// down at its funnel. The Redact button and ⇧⌘R are gated while that
// session holds selections the user has not applied; this pins that the
// funnel itself holds the same gate, so Restart cannot drop them either.

@Suite("Restart passes the Redact gate", .tags(.search, .coordination))
@MainActor
struct RestartGateTests {

    private func addRegion(to coord: PipelineCoordinator) {
        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.1, y: 0.8, width: 0.8, height: 0.05),
            source: .manual)
        coord.redactionState.addRegion(region, page: 0, undoManager: nil)
    }

    @Test("A session holding selections the user touched survives a programmatic run entry, and no run starts",
          .timeLimit(.minutes(1)))
    func pendingSelectionsSurviveTheEntry() async throws {
        let coord = makeLoadedCoordinator()
        addRegion(to: coord)
        let search = SearchState()
        search.userModifiedSelections = true
        coord.redactionState.activeSearch = search

        coord.runFullPipeline(documentOverride: .secureRasterization)
        try await Task.sleep(for: .milliseconds(200))

        #expect(coord.redactionState.activeSearch === search, "the session is not torn down")
        #expect(coord.documentState.activePipelineTask == nil, "no run started over the pending selections")
        #expect(coord.documentState.phaseKind == .editing)
    }

    @Test("An untouched session does not hold the entry", .timeLimit(.minutes(1)))
    func untouchedSessionDoesNotHold() async throws {
        let coord = makeLoadedCoordinator()
        addRegion(to: coord)
        coord.redactionState.activeSearch = SearchState()

        coord.runFullPipeline(documentOverride: .secureRasterization)
        let task = coord.documentState.activePipelineTask
        #expect(task != nil, "the run started")
        #expect(coord.redactionState.activeSearch == nil, "the funnel tore the untouched session down")
        coord.documentState.cancelActivePipeline(redactionState: coord.redactionState)
        await task?.value
    }
}
