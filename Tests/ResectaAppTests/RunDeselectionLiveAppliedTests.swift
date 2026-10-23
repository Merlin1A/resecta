import Testing
import Foundation
import CoreGraphics
import RedactionEngine
@testable import ResectaApp

// The run's deselection facts exclude every result whose applied region
// is live. The strip's single-result Apply and the nudge's accept
// leave `isSelected` false by design, so the session's un-checked list
// still names a result the user applied; the run-entry reader
// (`RedactionState.runEntryDeselectionSnapshot()`, the one both run
// sites read) drops the results in `liveAppliedSearchResultIDs` — the
// join in `RedactionState+AppliedResults.swift` — so an Undo puts the
// result back in the count.

@Suite("Run deselection — live applied results excluded", .tags(.search))
@MainActor
struct RunDeselectionLiveAppliedTests {

    @Test("A strip apply of 1 of 3 unticked results leaves 2 deselected; Undo restores 3")
    func stripApplyLeavesTwoUndoRestoresThree() async throws {
        let redaction = RedactionState()
        let search = makeUntickedScanSession(total: 3)
        redaction.activeSearch = search
        let undo = makeUndoManager()
        let applied = try #require(search.results.first)

        undo.beginUndoGrouping()
        let outcome = await redaction.applyFindings(.searchResult(id: applied.id), undoManager: undo)
        undo.endUndoGrouping()
        try #require(outcome?.applied == 1, "precondition: the strip applied the one result")
        #expect(redaction.liveAppliedSearchResultIDs == [applied.id])

        let atRun = redaction.runEntryDeselectionSnapshot()
        #expect(atRun?.deselectedCount == 2, "today 3: the snapshot is `results.filter { !$0.isSelected }`")
        #expect(atRun?.items.contains { $0.id == applied.id } == false)
        #expect(atRun?.totalCount == 3, "the session's total is unchanged")

        undo.undo()
        #expect(redaction.liveAppliedSearchResultIDs.isEmpty)
        #expect(redaction.runEntryDeselectionSnapshot()?.deselectedCount == 3,
                "the undone apply puts the result back among the deselected")
    }

    @Test("The sheet dismissed after the strip apply: the run still reads 2")
    func dismissedSheetStillExcludesTheAppliedResult() async throws {
        let redaction = RedactionState()
        let search = makeUntickedScanSession(total: 3)
        redaction.activeSearch = search
        let applied = try #require(search.results.last)

        _ = await redaction.applyFindings(.searchResult(id: applied.id), undoManager: nil)
        // Mirrors the editor nil-ing `activeSearch` on sheet dismiss
        // (DeselectionVisibilityTests' `nilActiveSearchStillRecordsPendingSnapshot`).
        redaction.activeSearch = nil

        #expect(redaction.runEntryDeselectionSnapshot()?.deselectedCount == 2)
    }
}

// MARK: - Fixtures

/// A `.piiScan` session with `total` results, ALL un-checked, and a stored
/// scan report — `DeselectionVisibilityTests.makeScanSession(total:deselected:)`
/// with `deselected == total` (that helper is file-private; promote it to
/// `Fixtures/` instead of keeping this copy if the lane prefers).
@MainActor
private func makeUntickedScanSession(total: Int) -> SearchState {
    let state = SearchState()
    state.searchModeType = .piiScan
    state.results = (0..<total).map { index in
        SearchResult(
            pageIndex: 0,
            normalizedRect: CGRect(
                x: 0.1 + 0.25 * CGFloat(index), y: 0.1, width: 0.05, height: 0.02),
            matchedText: "match-\(index)",
            contextSnippet: "context-\(index)",
            source: .textLayer,
            term: "term",
            isSelected: false
        )
    }
    state.setCoverageReport(CoverageReport(
        scannedPageCount: 1,
        enabledCategories: [.ssn],
        candidateCountByCategory: [.ssn: total],
        appliedCount: 0,
        deselectedCount: 0,
        belowThresholdSuppressedCount: 0,
        overlapSuppressedCountByCategory: [:],
        startedAt: Date(timeIntervalSince1970: 0),
        completedAt: Date(timeIntervalSince1970: 1)
    ))
    return state
}
