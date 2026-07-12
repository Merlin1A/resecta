import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// Pkg L (CANCEL-009 + UX-background-mid-verify-banner)
//
// Closes the gap exposed by inherited red CANCEL-009: backgrounding during
// `.verifying` used to drop the user back to `.editing`, discarding the
// fact that `outputURL` was still valid. The new contract lands on
// `.verified(report: .skipped)` so the dynamic-action banner can offer
// "Re-verify" instead of forcing a full pipeline restart.
@Suite("DocumentState — cancel-from-verifying transitions to .skipped")
@MainActor
struct DocumentStateVerifyingCancelTests {

    @Test("Cancel during verify transitions to .verified(report: .skipped)")
    func testCancelDuringVerifyingTransitionsToSkipped() {
        let doc = DocumentState()
        let redaction = RedactionState()
        let outputURL = URL(fileURLWithPath: "/tmp/valid_output.pdf")
        redaction.outputURL = outputURL
        doc.phase = .verifying(progress: .init(
            currentLayer: 2,
            totalLayers: 5,
            layerName: "Layer 2",
            completedLayers: []
        ))

        doc.cancelActivePipeline(redactionState: redaction)

        // Phase must be .verified, not .editing.
        #expect(doc.phaseKind == .verified)
        guard case .verified(let report) = doc.phase else {
            Issue.record("Expected .verified phase after cancel-from-verifying")
            return
        }
        #expect(report.overallStatus == .skipped,
                "Cancel-from-verifying must use the .skipped sentinel report")
        #expect(report.skipReason == .cancelled,
                "Cancel-from-verifying must carry .cancelled so the results copy names the real cause")

        // outputURL must be preserved — SER-6 + Pkg L contract.
        #expect(redaction.outputURL == outputURL,
                "outputURL must be preserved across cancel-from-verifying")
    }

    @Test("Cancel during verify preserves regionsModifiedSinceVerification flag")
    func testCancelDuringVerifyingPreservesStaleFlag() {
        // The flag drives the banner's dynamic action label: Re-verify when
        // false (output current), Restart when true (regions changed since
        // last successful verify). Cancelling during the verify pass must
        // not artificially flip the flag — that would mask a stale state.
        let doc = DocumentState()
        let redaction = RedactionState()
        redaction.outputURL = URL(fileURLWithPath: "/tmp/output.pdf")
        // Force the flag true via a region mutation (the public path).
        redaction.addRegion(
            RedactionRegion(
                id: UUID(),
                normalizedRect: .init(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                source: .manual
            ),
            page: 0,
            undoManager: nil
        )
        #expect(redaction.isVerificationStale == true,
                "Precondition — addRegion sets the stale flag")

        doc.phase = .verifying(progress: .init(
            currentLayer: 1,
            totalLayers: 5,
            layerName: "Layer 1",
            completedLayers: []
        ))
        doc.cancelActivePipeline(redactionState: redaction)

        #expect(redaction.isVerificationStale == true,
                "regionsModifiedSinceVerification must survive the cancel")
    }

    @Test("Cancel from verifying always yields .skipped after OQ-1 removal (CAT-240)")
    func testCancelFromVerifyingAlwaysYieldsSkipped() {
        // CAT-240 / CAT-157 / D-05: the OQ-1 `ocrReturnReport` precedence path
        // was removed — no production writer ever set it, so the field and its
        // `cancelActivePipeline` branch are gone. Cancelling mid-verify now
        // unconditionally lands on the `.skipped` sentinel regardless of any
        // prior verified report. This guard pins that the removed contract
        // stays removed.
        let doc = DocumentState()
        let redaction = RedactionState()
        doc.phase = .verifying(progress: .init(
            currentLayer: 3,
            totalLayers: 8,
            layerName: "Layer 3",
            completedLayers: []
        ))

        doc.cancelActivePipeline(redactionState: redaction)

        guard case .verified(let report) = doc.phase else {
            Issue.record("Expected .verified phase after cancel-from-verifying")
            return
        }
        #expect(report.overallStatus == .skipped,
                "Cancel-from-verifying must land on the .skipped sentinel, not a prior report")
        #expect(report.skipReason == .cancelled,
                "Cancel-from-verifying must carry .cancelled regardless of prior state")
    }
}
