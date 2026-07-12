import Foundation

// W-I2 — A22 (`Resources/Audit/rule-catalog.json`) loader + engine-rule-id
// translation layer (path-(a) per Q1 / 2026-04-30 DECIDED).
//
// The catalog ships 19 entries with `rule_id` in `pii.<X>.[<sub>.]v1` form;
// the engine emits ruleIDs in `<family>.<sub>` form (e.g.,
// `ssn.state-machine`, `cc.luhn`). The hand-curated alias map below
// translates engine ruleIDs into catalog `rule_id` values so that
// audit-export records can pin a catalog `version` + `source_artifact`
// without renaming either side.
//
// Q1 (2026-04-30, Jesse): path (a) is the binding V1 choice. Paths (b)
// and (c) are recorded in STRAT §5.2 stop-conditions as historical
// alternatives. The alias map below is the V1 surface; V1.1+ may move
// it to a paired schema field on rule_catalog.schema.json.
//
// Schema: `~/resecta-datapipeline/schemas/rule_catalog.schema.json`.

public struct RuleCatalog: Sendable {

    public enum LoaderError: Error {
        case resourceMissing
        case decodingFailed(underlying: Error)
        case unsupportedVersion(actual: Int, supported: ClosedRange<Int>)
    }

    public struct Entry: Sendable, Equatable, Codable {
        public let detector: String
        public let family: String
        public let isChecksumGated: Bool
        public let ruleID: String
        public let sourceArtifact: String?
        public let version: String

        enum CodingKeys: String, CodingKey {
            case detector, family, version
            case isChecksumGated = "is_checksum_gated"
            case ruleID = "rule_id"
            case sourceArtifact = "source_artifact"
        }
    }

    public static let supportedVersions: ClosedRange<Int> = 1...1

    /// Engine-ruleID → catalog rule_id. V1 alias map (Q1 path-(a) DECIDED).
    /// Update alongside any new engine-ruleID emission. Coverage is
    /// guarded at build time by `RuleCatalogTests.everyEmittedRuleIDIsAliased`.
    ///
    /// RHS values are aligned to the live catalog rule_id strings shipped
    /// in `Resources/Audit/rule-catalog.json` (A22 wire-locked at ship per
    /// audit §B.1 row 5).
    private static let engineToCatalog: [String: String] = [
        // SSN — two engine emissions collapse onto one catalog entry.
        "ssn.state-machine":    "pii.ssn.state_machine.v1",
        "ssn.regex":            "pii.ssn.state_machine.v1",
        // Credit card.
        "cc.luhn":              "pii.cc.luhn.v1",
        // DEA.
        "dea.letter-check":     "pii.dea.checksum.v1",
        // NPI — catalog entry name is `pii.npi.luhn.v1` (verified live).
        "npi.80840":            "pii.npi.luhn.v1",
        // Name (NLTagger).
        "name.nltagger":        "pii.name.nltagger.v1",
        // License plate.
        "licensePlate.labeled": "pii.lp.v1",
        // MRN — three sub-rules + regex fallback path.
        "mrn.labeled":          "pii.mrn.labeled.v1",
        "mrn.patientID":        "pii.mrn.patient_id.v1",
        "mrn.institution":      "pii.mrn.institution.v1",
        "mrn.regex":            "pii.mrn.labeled.v1",
        // Account.
        "account.regex":        "pii.account.v1",
        // Routing number — emitted by
        // RoutingNumberDetector and defaultRuleID(for: .routingNumber).
        "routingNumber.aba-checksum": "pii.routing_number.v1",
        // Barcode / signature — defaultRuleID(for: .barcode /
        // .signatureCandidate) arms; aliases bundled with the
        // 21-row catalog.
        "barcode.vision":       "pii.barcode.vision.v1",
        "signature.heuristic":  "pii.signature.heuristic.v1",
        // Per-kind regex defaults from `defaultRuleID(for:)` in PIIDetector.
        // Each maps to its family's catalog entry.
        "phone.regex":          "pii.phone.v1",
        "email.regex":          "pii.email.v1",
        "ein.regex":            "pii.ein.v1",
        "itin.regex":           "pii.itin.v1",
        // The ContextWindowScorer migration's rationale ruleID —
        // same ITIN rule family (SSN-style fold).
        "itin.yy-bucket":       "pii.itin.v1",
        "dob.regex":            "pii.dob.v1",
        "passport.regex":       "pii.passport.v1",
        "dl.regex":             "pii.dl.v1",
        "address.regex":        "pii.address.v1",
        // Synthetic / catch-all — `user.alwaysFlag` and `pii.other` stay
        // un-translated. `entry(forEngineRuleID:)` returns nil for these,
        // so audit-export records get nil `ruleVersion` / `sourceArtifact`
        // (intentional — nothing in the catalog carries provenance for them).
    ]

    public static var knownEngineRuleIDs: Set<String> {
        Set(engineToCatalog.keys)
    }

    private let byCatalogRuleID: [String: Entry]
    public let entries: [Entry]

    public static let shared: RuleCatalog? = try? RuleCatalog()

    public init() throws { try self.init(bundle: .module) }

    init(bundle: Bundle) throws {
        guard let url = bundle.url(
            forResource: "rule-catalog",
            withExtension: "json",
            subdirectory: "Audit"
        ) else { throw LoaderError.resourceMissing }

        let wire: WireFormat
        do {
            let bytes = try Data(contentsOf: url)
            wire = try JSONDecoder().decode(WireFormat.self, from: bytes)
        } catch {
            throw LoaderError.decodingFailed(underlying: error)
        }
        guard Self.supportedVersions.contains(wire.version) else {
            throw LoaderError.unsupportedVersion(
                actual: wire.version, supported: Self.supportedVersions
            )
        }

        self.entries = wire.entries
        self.byCatalogRuleID = Dictionary(
            uniqueKeysWithValues: wire.entries.map { ($0.ruleID, $0) }
        )
    }

    /// Look up a catalog entry by engine-side ruleID. Translates through
    /// the alias map; returns nil for ruleIDs without a catalog mapping
    /// (synthetic ruleIDs `user.alwaysFlag`, fallback `pii.other`).
    public func entry(forEngineRuleID engineRuleID: String) -> Entry? {
        guard let catalogRuleID = Self.engineToCatalog[engineRuleID] else {
            return nil
        }
        return byCatalogRuleID[catalogRuleID]
    }

    /// Direct catalog-rule_id lookup (callers that already speak A22's
    /// vocabulary).
    public func entry(forCatalogRuleID ruleID: String) -> Entry? {
        byCatalogRuleID[ruleID]
    }
}

private struct WireFormat: Decodable {
    let version: Int
    let generatedBy: String
    let seed: Int
    let entries: [RuleCatalog.Entry]
    enum CodingKeys: String, CodingKey {
        case version, seed, entries
        case generatedBy = "generated_by"
    }
}
