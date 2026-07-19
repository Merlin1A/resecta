import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

@Suite("SearchState", .tags(.search))
@MainActor
struct SearchStateTests {

    @Test("clear() resets all fields")
    func clearResetsAll() {
        let state = SearchState()
        state.queryText = "test"
        state.results = [makeResult(term: "test")]
        state.isSearching = true
        state.currentSearchPage = 5
        state.totalPages = 10

        state.clear()

        #expect(state.queryText == "")
        #expect(state.results.isEmpty)
        #expect(state.isSearching == false)
        #expect(state.currentSearchPage == 0)
        #expect(state.totalPages == 0)
    }

    @Test("toggleSelectAll selects all when some deselected")
    func toggleSelectAllSelectsAll() {
        let state = SearchState()
        state.results = [
            makeResult(isSelected: true),
            makeResult(isSelected: false),
            makeResult(isSelected: true)
        ]

        state.toggleSelectAll()

        #expect(state.results.allSatisfy { $0.isSelected })
    }

    @Test("toggleSelectAll deselects all when all selected")
    func toggleSelectAllDeselectsAll() {
        let state = SearchState()
        state.results = [
            makeResult(isSelected: true),
            makeResult(isSelected: true)
        ]

        state.toggleSelectAll()

        #expect(!state.results.contains { $0.isSelected })
    }

    @Test("toggleSelection toggles individual result")
    func toggleSelectionToggles() {
        let state = SearchState()
        let result = makeResult(isSelected: true)
        state.results = [result]

        state.toggleSelection(for: result.id)

        #expect(state.results.first?.isSelected == false)

        state.toggleSelection(for: result.id)

        #expect(state.results.first?.isSelected == true)
    }

    @Test("selectedCount reports correct count")
    func selectedCountCorrect() {
        let state = SearchState()
        state.results = [
            makeResult(isSelected: true),
            makeResult(isSelected: false),
            makeResult(isSelected: true)
        ]

        #expect(state.selectedCount == 2)
    }

    @Test("cancelSearch cancels active task")
    func cancelSearchCancelsTask() async {
        let state = SearchState()
        state.isSearching = true
        state.activeSearchTask = Task { try? await Task.sleep(for: .seconds(60)) }

        await state.cancelSearch()

        #expect(state.isSearching == false)
        #expect(state.activeSearchTask == nil)
    }

    @Test("resultVersion increments on mutations")
    func resultVersionIncrements() {
        let state = SearchState()
        let v0 = state.resultVersion

        state.appendResult(makeResult())
        state.flushPendingResults() // P2: results are batched; flush to commit
        #expect(state.resultVersion > v0)

        let v1 = state.resultVersion
        state.toggleSelectAll()
        #expect(state.resultVersion > v1)
    }

    // MARK: - D06-F2 Part 1: below-threshold suppression tally

    @Test("accumulateBelowThresholdSuppression sums per-page counts")
    func accumulatesBelowThresholdAcrossPages() {
        let state = SearchState()
        state.accumulateBelowThresholdSuppression(2)
        state.accumulateBelowThresholdSuppression(3)
        #expect(state.pendingBelowThresholdSuppressed == 5)
    }

    @Test("resetBelowThresholdSuppression zeroes the running tally")
    func resetBelowThresholdClears() {
        let state = SearchState()
        state.accumulateBelowThresholdSuppression(4)
        state.resetBelowThresholdSuppression()
        #expect(state.pendingBelowThresholdSuppressed == 0)
    }

    @Test("clear() also resets the below-threshold tally")
    func clearResetsBelowThreshold() {
        let state = SearchState()
        state.accumulateBelowThresholdSuppression(6)
        state.clear()
        #expect(state.pendingBelowThresholdSuppressed == 0)
    }

    @Test("clearResults() also resets the below-threshold tally")
    func clearResultsResetsBelowThreshold() {
        let state = SearchState()
        state.accumulateBelowThresholdSuppression(7)
        state.clearResults()
        #expect(state.pendingBelowThresholdSuppressed == 0)
    }

    @Test("makeCoverageReport threads the below-threshold tally into the report")
    func makeCoverageReportPropagatesBelowThreshold() {
        // D06-F2 Part 1 report-wiring: the tally must land in
        // `belowThresholdSuppressedCount` (no longer a hardcoded 0).
        let report = SearchAndRedactSheet.makeCoverageReport(
            scannedPages: 2,
            enabled: [.ssn],
            results: [],
            overlapSuppressed: [:],
            belowThresholdSuppressed: 7,
            startedAt: Date(timeIntervalSince1970: 0),
            completedAt: Date(timeIntervalSince1970: 1)
        )
        #expect(report.belowThresholdSuppressedCount == 7)
        // Part-2 fields remain 0 this session (Session 7 fills appliedCount /
        // deselectedCount from view state).
        #expect(report.appliedCount == 0)
        #expect(report.deselectedCount == 0)
    }

    // MARK: - D06-F2 Part 2 — applied/deselected coverage counts

    @Test("deselectedCount counts results left un-checked (complement of selectedCount)")
    func deselectedCountReflectsSelection() {
        let state = SearchState()
        state.results = [
            makeResult(isSelected: true),
            makeResult(isSelected: false),
            makeResult(isSelected: false),
        ]
        #expect(state.selectedCount == 1)
        #expect(state.deselectedCount == 2)
    }

