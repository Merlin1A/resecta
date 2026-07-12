import Foundation

// W5 — one row of the match audit log. Engine-owned so both CSV and JSON
// serializers emit the exact same field set. `matchedText` is either raw
// content or already-redacted depending on the caller's `includeSensitive`
// choice; the exporter applies redaction before constructing records so
// that the on-disk artifact never carries raw text when the user opts out.

public struct MatchAuditRecord: Codable, Sendable, Equatable {
    public let id: UUID
    public let pageIndex: Int
    public let matchedText: String
    /// Stringified `SearchSource` — `"textLayer"` or
    /// `"ocr(confidence=0.92)"`. Stable across versions.
    public let source: String
    /// `PIICategory.rawValue` when the row is a PII hit, nil otherwise
    /// (text/regex/multi-term results, and W3 always-flag synthetic hits).
    public let piiCategory: String?
    public let piiConfidence: Double?
    public let term: String
    public let ruleID: String?
    public let finalScore: Double?
    public let appliedThreshold: Double?
    /// Human-readable one-line summary of `rationale.signals`. Built via
    /// `MatchAuditExporter.rationaleSummary(_:)` so CSV + JSON stay aligned.
    public let rationaleSummary: String
    public let isSelected: Bool
    public let wasApplied: Bool
    /// W10 — true when the overlap resolver dropped this record in favor
    /// of a higher-confidence sibling. Phase 3b threads losers through the
    /// export boundary; for W10 this column is infrastructure and always
    /// false on surviving records.
    public let suppressedByOverlap: Bool
    /// W8 — FOIA exemption `shortCode` (e.g. `"(b)(6)"`, `"custom"`) set
    /// by the reviewer on the underlying region. Nil when untagged.
    public let foiaExemption: String?
    /// W8 — free-text statutory citation. Only populated when the
    /// underlying exemption is `.custom`; nil otherwise.
    public let foiaCitation: String?
    /// W8 — optional reviewer note captured alongside the exemption tag.
    public let foiaNote: String?
    /// W-I2 — A22 catalog `version` for the rule that fired (e.g. "1.0").
    /// Nil when the engine emits a ruleID without a catalog alias
    /// (synthetic `user.alwaysFlag`, fallback `pii.other`). Resolved via
    /// `RuleCatalog.shared.entry(forEngineRuleID:)`.
    public let ruleVersion: String?
    /// W-I2 — `version` field from `gazetteer-manifest.json` (e.g.
    /// "1.0.0"). Nil when the manifest is absent (test contexts) or
    /// when a decode error occurred (logged in `ExportMetadataLoader`).
    public let gazetteerManifestVersion: String?

    public init(
        id: UUID,
        pageIndex: Int,
        matchedText: String,
        source: String,
        piiCategory: String?,
        piiConfidence: Double?,
        term: String,
        ruleID: String?,
        finalScore: Double?,
        appliedThreshold: Double?,
        rationaleSummary: String,
        isSelected: Bool,
        wasApplied: Bool,
        suppressedByOverlap: Bool = false,
        foiaExemption: String? = nil,
        foiaCitation: String? = nil,
        foiaNote: String? = nil,
        ruleVersion: String? = nil,
        gazetteerManifestVersion: String? = nil
    ) {
        self.id = id
        self.pageIndex = pageIndex
        self.matchedText = matchedText
        self.source = source
        self.piiCategory = piiCategory
        self.piiConfidence = piiConfidence
        self.term = term
        self.ruleID = ruleID
        self.finalScore = finalScore
        self.appliedThreshold = appliedThreshold
        self.rationaleSummary = rationaleSummary
        self.isSelected = isSelected
        self.wasApplied = wasApplied
        self.suppressedByOverlap = suppressedByOverlap
        self.foiaExemption = foiaExemption
        self.foiaCitation = foiaCitation
        self.foiaNote = foiaNote
        self.ruleVersion = ruleVersion
        self.gazetteerManifestVersion = gazetteerManifestVersion
    }
}
