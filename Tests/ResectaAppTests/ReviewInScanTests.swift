import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// The Detection Sweep's note ("N possible items remain") offers Review in
// Scan: back to the editor with Scan running over the document, the same
// session the toolbar's Scan opens. Real `DocumentState`, `RedactionState`
// and `SearchState`; the seeded reports.

@Suite("Review in Scan from the sweep's note")
@MainActor
struct ReviewInScanTests {

    @Test("Review in Scan returns to the editor with a Scan session that runs on appear")
    func routeOpensScan() {
        let documentState = DocumentState()
        documentState.phase = .verified(report: VerificationDebugFixtures.secureScreenshot)
        let redactionState = RedactionState()
        VerificationResultsView.reviewInScan(documentState: documentState, redactionState: redactionState)
        #expect(documentState.phaseKind == .editing)
        #expect(redactionState.activeSearch?.searchModeType == .piiScan)
        #expect(redactionState.activeSearch?.pendingAutoRunScan == true)
    }

    @Test("The Scan session is the detectors' scan, armed to run once")
    func scanSession() {
        let session = SearchState.scanSession()
        #expect(session.searchModeType == .piiScan)
        #expect(session.pendingAutoRunScan)
    }

    @Test("Offered only on a Detection Sweep row that reports possible items remaining")
    func offeredOnlyWithItemsRemaining() throws {
        let note = try #require(VerificationDebugFixtures.secureScreenshot.layers.first { $0.layer == .detectionSweep })
        let pass = try #require(VerificationDebugFixtures.secureAllPass.layers.first { $0.layer == .detectionSweep })
        let recheck = try #require(VerificationDebugFixtures.secureAllPass.layers.first { $0.layer == .searchRecheck })
        #expect(LayerResultRow.offersReviewInScan(layer: note))
        #expect(!LayerResultRow.offersReviewInScan(layer: pass))
        #expect(!LayerResultRow.offersReviewInScan(layer: recheck))
        #expect(LayerResultRow.reviewInScanLabel == "Review in Scan")
    }
}
