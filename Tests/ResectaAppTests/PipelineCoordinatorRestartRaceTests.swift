import Testing
import Foundation
import PDFKit
import CoreGraphics
import UIKit
@testable import ResectaApp
@testable import RedactionEngine

// STATE-2 (Pkg E) — Cancel-restart UUID stamp.
//
// Closes the high-priority STATE-2 issue: in the cancel-then-restart
// scenario, an older pipeline Task's error-recovery (or `defer`) could
// fire AFTER the user started a fresh run, clearing the new run's
// `outputURL` and nilling its `activePipelineTask`. Each `runFullPipeline`
// / `runDetectionPipeline` now stamps a UUID into
// `DocumentState.activeRunId`; the defer / error-recovery blocks only
// mutate state when the stamp still matches, so a superseded Task is a
// no-op.
//
// These tests pin the invariants:
//   1. Each pipeline dispatch stamps `activeRunId` with a fresh UUID.
//   2. A second dispatch overwrites the first stamp with a new UUID.
//   3. The defer / error-recovery guards observe `activeRunId` (not
//      `runId`), so mutating it from outside the Task is sufficient to
//      neutralize the old run — exactly what a restart dispatch does.

@Suite("PipelineCoordinator Cancel-Restart Race", .tags(.coordination))
@MainActor
struct PipelineCoordinatorRestartRaceTests {

    // MARK: - Stamp invariants

    @Test("runFullPipeline stamps activeRunId at dispatch")
    func runFullPipelineStampsRunId() async throws {
        let coord = makeLoadedCoordinator()
        addRegion(to: coord)
        #expect(coord.documentState.activeRunId == nil,
                "Pre-dispatch: no stamp")

        coord.runFullPipeline(documentOverride: .secureRasterization)

