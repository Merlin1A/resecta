import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// UI_UX §8.1: State machine transition tests.

@Suite("Phase Transition Engine")
@MainActor
struct TransitionTests {

    // MARK: - Valid Transitions (UI_UX §1.2)

    @Test("empty → importing succeeds")
    func emptyToImporting() {
        let state = DocumentState()
        #expect(state.transition(to: .importing))
        #expect(state.phaseKind == .importing)
    }

    @Test("importing → editing succeeds")
    func importingToEditing() {
        let state = DocumentState()
        state.phase = .importing
        #expect(state.transition(to: .editing))
        #expect(state.phaseKind == .editing)
    }

    @Test("importing → failed succeeds")
    func importingToFailed() {
        let state = DocumentState()
        state.phase = .importing
        #expect(state.transition(to: .failed(
            error: .importError(.corrupt), returnPhase: .empty)))
    }

    @Test("editing → detecting succeeds")
    func editingToDetecting() {
        let state = DocumentState()
        state.phase = .editing
        #expect(state.transition(to: .detecting(progress:
            .init(currentPage: 1, totalPages: 5, currentStep: "Running OCR…"))))
    }

    @Test("editing → redacting succeeds")
    func editingToRedacting() {
        let state = DocumentState()
        state.phase = .editing
        #expect(state.transition(to: .redacting(progress:
            .init(currentPage: 1, totalPages: 5, currentStep: "Processing…"))))
    }

    @Test("editing → importing succeeds (new document replaces current)")
    func editingToImporting() {
        let state = DocumentState()
        state.phase = .editing
        #expect(state.transition(to: .importing))
    }

    @Test("editing → empty succeeds (close document)")
    func editingToEmpty() {
        let state = DocumentState()
        state.phase = .editing
        #expect(state.transition(to: .empty))
    }

    @Test("redacting → verifying succeeds")
    func redactingToVerifying() {
        let state = DocumentState()
        state.phase = .redacting(progress:
            .init(currentPage: 5, totalPages: 5, currentStep: "Done"))
        #expect(state.transition(to: .verifying(progress:
            .init(currentLayer: 1, totalLayers: 5, layerName: "Text extraction",
                  completedLayers: []))))
    }

    @Test("redacting → verified succeeds (autoVerify disabled)")
    func redactingToVerified() {
        let state = DocumentState()
        state.phase = .redacting(progress:
            .init(currentPage: 1, totalPages: 1, currentStep: "Done"))
        #expect(state.transition(to: .verified(report: .skipped)))
    }

    @Test("verifying → verified succeeds")
    func verifyingToVerified() {
        let state = DocumentState()
        state.phase = .verifying(progress:
            .init(currentLayer: 5, totalLayers: 5, layerName: "Metadata",
                  completedLayers: []))
        #expect(state.transition(to: .verified(report: .skipped)))
    }

    @Test("verified → exporting succeeds")
    func verifiedToExporting() {
        let state = DocumentState()
        state.phase = .verified(report: .skipped)
        #expect(state.transition(to: .exporting))
    }

    @Test("verified → editing succeeds (go back)")
    func verifiedToEditing() {
        let state = DocumentState()
        state.phase = .verified(report: .skipped)
        #expect(state.transition(to: .editing))
    }

    @Test("verified → verifying succeeds (OCR re-verification §5.7)")
    func verifiedToVerifying() {
        let state = DocumentState()
        state.phase = .verified(report: .skipped)
        #expect(state.transition(to: .verifying(progress:
            .init(currentLayer: 1, totalLayers: 5, layerName: "Re-verify",
                  completedLayers: []))))
    }

    @Test("exporting → verified succeeds (share dismissed)")
    func exportingToVerified() {
        let state = DocumentState()
        state.phase = .exporting
        #expect(state.transition(to: .verified(report: .skipped)))
    }

    @Test("exporting → failed succeeds")
    func exportingToFailed() {
        let state = DocumentState()
        state.phase = .exporting
        #expect(state.transition(to: .failed(
            error: .exportError(.diskFull),
            returnPhase: .verified(report: .skipped))))
    }

    @Test("failed → editing succeeds")
    func failedToEditing() {
        let state = DocumentState()
        state.phase = .failed(error: .redactionError(.reconstructionFailed),
                              returnPhase: .editing)
        #expect(state.transition(to: .editing))
    }

    @Test("failed → empty succeeds")
    func failedToEmpty() {
        let state = DocumentState()
        state.phase = .failed(error: .importError(.corrupt), returnPhase: .empty)
        #expect(state.transition(to: .empty))
    }

    @Test("failed → verified succeeds")
    func failedToVerified() {
        let state = DocumentState()
        state.phase = .failed(error: .exportError(.diskFull),
                              returnPhase: .verified(report: .skipped))
        #expect(state.transition(to: .verified(report: .skipped)))
    }

    // MARK: - Self-Transitions

    @Test("detecting → detecting succeeds (progress update)")
    func detectingSelfTransition() {
        let state = DocumentState()
        state.phase = .detecting(progress:
            .init(currentPage: 1, totalPages: 5, currentStep: "Page 1"))
        #expect(state.transition(to: .detecting(progress:
            .init(currentPage: 2, totalPages: 5, currentStep: "Page 2"))))
    }

    @Test("redacting → redacting succeeds (progress update)")
    func redactingSelfTransition() {
        let state = DocumentState()
        state.phase = .redacting(progress:
            .init(currentPage: 1, totalPages: 5, currentStep: "Page 1"))
        #expect(state.transition(to: .redacting(progress:
            .init(currentPage: 2, totalPages: 5, currentStep: "Page 2"))))
    }

    @Test("verifying → verifying succeeds (progress update)")
    func verifyingSelfTransition() {
        let state = DocumentState()
        state.phase = .verifying(progress:
            .init(currentLayer: 1, totalLayers: 5, layerName: "Layer 1",
                  completedLayers: []))
        #expect(state.transition(to: .verifying(progress:
            .init(currentLayer: 2, totalLayers: 5, layerName: "Layer 2",
                  completedLayers: []))))
    }

    // MARK: - Invalid Transitions (checked via transition table, not transition()
    // which calls assertionFailure in debug builds)

    @Test("Transition table rejects illegal pairs",
          arguments: [
            (DocumentState.PhaseKind.empty, DocumentState.PhaseKind.editing),
            (.editing, .editing),           // No self-transition for editing
            (.editing, .verified),           // Must go through redacting
            (.editing, .exporting),          // Must go through verified
            (.verified, .redacting),         // Must return to editing first
            (.importing, .importing),        // No self-transition for importing
            (.exporting, .editing),          // Must return to verified
            (.empty, .empty),               // No self-transition for empty
          ] as [(DocumentState.PhaseKind, DocumentState.PhaseKind)])
    func illegalTransitions(from: DocumentState.PhaseKind, to: DocumentState.PhaseKind) {
        let pair = DocumentState.TransitionPair(from, to)
        #expect(!DocumentState.legalTransitions.contains(pair),
                "Expected \(from) → \(to) to be illegal")
    }

    // MARK: - PhaseKind Convenience

    @Test("isPipelineActive reports correctly for all phases")
    func pipelineActiveFlag() {
        let activeKinds: [DocumentState.PhaseKind] = [
            .detecting, .redacting, .verifying, .importing, .exporting
        ]
        let inactiveKinds: [DocumentState.PhaseKind] = [
            .empty, .editing, .verified, .failed
        ]
        for kind in activeKinds {
            #expect(kind.isPipelineActive, "Expected \(kind) to be pipeline-active")
        }
        for kind in inactiveKinds {
            #expect(!kind.isPipelineActive, "Expected \(kind) to NOT be pipeline-active")
        }
    }

    @Test("isCancellable reports correctly")
    func cancellableFlag() {
        // CANCEL-006 (Pkg B): `.importing` is now cancellable so the
        // scene-phase observer and the in-card Cancel button can reach
        // the detached per-page validation loops.
        let cancellable: [DocumentState.PhaseKind] = [
            .detecting, .redacting, .verifying, .importing
        ]
        let notCancellable: [DocumentState.PhaseKind] = [
            .empty, .editing, .verified, .exporting, .failed
        ]
        for kind in cancellable {
            #expect(kind.isCancellable)
        }
        for kind in notCancellable {
            #expect(!kind.isCancellable)
        }
    }

    // MARK: - Verification Override

    @Test("overrideVerificationFailure sets flag on verified report")
    func overrideVerificationFailure() {
        let state = DocumentState()
        let report = VerificationReport(
            layers: [], overallStatus: .fail("test"), durationSeconds: 1.0)
        state.phase = .verified(report: report)
        state.overrideVerificationFailure()
        if case .verified(let updatedReport) = state.phase {
            #expect(updatedReport.userOverrodeFailure == true)
        } else {
            Issue.record("Expected verified phase after override")
        }
    }

    @Test("overrideVerificationFailure in a non-verified phase is a no-op (ERR-05 wrong-phase guard)")
    func overrideVerificationFailureWrongPhaseNoOp() {
        // F08 → F11/C-K ERR lens: the negative branch of
        // `guard case .verified(var report) = phase else { return }`
        // (DocumentState.overrideVerificationFailure) was unexercised. In any
        // non-verified phase the call must return without mutating the phase
        // — no crash, no spurious transition.
        let state = DocumentState()
        state.phase = .editing
        state.overrideVerificationFailure()
        let isStillEditing: Bool = {
            if case .editing = state.phase { return true } else { return false }
        }()
        #expect(isStillEditing, "wrong-phase override must not mutate the phase")
    }
}

