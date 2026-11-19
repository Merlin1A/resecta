import Foundation
import RedactionEngine

extension SearchState {
    // MARK: - Diagnostics

    /// Setter used by the scan orchestration in `SearchAndRedactSheet`.
    func setDoctypeExplanation(_ explanation: DoctypeExplanation?) {
        lastDoctypeExplanation = explanation
    }

    /// The stored scan report with the two post-scan,
    /// view-state counts folded in: `appliedCount` from `appliedResultIDs`
    /// and `deselectedCount` from triage selections. `makeCoverageReport`
    /// deliberately leaves both at 0 at scan completion — nothing is applied
    /// or deselected yet (see `CoverageReport` in `SearchTypes`). The coverage
    /// panel and the shared audit snapshot read THIS rather than
    /// `lastCoverageReport` directly, so both reflect the user's current
    /// apply/deselect state instead of a frozen scan-time zero. Returns nil
    /// when no scan report exists (panel hidden), mirroring
    /// `lastCoverageReport`. A pure derivation over already-reset state, so it
    /// needs no teardown of its own. See `withAppliedCount` /
    /// `withDeselectedCount`.
    func coverageReportForDisplay() -> CoverageReport? {
        lastCoverageReport?
            .withAppliedCount(appliedResultIDs.count)
            .withDeselectedCount(deselectedCount)
    }

    /// Value snapshot of the session's deselection facts,
    /// captured by `PipelineCoordinator.runFullPipeline` at run entry and
    /// surfaced on the verification-results screen. Gated on the exact
    /// condition the scan coverage panel mounts under
    /// (`SearchResultsSection`: a stored scan report + `.piiScan` mode)
    /// and derived from the same live `isSelected` state
    /// (`deselectedCount`), so the two surfaces read from one
    /// definition and cannot disagree. Nil for plain-text sessions or
    /// before a scan lands — the results screen renders nothing then.
    func deselectionSnapshotForRun() -> RedactionState.DeselectionSnapshot? {
        guard searchModeType == .piiScan, lastCoverageReport != nil else {
            return nil
        }
        return RedactionState.DeselectionSnapshot(
            items: results.filter { !$0.isSelected && $0.hasBox }, totalCount: totalCount)
    }

    /// Accumulate per-page overlap-suppressed counts. Invoked from
    /// `DocumentSearcher.overlapSink` during scanning.
    func accumulateOverlapSuppression(_ counts: [PIICategory: Int]) {
        for (category, count) in counts {
            pendingOverlapSuppressed[category, default: 0] += count
        }
    }

    /// Reset the running overlap tally. Called before each scan
    /// kickoff by `SearchAndRedactSheet.triggerSearch`.
    func resetOverlapSuppression() {
        pendingOverlapSuppressed = [:]
    }

    /// Accumulate per-page below-threshold drop counts. Invoked
    /// from `DocumentSearcher.belowThresholdSink` during scanning.
    func accumulateBelowThresholdSuppression(_ count: Int) {
        pendingBelowThresholdSuppressed += count
    }

    /// Reset the running below-threshold tally. Called before
    /// each scan kickoff by `SearchAndRedactSheet.triggerSearch`.
    func resetBelowThresholdSuppression() {
        pendingBelowThresholdSuppressed = 0
    }

    /// Route the engine's regex-rejection sink into the callout. The
    /// searcher fires it once, with the gate's reason, when a regex search
    /// starts on a pattern the safety gate refuses — the stream then
    /// finishes empty instead of silently reading as "0 results". The
    /// trigger pre-validates and normally sets `regexError` first; a
    /// message already standing wins, so the sink never overwrites it.
    func recordRegexRejection(_ reason: String) {
        guard regexError == nil else { return }
        regexError = reason
    }

    // MARK: - Intra-Session Diff

    /// Deterministic, geometry+category-only fingerprint
    /// of a single `SearchResult`. The output string is
    /// `"<pageIndex>|<x>,<y>,<w>,<h>|<categoryRawValue ?? '''>"` where
    /// the rect components are formatted to 3 decimal places. NEVER
    /// includes `matchedText`, `contextSnippet`, `term`, `rationale`,
    /// or any other document-derived value — pinned by
    /// `fingerprintNoMatchedText` load-bearing test.
    /// `static` so the helper can be invoked from `for`-loop bodies
    /// without capturing `self`.
    static func fingerprint(for r: SearchResult) -> String {
        let rounded = String(
            format: "%.3f,%.3f,%.3f,%.3f",
            r.normalizedRect.origin.x,
            r.normalizedRect.origin.y,
            r.normalizedRect.size.width,
            r.normalizedRect.size.height
        )
        return "\(r.pageIndex)|\(rounded)|\(r.piiCategory?.rawValue ?? "")"
    }

    /// Compute the intra-session diff between the most recent
    /// captured snapshot and the current `results`. Returns nil when
    /// no prior snapshot exists (first scan of session, or after
    /// `clear()` wiped the snapshot). The 3-tuple shape mirrors
    /// the `(added, removed, unchanged)` contract.
    /// O(n) over `results` + O(|prior|) for set arithmetic.
    func diffSinceLastScan() -> (added: Int, removed: Int, unchanged: Int)? {
        guard let prior = priorScanFingerprints else { return nil }
        var current: Set<String> = []
        current.reserveCapacity(results.count)
        for r in results {
            current.insert(Self.fingerprint(for: r))
        }
        let added = current.subtracting(prior).count
        let removed = prior.subtracting(current).count
        let unchanged = prior.intersection(current).count
        return (added: added, removed: removed, unchanged: unchanged)
    }
}
