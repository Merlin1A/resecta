import Foundation
import RedactionEngine

// W5 — captured at `applySearchResults` time so the `MatchRationale`,
// `piiCategory`, and source context survive even after the Search sheet
// closes and `SearchState.results` is cleared. Keyed into
// `RedactionState.appliedMatchAudit` by the RedactionRegion UUID; undo /
// redo tracks these snapshots alongside the regions they belong to.
//
// Scope: per-document-open session. `RedactionState.clearAll()` wipes
// the dict, so audit never leaks across documents.

struct MatchAuditSnapshot: Sendable, Equatable {
    let resultID: UUID
    let regionID: UUID
    let pageIndex: Int
    let matchedText: String
    let source: SearchSource
    let piiCategory: PIICategory?
    let piiConfidence: Double?
    let rationale: MatchRationale?
    let term: String
    let appliedAt: Date
}
