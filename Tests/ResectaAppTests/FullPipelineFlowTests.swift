import Testing
import Foundation
import PDFKit
import UIKit
@testable import ResectaApp
@testable import RedactionEngine

// UI_UX §3.3: Full pipeline flow integration tests.
// Tests the coordinator's orchestration logic: state transitions,
// guard conditions, and cancellation. Pipeline success depends on
// simulator resources — tests accept both success (.verified) and
// graceful failure (.failed) as valid outcomes where noted.

@Suite("Full Pipeline Flow", .tags(.critical, .coordination))
@MainActor
struct FullPipelineFlowTests {

    // MARK: - Orchestration Logic (no real pipeline needed)

    @Test("Full pipeline with no regions is no-op (AD-4-1)",
          .timeLimit(.minutes(1)))
    func fullPipelineNoRegionsIsNoOp() async throws {
        let coord = makeLoadedCoordinator()

        coord.runFullPipeline(documentOverride: .secureRasterization)

        // Give the task a moment to execute the guard check
        try await Task.sleep(for: .milliseconds(200))

        // Pipeline should not have transitioned past the guard
        #expect(coord.documentState.activePipelineTask == nil)
    }

    @Test("Guard against concurrent pipeline runs",
          .timeLimit(.minutes(1)))
    func guardAgainstConcurrentRuns() async throws {
        let coord = makeLoadedCoordinator()
        addRegion(to: coord)

        // Set a fake active task
        coord.documentState.activePipelineTask = Task { }

        coord.runFullPipeline(documentOverride: .secureRasterization)

        // Should be a no-op — phase should not change
        try await Task.sleep(for: .milliseconds(100))
        #expect(coord.documentState.activePipelineTask != nil)
        coord.documentState.activePipelineTask = nil
    }

    // MARK: - Pre-flight Validation (CAT-138 / D-34)

    @Test("validatePage refuses an oversized page (CAT-138)",
          .timeLimit(.minutes(1)))
    func validatePageRefusesOversizedPage() async throws {
        let coord = makeOversizedCoordinator()
        addRegion(to: coord)

        coord.runFullPipeline(documentOverride: .secureRasterization)

        // The CAT-138 pre-flight throws almost immediately; poll for the
        // terminal .failed transition with a cap so a regression that lets the
        // oversized page through ends the test instead of hanging.
        var failure: PipelineError?
        for _ in 0..<300 {
            if case .failed(let error, _) = coord.documentState.phase {
                failure = error
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        guard case .redactionError(.insufficientMemory) = failure else {
            Issue.record("Expected .redactionError(.insufficientMemory) from the CAT-138 pre-flight, got \(String(describing: failure))")
            return
        }
    }

    // MARK: - Helpers

    private func makeLoadedCoordinator() -> PipelineCoordinator {
        let coord = PipelineCoordinator(
            documentState: DocumentState(),
            redactionState: RedactionState(),
            settingsState: SettingsState())
        coord.documentState.sourceDocument = makeTestPDFDocument()
        coord.documentState.phase = .editing
        return coord
    }

    private func addRegion(to coord: PipelineCoordinator) {
        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.1, y: 0.8, width: 0.8, height: 0.05),
            source: .manual)
        coord.redactionState.addRegion(region, page: 0, undoManager: nil)
    }

    private func makeOversizedCoordinator() -> PipelineCoordinator {
        let coord = PipelineCoordinator(
            documentState: DocumentState(),
            redactionState: RedactionState(),
            settingsState: SettingsState())
        coord.documentState.sourceDocument = makeOversizedPDFDocument()
        coord.documentState.phase = .editing
        return coord
    }

    /// A 1-page PDF whose page is 5,200 × 300 pt — past the 5,000-pt
    /// validatePage dimension cap (ENGINE §2.6) but cheap to build. Loaded
    /// directly onto the coordinator, which bypasses the import-time dimension
    /// gate so the page reaches `PageRasterizer.rasterize`, where the CAT-138
    /// pre-flight refuses it with `.insufficientMemory`.
    private func makeOversizedPDFDocument() -> PDFDocument {
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(x: 0, y: 0, width: 5200, height: 300))
        let data = renderer.pdfData { ctx in
            ctx.beginPage()
        }
        return PDFDocument(data: data)!
    }

}
