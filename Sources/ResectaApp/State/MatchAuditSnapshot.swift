import Foundation
import RedactionEngine

// Captured at apply time so the `MatchRationale`, `piiCategory`,
// and source context survive even after the Search sheet closes and
// `SearchState.results` is cleared. Keyed into
// `RedactionState.appliedMatchAudit` by the RedactionRegion UUID; undo /
// redo tracks these snapshots alongside the regions they belong to.
//
// The one apply path writes a snapshot for every applied result, so no
// applied region is audit-less. In-memory model only —
// the export artifact schema is unchanged (v4), and export surfaces
// stay compiled off for 1.0.
//
// Scope: per-document-open session. `RedactionState.clearAll()` wipes
// the dict, so audit never leaks across documents.

// nonisolated: a pure Sendable value type constructed off MainActor
// inside `prepareApply` and carried back in the Sendable
// `PreparedApply`. Its explicit inits would otherwise become
// MainActor-isolated under the SE-0466 MainActor-default flip,
// breaking the detached apply-prepare path; pin the type nonisolated
// (mirrors RegionMetadata).
nonisolated struct MatchAuditSnapshot: Sendable, Equatable {
    /// Which apply origin produced this record.
    enum Origin: Sendable, Equatable {
        /// Applied from the search/scan-run result list (`SearchResult`).
        case search
    }

    let origin: Origin
    let resultID: UUID
    /// The created region's UUID — populated on every record, so the
    /// audit model stays join-ready against `regionMetadata` and the
    /// region list while export surfaces remain dark.
    let regionID: UUID
    let pageIndex: Int
    /// Search-origin records always populate it.
    let matchedText: String?
    /// Search-origin records carry the engine's source verbatim.
    let source: SearchSource?
    let piiCategory: PIICategory?
    let piiConfidence: Double?
    let rationale: MatchRationale?
    /// The user's query term.
    let term: String?
    let appliedAt: Date
    /// The applied-search record of the search session this snapshot
    /// was applied from — typed-search origin only. Nil for `.piiScan`
    /// sessions and for nudge-accepted regions.
    /// Read at run entry by the coordinator's present-region join
    /// (`PipelineCoordinator.appliedSearches(fromRegions:audit:)`) to
    /// build the Search Re-check requests. The display texts inside are
    /// never logged or persisted; the export surfaces do not read it.
    let searchRecord: AppliedSearchRecord?
    /// The applied box is the widened envelope, not the word's ink
    /// (`SearchResult.inkFitDegraded`): the page keeps its notice.
    let inkFitDegraded: Bool

    /// Search-origin memberwise shape (field-for-field what
    /// `prepareApply` always recorded).
    init(
        origin: Origin,
        resultID: UUID,
        regionID: UUID,
        pageIndex: Int,
        matchedText: String?,
        source: SearchSource?,
        piiCategory: PIICategory?,
        piiConfidence: Double?,
        rationale: MatchRationale?,
        term: String?,
        appliedAt: Date,
        searchRecord: AppliedSearchRecord? = nil,
        inkFitDegraded: Bool = false
    ) {
        self.origin = origin
        self.resultID = resultID
        self.regionID = regionID
        self.pageIndex = pageIndex
        self.matchedText = matchedText
        self.source = source
        self.piiCategory = piiCategory
        self.piiConfidence = piiConfidence
        self.rationale = rationale
        self.term = term
        self.appliedAt = appliedAt
        self.searchRecord = searchRecord
        self.inkFitDegraded = inkFitDegraded
    }
}
