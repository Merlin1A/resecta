import Foundation

// Envelope metadata that accompanies the record list. Captures the
// scan context so a reviewer reading the audit log months later knows
// which preset + overrides were in effect.
//
// Schema versions:
//   1 — original column set.
//   2 — adds the `suppressedByOverlap` trailing column to both CSV
//       and JSON records. Readers that address columns by name
//       remain compatible; readers that address by index should
//       switch to name-addressing before schema v3.
//   3 — adds the trailing `foiaExemption` / `foiaCitation` /
//       `foiaNote` columns for per-region statutory exemption
//       coding. Additive; header-name-addressed readers stay
//       compatible with v1 and v2 files.
//   4 — adds `ruleVersion` + `gazetteerManifestVersion` (positioned
//       after `ruleID`, before `finalScore`). Both `String?`;
//       older payloads decode cleanly via Swift's synthesized
//       `init(from:)` (Optional defaults to nil). Header-name-
//       addressed readers stay compatible with v1..v3 files. This is
//       the second audit-export schema break; the wire integer is 4
//       because schemaVersion=3 already shipped for the FOIA-tag
//       fields.

public struct ExportMetadata: Codable, Sendable, Equatable {
    public let schemaVersion: UInt8
    public let exportedAt: Date
    public let appVersion: String
    public let presetName: String
    /// Map of `PIICategory.rawValue` to the user's per-category threshold
    /// override. Empty when the user is on defaults.
    public let perCategoryOverrides: [String: Double]
    public let documentName: String
    public let totalMatches: Int
    public let appliedMatches: Int

    public init(
        schemaVersion: UInt8 = 4,
        exportedAt: Date = Date(),
        appVersion: String,
        presetName: String,
        perCategoryOverrides: [String: Double],
        documentName: String,
        totalMatches: Int,
        appliedMatches: Int
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.presetName = presetName
        self.perCategoryOverrides = perCategoryOverrides
        self.documentName = documentName
        self.totalMatches = totalMatches
        self.appliedMatches = appliedMatches
    }
}
