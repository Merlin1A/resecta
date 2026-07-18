import Foundation
import RedactionEngine

// W5 — captured at apply time so the `MatchRationale`, `piiCategory`,
// and source context survive even after the Search sheet closes and
// `SearchState.results` is cleared. Keyed into
// `RedactionState.appliedMatchAudit` by the RedactionRegion UUID; undo /
// redo tracks these snapshots alongside the regions they belong to.
//
// The one apply path writes a snapshot for BOTH result origins — the
// search side and the detection (scan) side — so no applied region is
// audit-less. Fields the scan origin does not record are optional and
// stay nil rather than carrying invented values: a detection has no
// query term, no `MatchRationale`, and no per-word OCR confidence.
// `origin` names which side produced the record. In-memory model only —
// the export artifact schema is unchanged (v4), and export surfaces
// stay compiled off for 1.0.
//
// Scope: per-document-open session. `RedactionState.clearAll()` wipes
// the dict, so audit never leaks across documents.

// nonisolated: a pure Sendable value type constructed off MainActor
// inside `prepareApply` and carried back in the Sendable
// `PreparedApply`. Its explicit inits would otherwise become
// MainActor-isolated under the s04 SE-0466 MainActor-default flip,
// breaking the detached apply-prepare path; pin the type nonisolated
// (mirrors RegionMetadata).
nonisolated struct MatchAuditSnapshot: Sendable, Equatable {
    /// Which apply origin produced this record.
    enum Origin: Sendable, Equatable {
        /// Applied from the search/scan-run result list (`SearchResult`).
        case search
        /// Applied from staged pipeline detections (`DetectionResult`).
        case scan
    }

    let origin: Origin
    let resultID: UUID
    /// The created region's UUID — populated for BOTH origins, so the
    /// audit model stays join-ready against `regionMetadata` and the
    /// region list while export surfaces remain dark.
    let regionID: UUID
    let pageIndex: Int
    /// Nil only for scan-origin records whose detection carries no text
    /// (e.g. a face). Search-origin records always populate it.
    let matchedText: String?
    /// Search-origin records carry the engine's source verbatim. Scan-
    /// origin records populate `.textLayer` only when the detection's
    /// provenance recorded that the embedded text layer produced it;
    /// when OCR ran, the per-word OCR confidence was not retained at
    /// this granularity, so the field stays nil rather than repurposing
    /// the detection confidence as an OCR confidence.
    let source: SearchSource?
    let piiCategory: PIICategory?
    let piiConfidence: Double?
    /// Nil for scan-origin records — `DetectionResult` carries no
    /// `MatchRationale` (verified; the rationale surfaces render
    /// per-origin accessories instead).
    let rationale: MatchRationale?
    /// The user's query term. Nil for scan-origin records — a detection
    /// run has no typed query.
    let term: String?
    let appliedAt: Date

    /// Scan-origin builder: the truthful subset a `DetectionResult`
    /// records, with `regionID` populated like every snapshot.
    init(
        detection: DetectionResult,
        pageIndex: Int,
        regionID: UUID,
        appliedAt: Date
    ) {
        self.origin = .scan
        self.resultID = detection.id
        self.regionID = regionID
        self.pageIndex = pageIndex
        self.matchedText = detection.matchedText
        self.source = detection.provenance.ocrSkipped ? .textLayer : nil
        let category: PIICategory? = {
            if case .pii(let kind) = detection.kind {
                return PIICategory(piiKind: kind)
            }
            return nil
        }()
        self.piiCategory = category
        // Paired with `piiCategory` like every other producer of the
        // field: a non-PII detection's confidence (e.g. a face
        // detector's) is not a PII confidence, so it stays out of the
        // PII-specific field. The raw confidence still travels on the
        // region's `RegionMetadata`, keyed by the same region id.
        self.piiConfidence = category != nil ? detection.confidence : nil
        self.rationale = nil
        self.term = nil
        self.appliedAt = appliedAt
    }

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
        appliedAt: Date
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
    }
}
