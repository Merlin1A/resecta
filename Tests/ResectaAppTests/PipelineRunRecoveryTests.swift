import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// The recovery table behind `PipelineCoordinator.launch(_:)`: one row per
// run kind × end, reproducing the transitions the three run scaffolds'
// error handlers drove. The end-to-end pins stay in `CancellationTests`,
// `ErrorRecoveryTests`, `PipelineFailureStageTests` and
// `DetectionErrorRecoveryTests`; these pin the table itself, without a
// live run.

@Suite("Pipeline run recovery table")
struct PipelineRunRecoveryTests {

    private struct Boom: Error {}

    private var settings: PipelineCoordinator.RunSettings {
        PipelineCoordinator.RunSettings(
            pipelineMode: .secureRasterization, autoVerify: true,
            paranoidMode: false, fillColor: .black, exportDPI: 300)
    }
    private var full: PipelineRunKind {
        .full(effectiveMode: .secureRasterization, runSettings: settings)
    }
    private var verifyOnly: PipelineRunKind {
        .verifyOnly(outputURL: URL(fileURLWithPath: "/tmp/recovery-table.pdf"),
                    effectiveMode: .secureRasterization)
    }
    private var detection: PipelineRunKind {
        .detection(recognitionLevel: .fast, runSettings: settings)
    }

    // MARK: - Cancel

    @Test("Full run cancelled mid-flight: discard the output and return to editing; a settled phase is left alone")
    func fullCancel() {
        for phase in [DocumentState.PhaseKind.redacting, .verifying] {
            guard case .returnToEditing(clearOutput: true) = PipelineCoordinator.recovery(
                for: full, after: .cancelled, phaseKind: phase) else {
                Issue.record("expected returnToEditing(clearOutput: true) from \(phase)"); return
            }
        }
        for phase in [DocumentState.PhaseKind.editing, .verified] {
            guard case .none = PipelineCoordinator.recovery(
                for: full, after: .cancelled, phaseKind: phase) else {
                Issue.record("expected none from \(phase)"); return
            }
        }
    }

    @Test("Verify-only cancelled mid-flight: the skipped(cancelled) report; a settled phase is left alone")
    func verifyOnlyCancel() {
        guard case .verifiedSkippedCancelled = PipelineCoordinator.recovery(
            for: verifyOnly, after: .cancelled, phaseKind: .verifying) else {
            Issue.record("expected verifiedSkippedCancelled from verifying"); return
        }
        for phase in [DocumentState.PhaseKind.editing, .verified] {
            guard case .none = PipelineCoordinator.recovery(
                for: verifyOnly, after: .cancelled, phaseKind: phase) else {
                Issue.record("expected none from \(phase)"); return
            }
        }
    }

    @Test("Detection cancelled mid-flight: return to editing without touching the output; editing is left alone")
    func detectionCancel() {
        guard case .returnToEditing(clearOutput: false) = PipelineCoordinator.recovery(
            for: detection, after: .cancelled, phaseKind: .detecting) else {
            Issue.record("expected returnToEditing(clearOutput: false) from detecting"); return
        }
        guard case .none = PipelineCoordinator.recovery(
            for: detection, after: .cancelled, phaseKind: .editing) else {
            Issue.record("expected none from editing"); return
        }
    }

    // MARK: - Error

    @Test("Full run failing in the redaction stage: discard the output, land on .failed → editing, an untyped error reads as reconstructionFailed")
    func fullRedactionStageError() {
        guard case .failed(let error, let returnPhase, clearOutput: true) = PipelineCoordinator.recovery(
            for: full, after: .failed(Boom(), stage: .redaction), phaseKind: .redacting) else {
            Issue.record("expected failed(clearOutput: true)"); return
        }
        guard case .redactionError(.reconstructionFailed) = error else {
            Issue.record("expected redactionError(.reconstructionFailed), got \(error)"); return
        }
        guard case .editing = returnPhase else {
            Issue.record("expected returnPhase .editing"); return
        }
    }

    @Test("Full run failing in the verification stage: keep the output, land on .failed → verified(skipped: error), an untyped error reads as engineCrash(0)")
    func fullVerificationStageError() {
        guard case .failed(let error, let returnPhase, clearOutput: false) = PipelineCoordinator.recovery(
            for: full, after: .failed(Boom(), stage: .verification), phaseKind: .verifying) else {
            Issue.record("expected failed(clearOutput: false)"); return
        }
        guard case .verificationError(.engineCrash(layerIndex: 0)) = error else {
            Issue.record("expected verificationError(.engineCrash(0)), got \(error)"); return
        }
        guard case .verified(let report) = returnPhase, report.layers.isEmpty else {
            Issue.record("expected returnPhase .verified(.skipped(reason: .error))"); return
        }
    }

    @Test("A typed PipelineError passes through the full run's recovery unchanged")
    func fullTypedErrorPassesThrough() {
        let typed = PipelineError.redactionError(.fillVerificationFailed(pageIndex: 4))
        guard case .failed(let error, _, clearOutput: true) = PipelineCoordinator.recovery(
            for: full, after: .failed(typed, stage: .redaction), phaseKind: .redacting) else {
            Issue.record("expected failed"); return
        }
        guard case .redactionError(.fillVerificationFailed(pageIndex: 4)) = error else {
            Issue.record("expected the typed error unchanged, got \(error)"); return
        }
    }

    @Test("Verify-only failing: keep the output, land on .failed → verified(skipped: error) regardless of the stage marker")
    func verifyOnlyError() {
        for stage in [PipelineCoordinator.PipelineFailureStage.redaction, .verification] {
            guard case .failed(let error, let returnPhase, clearOutput: false) = PipelineCoordinator.recovery(
                for: verifyOnly, after: .failed(Boom(), stage: stage), phaseKind: .verifying) else {
                Issue.record("expected failed(clearOutput: false) for stage \(stage)"); return
            }
            guard case .verificationError(.engineCrash(layerIndex: 0)) = error else {
                Issue.record("expected engineCrash(0), got \(error)"); return
            }
            guard case .verified = returnPhase else {
                Issue.record("expected returnPhase .verified"); return
            }
        }
    }

    @Test("Detection failing: degrade to editing (the toast + the run record), never a .failed transition")
    func detectionError() {
        guard case .degradeDetection = PipelineCoordinator.recovery(
            for: detection, after: .failed(Boom(), stage: .redaction), phaseKind: .detecting) else {
            Issue.record("expected degradeDetection"); return
        }
    }
}
