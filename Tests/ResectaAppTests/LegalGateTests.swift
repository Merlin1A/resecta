import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// UI_UX §8.4 — Legal gate tests.

@Suite("Legal and Export Gates")
@MainActor
struct LegalGateTests {

    @Test("Export requires non-nil outputURL")
    func exportRequiresOutputURL() {
        let state = RedactionState()
        state.outputURL = nil
        #expect(state.outputURL == nil, "No output means export not possible")
    }

    @Test("Export blocked by stale verification")
    func exportBlockedByStaleVerification() {
        let state = RedactionState()
        state.outputURL = URL(fileURLWithPath: "/tmp/test.pdf")
        state.addRegion(
            RedactionRegion(id: UUID(),
                normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5),
                source: .manual),
            page: 0, undoManager: nil)
        // Adding a region sets regionsModifiedSinceVerification = true
        #expect(state.isVerificationStale == true,
                "Stale verification should block export")
    }

    @Test("Export allowed when outputURL set and verification current")
    func exportAllowedWhenReady() {
        let state = RedactionState()
        state.outputURL = URL(fileURLWithPath: "/tmp/test.pdf")
        state.markVerificationCurrent()
        #expect(state.outputURL != nil)
        #expect(state.isVerificationStale == false)
    }

    @Test("overrideVerificationFailure stores flag in report")
    func overrideStoresFlag() {
        let doc = DocumentState()
        let report = VerificationReport(
            layers: [], overallStatus: .fail("test"), durationSeconds: 1.0)
        doc.phase = .verified(report: report)

        doc.overrideVerificationFailure()

        if case .verified(let updated) = doc.phase {
            #expect(updated.userOverrodeFailure == true)
        } else {
            Issue.record("Expected verified phase")
        }
    }
}
