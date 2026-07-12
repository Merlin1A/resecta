import Testing
import Foundation
import PDFKit
import UIKit
import CoreGraphics
@testable import ResectaApp
@testable import RedactionEngine

// Failure-stage recovery classification.
//
// `runFullPipeline`'s generic error handler used to discriminate
// "redaction failed" from "verification crashed" by `outputURL` presence.
// CANCEL-008 moved the `outputURL` registration BEFORE `processDocument`
// (eager, to close an orphaned-file leak), which made that check true for
// every throw after run start — all redaction-stage failures took the
// "output is valid" branch: `clearOutput()` was skipped and "Return to
// Results" landed on a skipped-verification results screen for a run whose
// redaction failed and whose output file was never promoted. The handler
// now classifies by the error's STAGE; these tests pin the classifier
// table and the two recovery routes.

@Suite("Pipeline failure-stage recovery", .tags(.coordination))
@MainActor
struct PipelineFailureStageTests {

    // MARK: - Classifier table

    @Test("Pre-promotion stage errors classify as .redaction",
          arguments: [
            PipelineError.importError(.corrupt),
            PipelineError.importError(.tooLarge(bytesRead: 100_000_000)),
            PipelineError.detectionError(.visionError(pageIndex: 0)),
            PipelineError.redactionError(.fillVerificationFailed(pageIndex: 3)),
            PipelineError.redactionError(.pageTooLarge(pageIndex: 0)),
            PipelineError.redactionError(.bitmapCreationFailed(pageIndex: 1)),
            PipelineError.redactionError(.insufficientMemory(pageIndex: 0)),
            PipelineError.redactionError(.reconstructionFailed),
          ])
    func prePromotionErrorsClassifyAsRedaction(error: PipelineError) {
        // redactionSucceeded is deliberately contradictory (true) — a typed
        // stage error must win over the positional fallback.
        #expect(PipelineCoordinator.classifyPipelineFailure(
                    error, redactionSucceeded: true) == .redaction)
        #expect(PipelineCoordinator.classifyPipelineFailure(
                    error, redactionSucceeded: false) == .redaction)
    }

    @Test("Post-promotion stage errors classify as .verification",
          arguments: [
            PipelineError.verificationError(.engineCrash(layerIndex: 0)),
            PipelineError.exportError(.diskFull),
            PipelineError.exportError(.filePurged),
          ])
    func postPromotionErrorsClassifyAsVerification(error: PipelineError) {
        #expect(PipelineCoordinator.classifyPipelineFailure(
                    error, redactionSucceeded: true) == .verification)
        #expect(PipelineCoordinator.classifyPipelineFailure(
                    error, redactionSucceeded: false) == .verification)
    }

    @Test("Untyped throws fall back to whether processDocument had returned")
    func untypedThrowsFallBackToStageFlag() {
        struct OpaqueFailure: Error {}
        #expect(PipelineCoordinator.classifyPipelineFailure(
                    OpaqueFailure(), redactionSucceeded: false) == .redaction)
        #expect(PipelineCoordinator.classifyPipelineFailure(
                    OpaqueFailure(), redactionSucceeded: true) == .verification)
    }

    // MARK: - Redaction-failure route (end-to-end)

    @Test("Redaction-stage failure returns to the editor with no output",
          .timeLimit(.minutes(1)))
    func redactionFailureReturnsToEditing() async throws {
        let coord = makeOversizedCoordinator()
        addRegion(to: coord)

        coord.runFullPipeline(documentOverride: .secureRasterization)

        var terminal: (error: PipelineError, returnPhase: DocumentState.ReturnPhase)?
        for _ in 0..<300 {
            if case .failed(let error, let returnPhase) = coord.documentState.phase {
                terminal = (error, returnPhase)
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        let failure = try #require(terminal,
                                   "Oversized-page run must land on .failed")
        guard case .redactionError(.insufficientMemory) = failure.error else {
            Issue.record("Expected .redactionError(.insufficientMemory) from the CAT-138 pre-flight, got \(failure.error)")
            return
        }
        guard case .editing = failure.returnPhase else {
            Issue.record("Redaction-stage failure must return to .editing, got \(failure.returnPhase)")
            return
        }
        #expect(coord.redactionState.outputURL == nil,
                "Redaction-stage failure must clear the eagerly-registered outputURL")

        // The registered file was never promoted (`replaceItemAt` never
        // ran); after clearOutput() nothing may remain in the session temp
        // directory.
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: coord.tempExportDirectory.url,
            includingPropertiesForKeys: nil)) ?? []
        #expect(leftovers.isEmpty,
                "No output file may survive a redaction-stage failure, found \(leftovers.map(\.lastPathComponent))")
    }

    // MARK: - Orphan hygiene at eager registration

    @Test("Eager registration clears a previous run's output first",
          .timeLimit(.minutes(1)))
    func eagerRegistrationClearsPriorOutput() async throws {
        let coord = makeOversizedCoordinator()
        addRegion(to: coord)

        // Simulate a completed prior run: a real file on disk, registered
        // as the published output.
        let priorURL = try coord.tempExportDirectory.childURL(
            named: "prior_output_\(UUID().uuidString).pdf")
        try Data("stale".utf8).write(to: priorURL)
        coord.redactionState.outputURL = priorURL

        coord.runFullPipeline(documentOverride: .secureRasterization)

        for _ in 0..<300 {
            if case .failed = coord.documentState.phase { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .failed = coord.documentState.phase else {
            Issue.record("Oversized-page run must land on .failed, got \(coord.documentState.phaseKind)")
            return
        }

        #expect(!FileManager.default.fileExists(atPath: priorURL.path),
                "The eager registration must clear the prior run's file, not orphan it")
        #expect(coord.redactionState.outputURL == nil,
                "No output may remain published after the redaction-stage failure")
    }

    // MARK: - Helpers

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
    /// directly onto the coordinator, which bypasses the import-time
    /// dimension gate so the page reaches `PageRasterizer.rasterize`, where
    /// the CAT-138 pre-flight refuses it with `.insufficientMemory` — a
    /// deterministic redaction-stage throw for the recovery-route tests
    /// (same fixture as FullPipelineFlowTests).
    private func makeOversizedPDFDocument() -> PDFDocument {
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(x: 0, y: 0, width: 5200, height: 300))
        let data = renderer.pdfData { ctx in
            ctx.beginPage()
        }
        return PDFDocument(data: data)!
    }
}
