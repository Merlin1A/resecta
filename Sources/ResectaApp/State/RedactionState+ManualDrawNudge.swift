import Foundation
import RedactionEngine

extension RedactionState {
    // MARK: - Manual-Draw Nudge

    /// Pure-function predicate driving the manual-draw nearby-PII nudge.
    /// Returns the first eligible `SearchResult` on `page` that sits
    /// within `proximityNormalized` of `addedRegion`'s edges, or nil if
    /// no candidate qualifies. Eligibility:
    /// - Same page as the added region (cross-page nudges are out of
    ///   scope; the user's mental model is page-local).
    /// - `piiCategory != nil` (text / regex / multi-term hits do not
    ///   qualify — the nudge is specifically about PII discovery).
    /// - `result.id` is NOT in `appliedIDs` — the user has not already
    ///   redacted this match through the apply flow.
    /// - No region covers the result (`resultIsCovered`): not the new
    ///   region and none of `coveringRects`, the page's other live
    ///   regions. A covered name is already redacted, and prompting the
    ///   user to "add" it again would be redundant. The apply's
    ///   skip-on-overlap reads the same rule.
    /// - Edge-to-edge normalized distance ≤ `proximityNormalized`.
    /// Bypassed entirely when `suppressed` is true so a session-
    /// suppressed user never re-incurs the per-result scan cost.
    /// Pure — testable without a SwiftUI host or `RedactionState`
    /// instance. Pinned by `ManualDrawNudgeTests`.
    static func nearbyUnappliedPIIMatch(
        addedRegion: RedactionRegion,
        page: Int,
        results: [SearchResult],
        appliedIDs: Set<UUID>,
        suppressed: Bool,
        proximityNormalized: CGFloat,
        coveringRects: [CGRect] = [], coveringStripRects: [CGRect] = []
    ) -> SearchResult? {
        guard !suppressed else { return nil }
        guard !results.isEmpty else { return nil }
        let addedRect = addedRegion.normalizedRect
        for result in results {
            guard result.pageIndex == page, result.hasBox else { continue }
            guard result.piiCategory != nil else { continue }
            guard !appliedIDs.contains(result.id) else { continue }
            let resultRect = result.normalizedRect
            if resultIsCovered(result, paints: [addedRect] + coveringRects, strips: coveringStripRects) { continue }
            let dx = max(0, max(addedRect.minX - resultRect.maxX,
                                resultRect.minX - addedRect.maxX))
            let dy = max(0, max(addedRect.minY - resultRect.maxY,
                                resultRect.minY - addedRect.maxY))
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance <= proximityNormalized {
                return result
            }
        }
        return nil
    }

    /// Accept a nudged `SearchResult` directly: convert it into a
    /// redaction region whose `Source` carries the result's
    /// `MatchRationale` verbatim. The caller passes the nudge captured
    /// at toast enqueue (the enqueue path clears `pendingManualDrawNudge`).
    /// Routes through `addRegion` for the standard undo / region-version /
    /// page-index mutations, and mirrors the search-origin apply's
    /// per-result side effects (regionMetadata + audit snapshot; the
    /// sheet's markers derive from that audit). The toast outlives the
    /// sheet, so the accept needs no live session; it also outlives a run
    /// start, so the accept refuses while the pipeline owns the regions
    /// (`!canMutateRegions`), as `applyFindings` does. The suppression flag is NOT set on accept — the user is
    /// engaged; the toast-enqueue path sets it.
    @discardableResult
    func acceptManualDrawNudge(
        _ nudge: SearchResult,
        undoManager: UndoManager?,
        documentState: DocumentState? = nil
    ) -> RedactionRegion? {
        if let documentState, !documentState.canMutateRegions { return nil }
        let region = RedactionRegion(placing: nudge)
        // Category stamp — mirrors `prepareApply` so a nudge-accepted
        // region stays indistinguishable from a sheet-applied region.
        let nudgeKind: DetectionResult.Kind = nudge.piiCategory
            .map { .pii($0.piiKind) } ?? .searchMatch(term: nudge.term)
        let metadata = RegionMetadata(
            piiKind: nudgeKind,
            confidence: regionConfidence(for: nudge),
            matchedText: nudge.matchedText,
            recognitionLevel: nudge.source == .textLayer ? .fast : .accurate
        )
        let audit = MatchAuditSnapshot(
            origin: .search,
            resultID: nudge.id,
            regionID: region.id,
            pageIndex: nudge.pageIndex,
            matchedText: nudge.matchedText,
            source: nudge.source,
            piiCategory: nudge.piiCategory,
            piiConfidence: nudge.piiConfidence,
            rationale: nudge.rationale,
            term: nudge.term,
            appliedAt: Date(),
            // A nudge is a PII-scan-origin match by predicate (the
            // detector's category, never a typed query) — no search to
            // re-run, so the Search Re-check never sees it.
            searchRecord: nil, inkFitDegraded: nudge.inkFitDegraded
        )
        addRegion(region, page: nudge.pageIndex, undoManager: undoManager, actionName: UndoName.addNearbyMatch)
        regionMetadata[region.id] = metadata
        appliedMatchAudit[region.id] = audit
        pendingManualDrawNudge = nil
        return region
    }

    /// Set the per-search-session suppression flag. Called by the view
    /// layer after the toast is enqueued OR explicitly dismissed so a
    /// second qualifying manual-draw inside the same session does not
    /// re-spam the toast. Resets when the search session changes (the
    /// `activeSearch` didSet) or the document boundaries reset.
    func markManualDrawNudgeSuppressed() {
        manualDrawNudgeSuppressedForSession = true
        pendingManualDrawNudge = nil
    }

    /// Direct test hook — toggle the suppression flag without going
    /// through the `markManualDrawNudgeSuppressed` side effects. Lets
    /// `ManualDrawNudgeTests` flip the flag to true, then assert the
    /// three boundary resets clear it back to false.
    func setManualDrawNudgeSuppressedForTesting(_ value: Bool) {
        manualDrawNudgeSuppressedForSession = value
    }
}
