import Foundation
import RedactionEngine

// The state half of a search run's end, lifted from `finishSearchRun`
// (now in State/SearchRun.swift) so a hosted test runs the decision
// and the tail it gates; the run keeps the sink teardown and the
// VoiceOver completion line. No line inside the moved body changes but
// the three that read the Scan facts from `scan`.

extension SearchAndRedactSheet {

    /// What a Scan run's tail reads beyond the session: the categories it
    /// ran with and its start time, for the coverage report.
    struct ScanRunFacts {
        let enabled: Set<PIICategory>
        let startedAt: Date
    }

    /// The state half of a run's end, once its stream is done. False when
    /// the run ends as a cancelled one (`SearchState.runEndsCancelled`: a
    /// cancelled task, or the current run stopped at the result limit),
    /// and nothing below runs. Else the last flush, the run-state flips
    /// and, for a Scan (`scan` non-nil), the coverage report and run
    /// record; true, and the caller tears the sinks down and posts the
    /// VoiceOver completion line. `internal` so a hosted test runs it.
    @MainActor
    static func endRunState(
        run: Int, taskCancelled: Bool, scan: ScanRunFacts?,
        searchState: SearchState, redactionState: RedactionState
    ) -> Bool {
        guard !searchState.runEndsCancelled(run: run, taskCancelled: taskCancelled) else { return false }
        searchState.closeAccount(.completed, run: run)
        searchState.flushPendingResults()
        // A completed (non-cancelled) run flips the
        // empty-state discriminator from "not run yet" to a
        // genuine result verdict.
        searchState.hasCompletedRunSinceClear = true
        searchState.isSearching = false

        if let scan {
            let report = Self.makeCoverageReport(
                scannedPages: searchState.totalPages,
                enabled: scan.enabled,
                results: searchState.results,
                overlapSuppressed: searchState.pendingOverlapSuppressed,
                belowThresholdSuppressed: searchState.pendingBelowThresholdSuppressed,
                startedAt: scan.startedAt,
                completedAt: Date()
            )
            searchState.setCoverageReport(report)

            // Run-outcome record for the Scan interface —
            // the summary banner is the run-outcome surface
            // for both origins now. Found runs auto-dismiss
            // (the results are on screen in the sheet);
            // zero-found runs persist so "ran and found
            // nothing" stays distinguishable from "never
            // ran" after the sheet closes. Cancelled runs
            // skip this tail and leave no record.
            redactionState.recordDetectionRun(
                searchState.results.isEmpty
                    ? .nothingFound(pageCount: searchState.totalPages)
                    : .staged,
                scanSummary: .init(
                    foundCount: searchState.results.count,
                    pageCount: searchState.totalPages),
                ocrSkippedPages: searchState.ocrSkippedPages)
        }
        return true
    }
}
