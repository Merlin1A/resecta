import Testing
import Foundation
import CoreGraphics
@testable import ResectaApp
@testable import RedactionEngine

// DRAW-3 — App-side half of the review-only contract for signature
// heuristic candidates. The engine emits `.pii(.signatureCandidate)`
// detections; the detection-map origin of `applyFindings` peels
// those out and routes them into `pendingTriage` rather than creating
// regions, unconditionally (the former auto-apply preference is
// retired; the invariant this suite pins predates it and outlives it).
// Under review-first arrival the routed candidates arrive DESELECTED
// like every review arrival — the former selected-by-default routing
// died with the absent-reads-accepted fallback, so a routed candidate
// can never apply without an explicit user selection.
//
// DRAW-3 contract.

@Suite("Signature Candidate Triage Routing")
@MainActor
struct SignatureCandidateTriageRoutingTests {

    @Test("Detection-map apply does not create a region for a signature candidate; it routes to pendingTriage")
    func signatureCandidateRoutesToTriage() async {
        let state = RedactionState()
        let signature = DetectionResult(
            normalizedRect: CGRect(x: 0.4, y: 0.5, width: 0.4, height: 0.1),
            kind: .pii(.signatureCandidate),
            confidence: 0.7
        )

        await state.applyFindings(.detectionResults([0: [signature]]), undoManager: nil)

        // The direct-apply path produced no region.
        #expect((state.regions[0]?.count ?? 0) == 0,
                "Signature candidates must never be applied directly as regions")
        // The candidate landed in pendingTriage, DESELECTED like every
        // review arrival (absent id = not accepted): a follow-on
        // staged-review apply promotes nothing without a user selection.
        #expect(state.pendingTriage?[0]?.count == 1,
                "Signature candidates should appear in pendingTriage")
        #expect(state.triageSelections[signature.id] != true,
                "Routed candidates arrive deselected (review-first arrival)")
        let followOn = await state.applyFindings(.stagedDetections, undoManager: nil)
        #expect(followOn?.applied == 0,
                "an unselected routed candidate never becomes a region")
    }

    @Test("Signature candidates are partitioned from non-signature detections — non-signatures apply, signatures go to review")
    func partitioningKeepsBothPaths() async {
        let state = RedactionState()
        let ssn = DetectionResult(
            normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.04),
            kind: .pii(.ssn), confidence: 0.95
        )
        let signature = DetectionResult(
            normalizedRect: CGRect(x: 0.4, y: 0.5, width: 0.4, height: 0.1),
            kind: .pii(.signatureCandidate), confidence: 0.7
        )

        await state.applyFindings(.detectionResults([0: [ssn, signature]]), undoManager: nil)

        // SSN applied; signature did not.
        #expect(state.regions[0]?.count == 1,
                "Non-signature detections continue to apply directly")
        #expect(state.regions[0]?.first?.source == .detectedPII(kind: .ssn))
        #expect(state.pendingTriage?[0]?.count == 1,
                "Signature candidate landed in pendingTriage")
        #expect(state.pendingTriage?[0]?.first?.id == signature.id)
    }

    @Test("Multiple signature candidates across pages all land in pendingTriage with no regions")
    func multiPageSignatureCandidates() async {
        let state = RedactionState()
        let sig0 = DetectionResult(
            normalizedRect: CGRect(x: 0.4, y: 0.5, width: 0.4, height: 0.1),
            kind: .pii(.signatureCandidate), confidence: 0.7
        )
        let sig1 = DetectionResult(
            normalizedRect: CGRect(x: 0.5, y: 0.4, width: 0.3, height: 0.08),
            kind: .pii(.signatureCandidate), confidence: 0.6
        )

        await state.applyFindings(.detectionResults([0: [sig0], 2: [sig1]]), undoManager: nil)

        #expect((state.regions[0]?.count ?? 0) == 0)
        #expect((state.regions[2]?.count ?? 0) == 0)
        #expect(state.pendingTriage?[0]?.count == 1)
        #expect(state.pendingTriage?[2]?.count == 1)
        // All candidates arrive deselected (review-first arrival).
        #expect(state.triageSelections[sig0.id] != true)
        #expect(state.triageSelections[sig1.id] != true)
    }
}