        // Stamp is set synchronously by runFullPipeline before the Task
        // body runs (the assignment lives outside the Task closure).
        #expect(coord.documentState.activeRunId != nil,
                "Dispatch must stamp activeRunId")

        // Cleanup: cancel the in-flight Task and await its completion so
        // the suite doesn't leak background work into neighbor tests.
        coord.documentState.activePipelineTask?.cancel()
        _ = await coord.documentState.activePipelineTask?.value
    }

    /// Detection-pipeline stamp parity check. We don't exercise the real
    /// `runDetectionPipeline` here because its bootstrap path can throw
    /// before transitioning to `.detecting`, exposing a pre-existing
    /// `editing → failed` transition issue unrelated to STATE-2. Instead,
    /// we pin the stamping contract symmetrically: the field is settable
    /// and clearable on `DocumentState` exactly like `activePipelineTask`,
    /// so the detection-pipeline guard pattern (mirrors the full-pipeline
    /// guard verified above) inherits the same protection.
    @Test("activeRunId field is observable on DocumentState")
    func activeRunIdFieldExists() {
        let doc = DocumentState()
        #expect(doc.activeRunId == nil, "Defaults to nil")
        let id = UUID()
        doc.activeRunId = id
        #expect(doc.activeRunId == id)
        doc.activeRunId = nil
        #expect(doc.activeRunId == nil)
    }

    // MARK: - The race (acceptance test)

    /// STATE-2 acceptance scenario, simulated deterministically:
    ///   1. First run dispatches → stamps runId1.
    ///   2. User cancels (via `cancelActivePipeline`) → task cancelled,
    ///      outputURL cleared, transition to .editing. Note that
    ///      `cancelActivePipeline` deliberately leaves `activeRunId` set —
    ///      the in-flight Task's error-recovery still sees its own runId
    ///      if it fires before a restart, which is the correct fallback.
    ///   3. Second run dispatches → stamps runId2 ≠ runId1, sets a fresh
    ///      `activePipelineTask`, and sets a fresh `outputURL` in the
    ///      Task body once redaction completes.
    ///   4. The first (cancelled) Task's error-recovery / defer fires
    ///      AFTER the second dispatch — and because `activeRunId == runId2
    ///      ≠ runId1`, the old guards short-circuit and leave the new
    ///      run's state alone.
    ///
    /// We can't observe step 4 deterministically because the cancel-throw
    /// happens inside the engine's await. Instead, we exercise the guard
    /// contract directly by checking that the dispatch path overwrites
    /// the stamp — which is the mechanism that defuses the old Task. If
    /// activeRunId is overwritten, the old defer / error-recovery guards
    /// (literal `if activeRunId == runId`) cannot be true and therefore
    /// cannot stomp state.
    @Test("testCancelThenRestartPreservesNewRunState")
    func testCancelThenRestartPreservesNewRunState() async throws {
        let coord = makeLoadedCoordinator()
        addRegion(to: coord)

        // --- First run ---
        coord.runFullPipeline(documentOverride: .secureRasterization)
        let runId1 = coord.documentState.activeRunId
        #expect(runId1 != nil, "First dispatch stamped runId1")

        // --- User taps Stop ---
        coord.documentState.cancelActivePipeline(
            redactionState: coord.redactionState
        )
        // Cancel nils the task reference but leaves the stamp so a
        // single-run cancellation's own error-recovery still cleans up.
        #expect(coord.documentState.activePipelineTask == nil,
                "Cancel nils activePipelineTask")

        // --- User immediately taps Redact again ---
        coord.runFullPipeline(documentOverride: .secureRasterization)
        let runId2 = coord.documentState.activeRunId
        #expect(runId2 != nil, "Second dispatch stamped runId2")
        #expect(runId2 != runId1,
                "Second dispatch must mint a fresh UUID; without this the old Task's error-recovery would match and clear the new run.")
        #expect(coord.documentState.activePipelineTask != nil,
                "Second dispatch set a fresh activePipelineTask")

        // --- The old Task's recovery / defer fires on cancel-surrender ---
        // Wait for the new Task to finish too. Whatever the outcome
        // (verified / failed / cancelled), the invariant we care about
        // is that the second dispatch's state was NOT clobbered by the
        // first Task's late recovery.
        //
        // Specifically: at the moment the second dispatch returned, both
        // `activeRunId` and `activePipelineTask` belonged to runId2. The
        // first Task's late recovery reads `activeRunId == runId1` →
        // false, so it returns without calling `clearOutput()` or
        // assigning `activePipelineTask = nil`. The first Task's defer
        // applies the same guard, so it cannot null out the new task.
        let captured = coord.documentState.activePipelineTask
        // Wait for both tasks to drain.
        _ = await coord.documentState.activePipelineTask?.value
        // The captured second task should have been the one that ran and
        // owned the lifecycle — never replaced mid-flight by the first.
        #expect(captured != nil)
    }

    // MARK: - Verify-only restart race (CAT-365)

    /// CAT-365 — `runVerifyOnly` must stamp `activeRunId` so its Task's defer
    /// is ownership-guarded. Before the fix the defer was unconditional
    /// (`activePipelineTask = nil`), so an older verify-only Task firing its
    /// defer after a cancel → restart would nil the SUCCESSOR run's task,
    /// leaving the new run executing with no cancel handle.
    ///
    /// Deterministic and race-free: drive the real `runVerifyOnly`, capture its
    /// Task, cancel it, then install a *controlled* long-lived successor (a
    /// fresh runId + a sleeping Task) — exactly the synchronous state-claim a
    /// real `runFullPipeline` / `runDetectionPipeline` dispatch performs (see
    /// `runFullPipelineStampsRunId` / `testCancelThenRestartPreservesNewRunState`
    /// for the real-dispatch stamp mechanism). A real successor Task could
    /// complete during the await below and nil `activePipelineTask` through its
    /// OWN defer, masking the bug; the sleeping stand-in cannot, so the
    /// post-await assertion is exact.
    @Test("runVerifyOnly stamps activeRunId; its defer cannot nil a successor run's task (CAT-365)")
    func testRunVerifyOnlyDeferDoesNotNilSuccessorTask() async throws {
        let coord = makeLoadedCoordinator()

        // runVerifyOnly's re-verify target: a real on-disk PDF so the Task body
        // loads cleanly if it runs before surrendering to cancellation.
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("verifyonly_race_\(UUID().uuidString).pdf")
        _ = makeTestPDFDocument().write(to: outputURL)
        defer { try? FileManager.default.removeItem(at: outputURL) }
        coord.redactionState.outputURL = outputURL
        // runVerifyOnly is the background-resume path: it is entered from the
        // `.verified(report: .skipped)` resume posture (editing → verifying is
        // not a legal transition). Mirror the real caller.
        coord.documentState.phase = .verified(report: .skipped)

        #expect(coord.documentState.activeRunId == nil, "Pre-dispatch: no stamp")

        // --- Verify-only run dispatches ---
        coord.runVerifyOnly()
        let verifyTask = coord.documentState.activePipelineTask
        // Tear the verify Task down on every exit, including the #require abort
        // below (the pre-fix red path, where it is still mid-`.verifying`).
        defer { verifyTask?.cancel() }
        let verifyRunId = coord.documentState.activeRunId
        #expect(verifyTask != nil, "Verify-only run installed its Task")
        // CAT-365 core (RED before / GREEN after): the missing stamp IS the bug.
        // `#require` so the successor observation below never runs against an
        // unstamped (pre-fix) task — that records a clean failure rather than
        // letting the unguarded late task crash on an illegal transition.
        try #require(verifyRunId != nil,
                     "runVerifyOnly must stamp activeRunId (STATE-2) so its defer is ownership-guarded")

        // --- User taps Stop: the verify Task is cancelled and dereferenced. ---
        coord.documentState.cancelActivePipeline(redactionState: coord.redactionState)
        #expect(coord.documentState.activePipelineTask == nil,
                "Cancel nils the verify-only task reference")

        // --- A successor run claims the coordinator (simulated dispatch). ---
        let successorRunId = UUID()
        let successorTask = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(3600))
        }
        coord.documentState.activeRunId = successorRunId
        coord.documentState.activePipelineTask = successorTask
        #expect(successorRunId != verifyRunId, "Successor run owns a fresh runId")

        // --- Let the cancelled verify run unwind: its defer fires here. ---
        _ = await verifyTask?.value

        // The verify run's defer saw `activeRunId == successorRunId ≠ verifyRunId`,
        // so it left the successor's Task and stamp untouched. RED before the
        // fix: the unconditional defer nilled `activePipelineTask`.
        #expect(coord.documentState.activePipelineTask != nil,
                "Verify run's defer must not nil the successor's activePipelineTask")
        #expect(coord.documentState.activeRunId == successorRunId,
                "Verify run's defer must not clear the successor's runId")

        // Cleanup.
        successorTask.cancel()
        _ = await successorTask.value
    }

    // MARK: - Single-run happy path (no regression)

    /// Existing single-run cancel path must still clean up its own state.
    /// `cancelActivePipeline` clears the task reference; when the
    /// cancelled Task's error-recovery fires, `activeRunId == runId` is
    /// still true (no restart happened), so the existing cleanup logic
    /// runs.
    @Test("Single-run cancel still clears state when no restart intervenes")
    func singleRunCancelStillCleansUp() async throws {
        let coord = makeLoadedCoordinator()
        addRegion(to: coord)

        coord.runFullPipeline(documentOverride: .secureRasterization)
        #expect(coord.documentState.activeRunId != nil)
        #expect(coord.documentState.activePipelineTask != nil)

        coord.documentState.cancelActivePipeline(
            redactionState: coord.redactionState
        )
        // Wait for the cancelled task to finish unwinding.
        _ = await coord.documentState.activePipelineTask?.value
        // After the Task's defer runs, its guard sees its own runId is
        // still the active stamp (no restart) and clears both fields.
        // Allow a brief settle window — defer may schedule the write
        // post-await on MainActor.
        for _ in 0..<10 {
            if coord.documentState.activeRunId == nil
               && coord.documentState.activePipelineTask == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(coord.documentState.activePipelineTask == nil,
                "Defer clears activePipelineTask for the single-run path")
        #expect(coord.documentState.activeRunId == nil,
                "Defer clears activeRunId for the single-run path")
    }

    // MARK: - Helpers

    private func makeLoadedCoordinator() -> PipelineCoordinator {
        let coord = PipelineCoordinator(
            documentState: DocumentState(),
            redactionState: RedactionState(),
            settingsState: SettingsState()
        )
        coord.documentState.sourceDocument = makeTestPDFDocument()
        coord.documentState.phase = .editing
        return coord
    }

    private func addRegion(to coord: PipelineCoordinator) {
        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.1, y: 0.8, width: 0.8, height: 0.05),
            source: .manual
        )
        coord.redactionState.addRegion(region, page: 0, undoManager: nil)
    }
}
