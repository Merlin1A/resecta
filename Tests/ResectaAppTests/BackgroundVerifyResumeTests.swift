import Testing
import Foundation
import CoreGraphics
@testable import ResectaApp
@testable import RedactionEngine

// Leaving the app while the checks run. The scene's background handler
// cancels the run. A cut Verify returns to the editor with the paused
// notice, whose Restart runs Redact and the checks again, the same way a
// cut Scan or Redact does; it does not land on the results as skipped. A
// Stop from the toolbar still lands on the skipped results, and a cut Scan
// or Redact behaves as before.

@Suite("Leaving the app mid-verify: the paused notice", .tags(.coordination))
@MainActor
struct BackgroundVerifyResumeTests {

    private static var verifyingPhase: DocumentState.Phase {
        .verifying(progress: .init(
            currentLayer: 1, totalLayers: 5, layerName: "Layer 1", completedLayers: []))
    }

    private struct Fixture {
        let coord: PipelineCoordinator
        let output: URL
        let root: URL
        let task: Task<Void, Never>
    }

    private func drawnRegion() -> RedactionRegion {
        RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.1, y: 0.8, width: 0.8, height: 0.05),
            source: .manual)
    }

    /// A run that redacted the live regions and is now verifying: the
    /// run's own events in the runner's order, handed to the coordinator's
    /// adapter, with the run holding its task as a real run does.
    private func verifyingRun() throws -> Fixture {
        let coord = makeLoadedCoordinator()
        coord.redactionState.addRegion(drawnRegion(), page: 0, undoManager: nil)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("background_verify_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let output = root.appendingPathComponent("redacted_\(UUID().uuidString).pdf")
        try makeTestPDFData().write(to: output)

        coord.apply(.runStarted(effectiveMode: .secureRasterization))
        coord.apply(.phase(.redacting(progress: .init(currentPage: 0, totalPages: 1, currentStep: "Page 1…"))))
        coord.apply(.outputRegistered(output))
        coord.apply(.redactionFinished(
            outputURL: output,
            inputs: .fixture(burnedRegionVersion: coord.redactionState.regionVersion)))
        coord.apply(.phase(Self.verifyingPhase))

        let task = Task<Void, Never> { while !Task.isCancelled { await Task.yield() } }
        coord.documentState.activeRunId = UUID()
        coord.documentState.activePipelineTask = task
        return Fixture(coord: coord, output: output, root: root, task: task)
    }

    @Test("A verify cut by leaving the app returns to the editor with the paused notice, not a skipped report",
          .timeLimit(.minutes(1)))
    func backgroundMidVerifyRaisesThePausedNotice() async throws {
        let f = try verifyingRun()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let doc = f.coord.documentState

        ContentView.cancelForBackground(documentState: doc, redactionState: f.coord.redactionState)

        #expect(f.task.isCancelled, "the checks stopped")
        if case .verified(let report) = doc.phase {
            Issue.record("landed on the results as \(report.overallStatus), reason \(String(describing: report.skipReason))")
        }
        #expect(doc.phaseKind == .editing, "back in the editor")
        #expect(doc.wasPausedByBackground)
        #expect(doc.pausedFromPhase == .verifying)
        #expect(TopBannerSlot.winner(documentState: doc, detectionBannerPresent: false) == .paused,
                "the paused notice takes the editor's top slot")
        #expect(doc.redactRefusal(with: f.coord.redactionState) == nil,
                "the notice's Restart is not refused")
        #expect(f.coord.redactionState.outputURL == f.output, "the built copy is kept")
        _ = await f.task.value
    }

    @Test("The paused notice's Restart after a cut verify starts the run again", .timeLimit(.minutes(1)))
    func restartAfterACutVerifyStartsARun() async throws {
        let f = try verifyingRun()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let doc = f.coord.documentState
        ContentView.cancelForBackground(documentState: doc, redactionState: f.coord.redactionState)
        _ = await f.task.value
        // The cancel's awaiter observes the cut task's end on the MainActor.
        await Task.yield()

        // The notice's primary action, as `resumeBannerOverlay` runs it.
        DocumentEditorView.clearBackgroundPause(doc)
        f.coord.runFullPipeline(documentOverride: .secureRasterization)

        let restarted = try #require(doc.activePipelineTask, "Restart started a run")
        doc.cancelActivePipeline(redactionState: f.coord.redactionState)
        _ = await restarted.value
    }

    @Test("A real run cut by leaving the app as its checks start returns to the editor with the paused notice",
          .timeLimit(.minutes(2)))
    func realRunBackgroundedAsTheChecksStart() async throws {
        let coord = makeLoadedCoordinator()
        coord.redactionState.addRegion(drawnRegion(), page: 0, undoManager: nil)
        var seamFired = false
        coord.beforeVerificationLoadsSeam = { [weak coord] in
            guard let coord else { return }
            seamFired = true
            ContentView.cancelForBackground(
                documentState: coord.documentState, redactionState: coord.redactionState)
        }

        coord.runFullPipeline(documentOverride: .secureRasterization)
        let task = try #require(coord.documentState.activePipelineTask, "the run started")
        await task.value

        #expect(seamFired, "the run reached verification (else it failed earlier: simulator resources)")
        let doc = coord.documentState
        if case .verified(let report) = doc.phase {
            Issue.record("landed on the results as \(report.overallStatus), reason \(String(describing: report.skipReason))")
        }
        #expect(doc.phaseKind == .editing)
        #expect(doc.wasPausedByBackground)
        #expect(doc.pausedFromPhase == .verifying)
        #expect(TopBannerSlot.winner(documentState: doc, detectionBannerPresent: false) == .paused)
        #expect(coord.redactionState.regions[0]?.count == 1, "the regions are untouched")
    }

    // MARK: - Unchanged paths

    @Test("A Stop mid-verify still lands on the results as skipped, with no paused notice",
          .timeLimit(.minutes(1)))
    func stopMidVerifyStillLandsOnSkipped() async throws {
        let f = try verifyingRun()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let doc = f.coord.documentState

        doc.cancelActivePipeline(redactionState: f.coord.redactionState)

        guard case .verified(let report) = doc.phase else {
            Issue.record("expected the skipped results after a Stop, got \(doc.phaseKind)")
            return
        }
        #expect(report.skipReason == .cancelled)
        #expect(doc.wasPausedByBackground == false)
        #expect(doc.pausedFromPhase == nil)
        #expect(f.coord.redactionState.outputURL == f.output, "the built copy is kept")
        _ = await f.task.value
    }

    @Test("Leaving the app mid-scan still returns to the editor with the paused notice",
          .timeLimit(.minutes(1)))
    func backgroundMidScanIsUnchanged() async {
        let coord = makeLoadedCoordinator()
        let doc = coord.documentState
        doc.transition(to: .detecting(progress: .init(currentPage: 0, totalPages: 1, currentStep: "s")))
        let task = Task<Void, Never> { while !Task.isCancelled { await Task.yield() } }
        doc.activeRunId = UUID()
        doc.activePipelineTask = task

        ContentView.cancelForBackground(documentState: doc, redactionState: coord.redactionState)

        #expect(task.isCancelled)
        #expect(doc.phaseKind == .editing)
        #expect(doc.wasPausedByBackground)
        #expect(doc.pausedFromPhase == .detecting)
        #expect(TopBannerSlot.winner(documentState: doc, detectionBannerPresent: false) == .paused)
        _ = await task.value
    }

    @Test("Leaving the app mid-redact still discards the partial copy and raises the paused notice",
          .timeLimit(.minutes(1)))
    func backgroundMidRedactIsUnchanged() async throws {
        let coord = makeLoadedCoordinator()
        coord.redactionState.addRegion(drawnRegion(), page: 0, undoManager: nil)
        let doc = coord.documentState
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("background_redact_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("redacted_\(UUID().uuidString).pdf")
        try makeTestPDFData().write(to: output)
        coord.apply(.runStarted(effectiveMode: .secureRasterization))
        coord.apply(.phase(.redacting(progress: .init(currentPage: 0, totalPages: 1, currentStep: "Page 1…"))))
        coord.apply(.outputRegistered(output))
        let task = Task<Void, Never> { while !Task.isCancelled { await Task.yield() } }
        doc.activeRunId = UUID()
        doc.activePipelineTask = task

        ContentView.cancelForBackground(documentState: doc, redactionState: coord.redactionState)

        #expect(task.isCancelled)
        #expect(doc.phaseKind == .editing)
        #expect(doc.wasPausedByBackground)
        #expect(doc.pausedFromPhase == .redacting)
        #expect(coord.redactionState.outputURL == nil, "the partial copy is discarded")
        #expect(coord.redactionState.regions[0]?.count == 1, "the regions are untouched")
        _ = await task.value
    }
}
