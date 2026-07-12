import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// GAP §14.1a — Detection pipeline guard tests.

@Suite("Detection Pipeline Guards")
@MainActor
struct DetectionPipelineTests {

    @Test("Detection blocked while triage is pending (F-3)")
    func pendingTriageGuard() {
        let coordinator = makeCoordinator()
        coordinator.redactionState.pendingTriage = [0: [.mock()]]

        coordinator.runDetectionPipeline()

        // Guard should prevent pipeline from starting
        #expect(coordinator.documentState.activePipelineTask == nil,
                "Pipeline should not start when triage is pending")
    }

    @Test("Detection blocked while another pipeline task is active")
    func activePipelineTaskGuard() {
        let coordinator = makeCoordinator()
        // Simulate an active task
        coordinator.documentState.activePipelineTask = Task {}

        coordinator.runDetectionPipeline()

        // The existing task should not be replaced
        // (The guard returns early without modifying state)
        #expect(coordinator.documentState.phaseKind == .empty,
                "Phase should remain unchanged when guard blocks")

        // Clean up
        coordinator.documentState.activePipelineTask?.cancel()
        coordinator.documentState.activePipelineTask = nil
    }
}
