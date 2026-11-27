import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// The Detection Sweep's note ("N possible items remain") and its
// needs-review form offer Review in Scan: back to the editor with Scan
// running over the document, the same session the toolbar's Scan opens.
// Real `DocumentState`, `RedactionState` and `SearchState`; the seeded
// reports.

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
        #expect(redactionState.activeSearch?.pendingAutoRun == .piiScan)
    }

    @Test("The Scan session is the detectors' scan, armed to run once")
    func scanSession() {
        let session = SearchState.scanSession()
        #expect(session.searchModeType == .piiScan)
        #expect(session.pendingAutoRun == .piiScan)
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

    /// The seeded report's Detection Sweep row with one field changed.
    private static func sweepRow(
        _ base: LayerResult, layer: VerificationLayer? = nil, status: VerificationStatus? = nil,
        lines: [SearchRecheckQueryLine]?, couldNotVerify: Bool = false
    ) -> LayerResult {
        let identity = layer ?? base.layer ?? .detectionSweep
        return LayerResult(name: identity.name, symbolName: identity.symbolName, status: status ?? base.status,
                           shortDescription: base.shortDescription, detailDescription: base.detailDescription,
                           pageReferences: base.pageReferences, durationSeconds: base.durationSeconds,
                           reviewTermTexts: nil, layer: identity, queryLines: lines, couldNotVerify: couldNotVerify)
    }

    @Test("Offered on the sweep's needs-review row too, and not on its could-not-verify row, a row with no query lines or another check's needs-review row")
    func offeredOnNeedsReviewSweep() throws {
        let sweep = try #require(VerificationDebugFixtures.searchableSweepReview.layers.first { $0.layer == .detectionSweep })
        #expect(sweep.status.isAttention)
        #expect(LayerResultRow.offersReviewInScan(layer: sweep))

        // As the engine builds it: found 3, applied 1, 2 remaining.
        let engineLine = SearchRecheckQueryLine(
            label: "Scan (17 detectors)", foundCount: 3, foundHitCap: false, appliedCount: 1,
            remainingCount: 2, route: .mixed(textPages: 3, ocrPages: 3),
            perTerm: [.init(term: "Social Security number", found: 3, applied: 1, remaining: 2)])
        #expect(LayerResultRow.offersReviewInScan(layer: Self.sweepRow(sweep, lines: [engineLine])))

        let couldNotRead = Self.sweepRow(
            sweep, status: .warn("Ran the detectors on the output; 1 page could not be read"),
            lines: sweep.queryLines, couldNotVerify: true)
        #expect(!LayerResultRow.offersReviewInScan(layer: couldNotRead))
        #expect(!LayerResultRow.offersReviewInScan(layer: Self.sweepRow(sweep, lines: nil)))
        #expect(!LayerResultRow.offersReviewInScan(layer: Self.sweepRow(sweep, layer: .ocrCheck, lines: sweep.queryLines)))
    }

    @Test("The needs-review sweep adds no possible-items line to the share sheet")
    func needsReviewSweepAddsNoPossibleItemsLine() throws {
        let report = VerificationDebugFixtures.searchableSweepReview
        let sweep = try #require(report.layers.first { $0.layer == .detectionSweep })
        #expect(!VerificationRowModel.hasItemsRemaining(sweep))
        #expect(DocumentEditorView.possibleItemLines(report: report, formFieldCount: 0).isEmpty)
    }
}
