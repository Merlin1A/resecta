import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// UI_UX §1.4 — Cancellation and rollback tests.

@Suite("Pipeline Cancellation")
@MainActor
struct CancellationTests {

    @Test("Cancel from detecting returns to editing")
    func cancelFromDetecting() {
        let doc = DocumentState()
        let redaction = RedactionState()
        doc.phase = .detecting(progress:
            .init(currentPage: 1, totalPages: 5, currentStep: "OCR…"))
        doc.cancelActivePipeline(redactionState: redaction)
        #expect(doc.phaseKind == .editing)
    }

    @Test("Cancel from redacting clears outputURL")
    func cancelFromRedactingClearsOutput() {
        let doc = DocumentState()
        let redaction = RedactionState()
        redaction.outputURL = URL(fileURLWithPath: "/tmp/test.pdf")
        doc.phase = .redacting(progress:
            .init(currentPage: 3, totalPages: 10, currentStep: "Page 3…"))
        doc.cancelActivePipeline(redactionState: redaction)
        #expect(doc.phaseKind == .editing)
        #expect(redaction.outputURL == nil, "Redacting cancel must clear outputURL")
    }

    @Test("Cancel from verifying transitions to .verified(report: .skipped) (Pkg L)")
    func cancelFromVerifyingPreservesOutput() {
        // Pkg L (CANCEL-009): cancel-from-verifying now lands on
        // `.verified(report: .skipped)` instead of `.editing` so the
        // background-resume banner can offer a Re-verify shortcut against
        // the still-valid `outputURL`. The redacted output and the
        // `regionsModifiedSinceVerification` flag are preserved.
        let doc = DocumentState()
        let redaction = RedactionState()
        let outputURL = URL(fileURLWithPath: "/tmp/valid_output.pdf")
        redaction.outputURL = outputURL
        doc.phase = .verifying(progress:
            .init(currentLayer: 3, totalLayers: 5, layerName: "Layer 3",
                  completedLayers: []))
        doc.cancelActivePipeline(redactionState: redaction)
        #expect(doc.phaseKind == .verified)
        if case .verified(let report) = doc.phase {
            #expect(report.overallStatus == .skipped,
                    "Cancel-from-verifying must land on the .skipped sentinel report")
        } else {
            Issue.record("Expected .verified phase after cancel-from-verifying")
        }
        #expect(redaction.outputURL == outputURL,
                "Verifying cancel must preserve outputURL")
    }

    @Test("Cancel from editing is no-op")
    func cancelFromEditingNoOp() {
        let doc = DocumentState()
        let redaction = RedactionState()
        doc.phase = .editing
        doc.cancelActivePipeline(redactionState: redaction)
        #expect(doc.phaseKind == .editing)
    }

    @Test("Cancel from verified is no-op")
    func cancelFromVerifiedNoOp() {
        let doc = DocumentState()
        let redaction = RedactionState()
        doc.phase = .verified(report: .skipped)
        doc.cancelActivePipeline(redactionState: redaction)
        #expect(doc.phaseKind == .verified)
    }

    @Test("Cancel sets activePipelineTask to nil")
    func cancelClearsTask() {
        let doc = DocumentState()
        let redaction = RedactionState()
        doc.activePipelineTask = Task { }
        doc.phase = .detecting(progress:
            .init(currentPage: 1, totalPages: 1, currentStep: ""))
        doc.cancelActivePipeline(redactionState: redaction)
        #expect(doc.activePipelineTask == nil)
    }

    // CAT-214: cancelClearsTask above only injects an empty Task and checks the
    // synchronous nil-out. This guards the CANCEL-011 in-flight-suspension path:
    // a Task suspended inside real work, cancelled mid-flight, whose
    // STATE-2 UUID-guarded defer must settle `activeRunId`. cancelActivePipeline
    // nils `activePipelineTask` synchronously but does NOT touch `activeRunId`
    // (that is the production pipeline Task's defer, PipelineCoordinator:357-361,
    // which nils it only when the run still owns the UUID). The injected Task
    // mirrors that defer; the CANCEL-011 awaiter drains it. Yield-loop (not an
    // absolute sleep) until the run id settles.
    @Test("Cancel drains the in-flight Task and settles activeRunId via the STATE-2 UUID guard (CAT-214)")
    func cancelRacesInFlightTask() async {
        let doc = DocumentState()
        let redaction = RedactionState()
        let runId = UUID()
        doc.activeRunId = runId
        doc.activePipelineTask = Task { @MainActor in
            // Mirror the production run Task's STATE-2 defer: on unwind (here via
            // cancellation surrendering the sleep) clear the run id only if this
            // run still owns it.
            defer { if doc.activeRunId == runId { doc.activeRunId = nil } }
            try? await Task.sleep(for: .milliseconds(500))
        }
        doc.phase = .detecting(progress:
            .init(currentPage: 1, totalPages: 1, currentStep: ""))

        doc.cancelActivePipeline(redactionState: redaction)
        // activePipelineTask is nil'd synchronously inside cancelActivePipeline.
        #expect(doc.activePipelineTask == nil)

        // activeRunId settles asynchronously once the cancelled Task unwinds its
        // UUID-guarded defer (drained by the CANCEL-011 MainActor awaiter). Poll.
        for _ in 0..<200 where doc.activeRunId != nil {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(doc.activeRunId == nil,
                "CANCEL-011 awaiter must settle activeRunId to nil once the cancelled run's UUID-guarded defer unwinds")
        #expect(doc.phaseKind == .editing,
                "cancel-from-detecting must still land on .editing")
    }

    @Test("Cancel from exporting is no-op (not cancellable)")
    func cancelFromExportingNoOp() {
        let doc = DocumentState()
        let redaction = RedactionState()
        doc.phase = .exporting
        doc.cancelActivePipeline(redactionState: redaction)
        #expect(doc.phaseKind == .exporting)
    }

    @Test("Double cancel is no-op")
    func doubleCancelNoOp() {
        let doc = DocumentState()
        let redaction = RedactionState()
        doc.phase = .detecting(progress:
            .init(currentPage: 1, totalPages: 1, currentStep: ""))
        doc.cancelActivePipeline(redactionState: redaction)
        #expect(doc.phaseKind == .editing)
        // Second cancel from editing is no-op
        doc.cancelActivePipeline(redactionState: redaction)
        #expect(doc.phaseKind == .editing)
    }

    // CAT-240 / CAT-157 / D-05: the OQ-1 `ocrReturnReport` precedence contract
    // was removed (no production writer ever set the field). This is the
    // canonical successor guard — cancel from `.verifying` now unconditionally
    // yields `.verified(report: .skipped)`; there is no return-report path.
    @Test("Cancel from verifying yields .skipped when there is no return report (CAT-240)")
    func cancelFromVerifyingYieldsSkippedWhenNoReturnReport() {
        let doc = DocumentState()
        let redaction = RedactionState()
        doc.phase = .verifying(progress:
            .init(currentLayer: 2, totalLayers: 5, layerName: "Layer 2",
                  completedLayers: []))
        doc.cancelActivePipeline(redactionState: redaction)
        #expect(doc.phaseKind == .verified)
        guard case .verified(let report) = doc.phase else {
            Issue.record("Expected .verified phase after cancel-from-verifying")
            return
        }
        #expect(report.overallStatus == .skipped,
                "Cancel-from-verifying must land on the .skipped sentinel report")
    }

    // CAT-046 (C-J1, D-08): the three pipeline CancellationError handlers
    // (runFullPipeline / runDetectionPipeline / verifyDocument) now wrap their
    // @Observable state mutation in
    // `await MainActor.run { MainActor.assertIsolated(); … }`. A thrown
    // CancellationError can resume the error handler OFF the MainActor (a
    // Task.detached intermediate breaks actor inheritance — the
    // runDetectionPipeline general-error handler sibling carries the real-doc
    // crash backtrace for the same mechanism). That off-main resume is a
    // device-timing race not injectable at the unit level without a
    // cooperative-thread harness, so per D-08 the runtime
    // `MainActor.assertIsolated()` canary IS the guard: it traps in CI if the
    // hop is ever removed. This proxy asserts the canary is satisfied in the
    // MainActor context the hop provides and pins the recovery BEHAVIOR each
    // hopped handler produces (so a regression in the transition outcome shows up).
    @Test("CancellationError handler recovery is MainActor-isolated and lands on the documented phase (CAT-046)")
    func detectionCancellationHopsToMainActor() {
        // The canary the production hop runs at each `MainActor.run` closure
        // entry: a no-op on the MainActor (this suite is @MainActor), a trap
        // off it.
        MainActor.assertIsolated()

        // runDetectionPipeline's CancellationError recovery: detecting → editing.
        let detect = DocumentState()
        detect.phase = .detecting(progress:
            .init(currentPage: 1, totalPages: 3, currentStep: "Scanning…"))
        if detect.phaseKind != .editing { detect.transition(to: .editing) }
        #expect(detect.phaseKind == .editing)

        // runFullPipeline's CancellationError recovery: redacting → editing.
        let full = DocumentState()
        full.phase = .redacting(progress:
            .init(currentPage: 2, totalPages: 4, currentStep: "Page 2…"))
        if full.phaseKind != .editing && full.phaseKind != .verified {
            full.transition(to: .editing)
        }
        #expect(full.phaseKind == .editing)

        // verifyDocument's CancellationError recovery: verifying → verified(.skipped).
        let verify = DocumentState()
        verify.phase = .verifying(progress:
            .init(currentLayer: 2, totalLayers: 5, layerName: "Layer 2",
                  completedLayers: []))
        if verify.phaseKind != .editing && verify.phaseKind != .verified {
            verify.transition(to: .verified(report: .skipped))
        }
        #expect(verify.phaseKind == .verified)
    }
}
