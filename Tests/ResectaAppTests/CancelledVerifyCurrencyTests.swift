import Testing
import Foundation
import CoreGraphics
@testable import ResectaApp
import RedactionEngine

// A verification interrupted by leaving the app, after a run that burned
// the live regions. The output carries every region on screen, so the
// results screen must not say the regions changed after the PDF was made,
// and Run Verification re-checks the existing output instead of redacting
// again. The flag clears only THROUGH the burned-version guard
// (`RedactionState.markVerificationCurrent(burnedRegionVersion:)`): a
// region the run did not burn keeps the stale caption standing.

@Suite("Cancelled verify after a run that burned the live regions")
@MainActor
struct CancelledVerifyCurrencyTests {

    private static let staleCaption =
        "Regions changed after this PDF was made. Run\u{00A0}Redact\u{00A0}again\u{00A0}to\u{00A0}share."

    private struct Fixture {
        let coord: PipelineCoordinator
        let output: URL
        let root: URL
    }

    private func drawnRegion(y: Double) -> RedactionRegion {
        RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.1, y: y, width: 0.3, height: 0.1),
            source: .manual)
    }

    /// An output file on disk under a per-test root.
    private func writeOutput() throws -> (output: URL, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cancelled_verify_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let output = root.appendingPathComponent("redacted_\(UUID().uuidString).pdf")
        try makeTestPDFData().write(to: output)
        return (output, root)
    }

    private static var verifyingPhase: DocumentState.Phase {
        .verifying(progress: .init(
            currentLayer: 1, totalLayers: 5, layerName: "Layer 1", completedLayers: []))
    }

    /// A run that redacted the live regions and is now verifying: the
    /// run's own events, in the runner's order (`PipelineRunner`), handed
    /// to the coordinator's adapter (`PipelineCoordinator.apply(_:)`), as
    /// a real run hands them over. Nothing moves `regionVersion` between
    /// the draw and the verify, so the run burned the live regions.
    private func verifyingAfterABurn() throws -> Fixture {
        let coord = makeLoadedCoordinator()
        coord.redactionState.addRegion(drawnRegion(y: 0.2), page: 0, undoManager: nil)
        try #require(coord.redactionState.isVerificationStale,
                     "precondition: the draw marks the previous output stale")
        let (output, root) = try writeOutput()

        coord.apply(.runStarted(effectiveMode: .secureRasterization))
        coord.apply(.phase(.redacting(progress: .init(currentPage: 0, totalPages: 1, currentStep: "Page 1…"))))
        coord.apply(.outputRegistered(output))
        coord.apply(.redactionFinished(
            outputURL: output,
            inputs: .fixture(burnedRegionVersion: coord.redactionState.regionVersion)))
        coord.apply(.phase(Self.verifyingPhase))
        return Fixture(coord: coord, output: output, root: root)
    }

    /// Leaving the app during `.verifying` — the scene handler's cancel.
    private func backgroundMidVerify(_ f: Fixture) -> Bool {
        f.coord.documentState.cancelActivePipeline(redactionState: f.coord.redactionState)
        guard case .verified(let report) = f.coord.documentState.phase, report.skipReason == .cancelled else {
            Issue.record("expected the cancelled skipped report, got \(f.coord.documentState.phaseKind)")
            return false
        }
        #expect(f.coord.redactionState.outputURL == f.output, "the output survives the cancel")
        return true
    }

    @Test("Backgrounded mid-verify: the Share caption does not say the regions changed")
    func shareCaptionAfterACancelledVerify() throws {
        let f = try verifyingAfterABurn()
        defer { try? FileManager.default.removeItem(at: f.root) }
        guard backgroundMidVerify(f) else { return }

        let reason = VerificationResultsView.shareDisabledReason(
            outputExists: FileManager.default.fileExists(atPath: f.output.path),
            isStale: f.coord.redactionState.isVerificationStale)
        #expect(reason != Self.staleCaption,
                "today the stale flag the run burned past survives the cancel")
    }

    @Test("Backgrounded mid-verify: Run Verification re-checks the existing output")
    func runVerificationRoutesVerifyOnly() throws {
        let f = try verifyingAfterABurn()
        defer { try? FileManager.default.removeItem(at: f.root) }
        guard backgroundMidVerify(f) else { return }

        #expect(DocumentEditorView.runVerificationRoute(
            hasOutput: f.coord.redactionState.outputURL != nil,
            isVerificationStale: f.coord.redactionState.isVerificationStale,
            hasUnappliedSelections: false) == .verifyOnly,
            "today .fullPipeline: a re-redact of an output that already carries every region")
    }

    @Test("A cancel with no run behind the output keeps the stale caption")
    func noBurnedRunKeepsTheCaption() throws {
        // Every region mutation also clears the output, so "an output on
        // disk plus a region it lacks" arises only without a recorded run:
        // an output registered before the draw, no run this session. The
        // flag clears only through a run's burned version, so it stands
        // (DocumentStateVerifyingCancelTests'
        // `testCancelDuringVerifyingPreservesStaleFlag`, at the caption).
        let coord = makeLoadedCoordinator()
        coord.redactionState.addRegion(drawnRegion(y: 0.2), page: 0, undoManager: nil)
        let (output, root) = try writeOutput()
        defer { try? FileManager.default.removeItem(at: root) }
        coord.redactionState.outputURL = output
        coord.documentState.phase = Self.verifyingPhase
        let f = Fixture(coord: coord, output: output, root: root)
        guard backgroundMidVerify(f) else { return }

        #expect(coord.redactionState.isVerificationStale)
        #expect(VerificationResultsView.shareDisabledReason(
            outputExists: true, isStale: coord.redactionState.isVerificationStale) == Self.staleCaption)
        #expect(DocumentEditorView.runVerificationRoute(
            hasOutput: true, isVerificationStale: coord.redactionState.isVerificationStale,
            hasUnappliedSelections: false) == .fullPipeline)
    }
}
