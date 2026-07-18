import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// Regression coverage for the detection-pipeline graceful-degradation fix.
//
// Background: `PipelineCoordinator.runDetectionPipeline` performs a page-0
// "bootstrap" rasterize BEFORE the per-page loop transitions to `.detecting`.
// When that rasterize throws — which it does on the Simulator, a platform that
// cannot service the Vision/Core-Graphics path — the error handler previously
// requested an `editing → failed` transition. That pair is absent from
// `DocumentState.legalTransitions`, so the transition asserted and hard-crashed
// ("Illegal phase transition: editing → failed", DocumentState.swift). The fix
// routes both the bootstrap guard and the error handler through
// `degradeDetectionToEditing()`, which returns to a safe `.editing` state with a
// mechanism-description toast and never requests an illegal transition.
//
// These tests assert the degrade behavior directly (deterministic) and drive
// the whole pipeline end-to-end to assert it is crash-safe regardless of
// whether the sim rasterize throws. The transition table itself is unchanged
// (CLAUDE.md hard-stop); `transitionTableHasNoEditingToFailed` pins the
// invariant the fix relies on.

@Suite("Detection error graceful degradation", .tags(.coordination))
@MainActor
struct DetectionErrorRecoveryTests {

    /// The exact mechanism-description copy surfaced by the degrade path.
    /// Mirrors `PipelineCoordinator.degradeDetectionToEditing()`.
    private static let degradeToast =
        "Couldn't scan this document. Manual redaction tools remain available."

    // MARK: - Deterministic degrade behavior

    @Test("Degrade from .editing (page-0 bootstrap failure) stays in .editing with a warning toast")
    func degradeFromEditingStaysInEditing() {
        let coordinator = makeCoordinator()
        let toasts = ToastQueueManager()
        coordinator.toastManager = toasts
        // Phase at a bootstrap failure: still `.editing` (the per-page loop's
        // `.detecting` transition has not run yet).
        coordinator.documentState.phase = .editing

        coordinator.degradeDetectionToEditing()

        // No illegal transition was requested; the editor stays put and a
        // single warning toast is surfaced.
        #expect(coordinator.documentState.phaseKind == .editing)
        #expect(coordinator.documentState.phaseKind != .failed)
        #expect(toasts.activeToasts.count == 1)
        #expect(toasts.activeToasts.first?.severity == .warning)
        #expect(toasts.activeToasts.first?.message == Self.degradeToast)
        // UXF-06 — the failed outcome lands in the run record so the
        // summary banner keeps a trace after the toast expires.
        #expect(coordinator.redactionState.lastDetectionRun?.outcome == .failed)
    }

    @Test("Degrade from .detecting (mid-detection failure) returns to .editing with a warning toast")
    func degradeFromDetectingReturnsToEditing() {
        let coordinator = makeCoordinator()
        let toasts = ToastQueueManager()
        coordinator.toastManager = toasts
        // Phase at a mid-loop failure: `.detecting`. `detecting → editing` is a
        // legal transition, so the degrade returns to the editor.
        coordinator.documentState.phase = .detecting(progress: .init(
            currentPage: 1, totalPages: 1, currentStep: "Scanning page 1\u{2026}"))

        coordinator.degradeDetectionToEditing()

        #expect(coordinator.documentState.phaseKind == .editing)
        #expect(coordinator.documentState.phaseKind != .failed)
        #expect(toasts.activeToasts.count == 1)
        #expect(toasts.activeToasts.first?.severity == .warning)
        #expect(toasts.activeToasts.first?.message == Self.degradeToast)
    }

    // MARK: - Transition-table invariant the fix relies on

    @Test("Transition table has no editing→failed pair, but detecting→{failed,editing} are legal")
    func transitionTableHasNoEditingToFailed() {
        // The crash root cause: `editing → failed` is intentionally NOT legal.
        #expect(!DocumentState.legalTransitions.contains(
            DocumentState.TransitionPair(.editing, .failed)),
            "editing→failed must remain illegal — the detection path degrades instead")
        // The degrade / failure routing the fix depends on IS legal.
        #expect(DocumentState.legalTransitions.contains(
            DocumentState.TransitionPair(.detecting, .editing)))
        #expect(DocumentState.legalTransitions.contains(
            DocumentState.TransitionPair(.detecting, .failed)))
    }

    // MARK: - End-to-end crash-safety

    @Test("runDetectionPipeline on the simulator ends crash-safe in a legal state")
    func runDetectionPipelineEndsCrashSafe() async {
        let coordinator = makeCoordinator()
        coordinator.toastManager = ToastQueueManager()
        // A loaded document in `.editing` mirrors how Auto-Detect is reached
        // (the button is disabled outside `.editing`).
        coordinator.documentState.sourceDocument = makeTestPDFDocument()
        coordinator.documentState.phase = .editing

        coordinator.runDetectionPipeline()
        // Await the detection Task to completion.
        await coordinator.documentState.activePipelineTask?.value

        // On the sim the page-0 rasterize throws → the error path degrades to
        // `.editing`; if the sim can rasterize, detection completes (also
        // `.editing`, possibly staging triage). Either way the run ends in a
        // legal state — never `.failed`, never an illegal-transition crash.
        // Under the pre-fix code this test would have aborted via the
        // `editing → failed` assertion.
        #expect(coordinator.documentState.phaseKind == .editing)
        #expect(coordinator.documentState.phaseKind != .failed)
        #expect(coordinator.documentState.activePipelineTask == nil,
                "the run cleared its active-task stamp on completion")
    }

    // MARK: - Deliverable 2: --seedTriage seed helper

    #if DEBUG
    @Test("seedDebugTriage populates pendingTriage + all-deselected selections on page 0")
    func seedDebugTriagePopulatesPendingTriage() {
        let redactionState = RedactionState()
        #expect(redactionState.pendingTriage == nil)

        redactionState.seedDebugTriage()

        let pending = redactionState.pendingTriage
        #expect(pending != nil)
        // All mock detections land on page 0.
        #expect(pending?.keys.sorted() == [0])
        let page0 = pending?[0] ?? []
        // 6 mocks — q14 added a second "Jordan Avery" so the Grouped view
        // mode has a real cluster and "Apply Group" is drivable on-sim.
        #expect(page0.count == 6)
        // Review-first arrival: selections cover every seeded detection with an
        // EXPLICIT deselected entry, mirroring the real staging path's
        // all-deselected arrival (explicit-per-id because the apply
        // path's absent-id fallback still reads accepted).
        #expect(redactionState.triageSelections.count == page0.count)
        #expect(redactionState.triageSelections.values.allSatisfy { !$0 })
        for detection in page0 {
            #expect(redactionState.triageSelections[detection.id] == false)
        }
        // A mix of kinds so the triage list, filters, and "Apply N" are exercised.
        let kinds = Set(page0.map { $0.kind })
        #expect(kinds.count >= 3)
        // q14 — the seed now mirrors the real staging path's sibling
        // writes so the banner, Review re-entry, and Grouped view are
        // drivable on the Simulator.
        #expect(redactionState.detectionResults[0]?.map(\.id) == page0.map(\.id))
        #expect(redactionState.crossPageEntityGroups.count == 1)
        #expect(redactionState.lastDetectionRun?.outcome == .staged)
    }
    #endif
}
