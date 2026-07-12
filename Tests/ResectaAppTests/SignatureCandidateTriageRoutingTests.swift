import Testing
import Foundation
import CoreGraphics
@testable import ResectaApp
@testable import RedactionEngine

// DRAW-3 — App-side half of the "triage-only, never auto-apply" contract for
// signature heuristic candidates. The engine emits `.pii(.signatureCandidate)`
// detections; `RedactionState.applyDetectionResults` is designed to peel
// those out and route them into `pendingTriage` rather than creating
// regions, regardless of the user's `autoApplyDetections` preference.
//
// DRAW-3 contract.

@Suite("Signature Candidate Triage Routing")
@MainActor
struct SignatureCandidateTriageRoutingTests {

    @Test("applyDetectionResults does not create a region for a signature candidate; it routes to pendingTriage")
    func signatureCandidateRoutesToTriage() {
        let state = RedactionState()
        let signature = DetectionResult(
            normalizedRect: CGRect(x: 0.4, y: 0.5, width: 0.4, height: 0.1),
            kind: .pii(.signatureCandidate),
            confidence: 0.7
        )

        state.applyDetectionResults([0: [signature]], undoManager: nil)

        // The auto-apply path produced no region.
        #expect((state.regions[0]?.count ?? 0) == 0,
                "Signature candidates must never be auto-applied as regions")
        // The candidate landed in pendingTriage with the default selection.
        #expect(state.pendingTriage?[0]?.count == 1,
                "Signature candidates should appear in pendingTriage")
        #expect(state.triageSelections[signature.id] == true,
                "Signature candidates default to selected for user review")
    }

    @Test("Signature candidates are partitioned from non-signature detections — non-signatures auto-apply, signatures go to triage")
    func partitioningKeepsBothPaths() {
        let state = RedactionState()
        let ssn = DetectionResult(
            normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.04),
            kind: .pii(.ssn), confidence: 0.95
        )
        let signature = DetectionResult(
            normalizedRect: CGRect(x: 0.4, y: 0.5, width: 0.4, height: 0.1),
            kind: .pii(.signatureCandidate), confidence: 0.7
        )

        state.applyDetectionResults([0: [ssn, signature]], undoManager: nil)

        // SSN auto-applied; signature did not.
        #expect(state.regions[0]?.count == 1,
                "Non-signature detections continue to auto-apply")
        #expect(state.regions[0]?.first?.source == .detectedPII(kind: .ssn))
        #expect(state.pendingTriage?[0]?.count == 1,
                "Signature candidate landed in pendingTriage")
        #expect(state.pendingTriage?[0]?.first?.id == signature.id)
    }

    @Test("Multiple signature candidates across pages all land in pendingTriage with no regions")
    func multiPageSignatureCandidates() {
        let state = RedactionState()
        let sig0 = DetectionResult(
            normalizedRect: CGRect(x: 0.4, y: 0.5, width: 0.4, height: 0.1),
            kind: .pii(.signatureCandidate), confidence: 0.7
        )
        let sig1 = DetectionResult(
            normalizedRect: CGRect(x: 0.5, y: 0.4, width: 0.3, height: 0.08),
            kind: .pii(.signatureCandidate), confidence: 0.6
        )

        state.applyDetectionResults([0: [sig0], 2: [sig1]], undoManager: nil)

        #expect((state.regions[0]?.count ?? 0) == 0)
        #expect((state.regions[2]?.count ?? 0) == 0)
        #expect(state.pendingTriage?[0]?.count == 1)
        #expect(state.pendingTriage?[2]?.count == 1)
        // All candidates default to selected.
        #expect(state.triageSelections[sig0.id] == true)
        #expect(state.triageSelections[sig1.id] == true)
    }
}