    @Test("coverageReportForDisplay folds live applied + deselected counts into the stored report")
    func coverageReportForDisplayFoldsLiveCounts() {
        let state = SearchState()
        let r1 = makeResult(isSelected: true)
        let r2 = makeResult(isSelected: true)
        let r3 = makeResult(isSelected: false)
        state.results = [r1, r2, r3]
        state.appliedResultIDs = [r1.id, r2.id]            // 2 applied
        state.setCoverageReport(makeScanSkeletonReport())  // scan-time: 0/0

        let folded = state.coverageReportForDisplay()
        #expect(folded?.appliedCount == 2)                 // from appliedResultIDs
        #expect(folded?.deselectedCount == 1)              // r3 left un-checked
        // The fold preserves the scan-time fields untouched.
        #expect(folded?.belowThresholdSuppressedCount == 3)
        #expect(folded?.scannedPageCount == 2)
    }

    @Test("coverageReportForDisplay is nil when no scan report exists")
    func coverageReportForDisplayNilWithoutReport() {
        let state = SearchState()
        state.results = [makeResult(isSelected: false)]
        #expect(state.coverageReportForDisplay() == nil)
    }

    @Test("clear() drops the coverage report so folded counts reset")
    func clearResetsCoverageReportForDisplay() {
        let state = SearchState()
        let r = makeResult(isSelected: false)
        state.results = [r]
        state.appliedResultIDs = [r.id]
        state.setCoverageReport(makeScanSkeletonReport())
        state.clear()
        #expect(state.coverageReportForDisplay() == nil)
        #expect(state.deselectedCount == 0)
    }

    @Test("clearResults() drops the coverage report so folded counts reset")
    func clearResultsResetsCoverageReportForDisplay() {
        let state = SearchState()
        let r1 = makeResult(isSelected: false)
        let r2 = makeResult(isSelected: false)
        state.results = [r1, r2]
        state.appliedResultIDs = [r1.id]
        state.setCoverageReport(makeScanSkeletonReport())
        state.clearResults()
        #expect(state.coverageReportForDisplay() == nil)
        #expect(state.deselectedCount == 0)
    }

    // MARK: - Helpers

    private func makeResult(
        term: String = "test",
        isSelected: Bool = true
    ) -> SearchResult {
        SearchResult(
            pageIndex: 0,
            normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.04),
            matchedText: "test",
            contextSnippet: "…some test text…",
            source: .textLayer,
            term: term,
            isSelected: isSelected
        )
    }

    // MARK: - UP-2 — audit surfaces hidden for V1.0

    @Test("Audit-export / scan-coverage surfaces are gated off for 1.0 (UP-2)")
    func testAuditSurfacesHiddenForV1() {
        // Export Audit, the Scan Coverage report (incl. Share Snapshot), and
        // the verification-results "Review" hook are behind this flag per
        // ~/resecta-ui-polish-planning/00-DIRECTION.md. An accidental flip
        // re-exposes all three surfaces — this pin makes that a loud CI red.
        // Restore path (1.1, PB-75): flip the flag AND update this test.
        #expect(SearchState.searchAuditSurfacesEnabled == false)
    }

    // MARK: - UP-4 — doctype diagnostic surfaces hidden for V1.0

    @Test("Doctype diagnostic surfaces are gated off for 1.0 (UP-4)")
    func testDiagnosticSurfacesHiddenForV1() {
        // The doctype banner and the footer Document-profile disclosure
        // are behind this flag per
        // ~/resecta-ui-polish-planning/02-DIRECTION-UP4-declutter.md. An
        // accidental flip re-exposes both mounts — this pin makes that a
        // loud CI red. Restore path (1.1, SC/PB-75): flip the flag AND
        // update this test.
        #expect(SearchState.searchDiagnosticSurfacesEnabled == false)
    }

    /// D06-F2 Part 2 — a scan-completion skeleton report. `makeCoverageReport`
    /// leaves `appliedCount` / `deselectedCount` at 0; `coverageReportForDisplay()`
    /// folds the live counts in. `belowThresholdSuppressed: 3` pins a scan-time
    /// field so the fold can be shown to leave it untouched.
    private func makeScanSkeletonReport() -> CoverageReport {
        SearchAndRedactSheet.makeCoverageReport(
            scannedPages: 2,
            enabled: [.ssn],
            results: [],
            overlapSuppressed: [:],
            belowThresholdSuppressed: 3,
            startedAt: Date(timeIntervalSince1970: 0),
            completedAt: Date(timeIntervalSince1970: 1)
        )
    }
}

// MARK: - Trigger single-flight gate

@Suite("SearchState trigger single-flight", .tags(.search))
@MainActor
struct SearchStateTriggerSingleFlightTests {

    @Test("Overlapping begin coalesces into exactly one deferred retrigger")
    func triggerSetupSingleFlight() {
        let state = SearchState()
        #expect(state.beginTriggerSetup() == true, "first caller owns the window")
        #expect(state.beginTriggerSetup() == false, "overlapping caller coalesces")
        #expect(state.beginTriggerSetup() == false, "N overlapping callers still coalesce to one")
        #expect(state.endTriggerSetup() == true, "the coalesced request surfaces once at close")
        #expect(state.endTriggerSetup() == false, "consumed — no retrigger loop")
        #expect(state.beginTriggerSetup() == true, "the window reopens after close")
        #expect(state.endTriggerSetup() == false, "no retrigger when none was requested")
    }

    @Test("Run-state discriminators reset with clearResults")
    func runStateDiscriminatorsReset() {
        let state = SearchState()
        state.hasCompletedRunSinceClear = true
        state.scanStartFailed = true
        state.clearResults()
        #expect(state.hasCompletedRunSinceClear == false)
        #expect(state.scanStartFailed == false)
        state.hasCompletedRunSinceClear = true
        state.scanStartFailed = true
        state.clear()
        #expect(state.hasCompletedRunSinceClear == false)
        #expect(state.scanStartFailed == false)
    }
}

extension Tag {
    @Tag static var search: Self
}
