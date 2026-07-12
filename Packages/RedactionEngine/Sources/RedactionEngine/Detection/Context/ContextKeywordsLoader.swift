import Foundation

// W-N — A21 (`Resources/Gazetteers/context-keywords.json`) loader.
// Replaces the positive-keyword arrays in the four hardcoded
// `*ContextKeywords.swift` files. Schema:
// `~/resecta-datapipeline/schemas/context_keywords.schema.json` v1.
//
// V1 scope (per STRAT §1.5 row 14 / Q3 DECIDED 2026-04-30): positive-only
// lift. The 4 retired Swift files KEEP their `negativeKeywords:` arrays +
// threshold constants engine-side; only `positiveKeywords:` becomes
// loader-driven. Full file retirement is V1.1+ once A5 absorbs the label-
// style negatives via the §2.2 hand-review path.
//
// `confidence` enum (`high / medium-high / medium / medium (flag) / low`)
// is preserved on the entry struct but NOT consumed at scoring time — the
// existing scorer's `hasPositive` check (`ContextWindowScorer.score:97`)
// is binary contains over `Set<String>`. The `weight(for:)` helper below
// maps the enum to numeric values for V1.1+ soft-gating; no production
// caller in V1.
//
// Loader-version fence aligned with W-O policy
// (`FORMAT_CONTRACTS.md §12`). Bump `supportedVersions` when the A21
// shape changes in a way the Swift decoder must observe.

public struct ContextKeywordsLoader: Sendable {

    public enum LoaderError: Error {
        case resourceMissing
        case decodingFailed(underlying: Error)
        case unsupportedVersion(actual: Int, supported: ClosedRange<Int>)
    }

    public struct Entry: Sendable, Equatable, Codable {
        public let term: String
        public let category: String           // raw from A21 enum
        public let polarity: String           // const "positive"
        public let locale: String             // const "en"
        public let doctypes: [String]         // empty = global
        public let confidence: String
        public let detectorNote: String?
        public let detectorRequiresSecondary: Bool?

        enum CodingKeys: String, CodingKey {
            case term, category, polarity, locale, doctypes, confidence
            case detectorNote = "detector_note"
            case detectorRequiresSecondary = "detector_requires_secondary"
        }
    }

    /// Aligned with W-O loader-version-fence policy
    /// (`FORMAT_CONTRACTS.md §12`). Bump when A21 shape changes.
    public static let supportedVersions: ClosedRange<Int> = 1...1

    private let entriesByCategory: [PIICategory: [Entry]]

    public init() throws { try self.init(bundle: .module) }

    /// Testing / composition init — inject a custom bundle.
    init(bundle: Bundle) throws {
        guard let url = bundle.url(
            forResource: "context-keywords",
            withExtension: "json",
            subdirectory: "Gazetteers"
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

        var grouped: [PIICategory: [Entry]] = [:]
        for entry in wire.entries {
            guard let category = Self.mapCategory(entry.category) else {
                continue   // schema gates the enum; defensive
            }
            grouped[category, default: []].append(entry)
        }
        self.entriesByCategory = grouped
    }

    /// Returns the lowercased positive-keyword set for `(category, doctype)`.
    /// `doctype: nil` returns ONLY the global-scoped entries
    /// (`doctypes == []`); pass a concrete doctype to layer the
    /// doctype-scoped entries on top of the globals. Returns nil if no
    /// entries match — caller falls back to the engine-side const so the
    /// scorer keeps working in test contexts that don't ship A21.
    public func positiveKeywords(
        for category: PIICategory,
        doctype: DoctypeClass?
    ) -> Set<String>? {
        guard let entries = entriesByCategory[category], !entries.isEmpty else {
            return nil
        }
        let filtered: [Entry]
        if let doctype {
            filtered = entries.filter {
                $0.doctypes.isEmpty || $0.doctypes.contains(doctype.rawValue)
            }
        } else {
            filtered = entries.filter { $0.doctypes.isEmpty }
        }
        guard !filtered.isEmpty else { return nil }
        return Set(filtered.map { $0.term.lowercased() })
    }

    /// Numeric weight per `confidence` enum. **V1.1+ helper** — the V1
    /// scorer ignores it; reserved for future soft-gating. The F-50/F-51
    /// disposition keeps the five-case enum intact (don't coerce to numeric
    /// per STRAT §5.1 stop-condition); the values below are illustrative
    /// scaffolding only.
    public static func weight(for confidence: String) -> Double {
        switch confidence {
        case "high":           return 1.0
        case "medium-high":    return 0.85
        case "medium":         return 0.7
        case "medium (flag)":  return 0.55
        case "low":            return 0.4
        default:               return 0.7   // schema-gated; defensive
        }
    }

    /// Raw entries for a category — exposed for tests and audit tooling.
    public func entries(for category: PIICategory) -> [Entry] {
        entriesByCategory[category] ?? []
    }

    private static func mapCategory(_ raw: String) -> PIICategory? {
        switch raw {
        case "ssn":          return .ssn
        case "mrn":          return .medicalRecord
        case "licenseplate": return .licensePlate
        case "dea":          return .dea
        case "dob":          return .dateOfBirth
        case "itin":         return .itin
        case "name":         return .name
        case "npi":          return .npi
        // S3 §2.6: EIN context-keyword category infrastructure. Paired with
        // pipeline schema enum addition (schemas/context_keywords.schema.json).
        // smokeFullEntries count stays at 176 until the pipeline PR ships the
        // 6 EIN rows (+ 5 ssn + 5 name additions) — the count gate is in the
        // pipeline PR and is NOT updated here.
        case "ein":          return .ein
        default:             return nil
        }
    }

    /// Test seam: source-target bundle accessor. The W-N parity test
    /// ("axis 2 overlap cap") needs to read A5 (`negative-context.json`)
    /// — which lives in the same `Resources/Gazetteers/` directory as
    /// A21 — to count how many SSN-scoped negatives in A5 overlap the
    /// `SSNContextKeywords.profile.negativeKeywords` constant. The test
    /// target's own `Bundle.module` doesn't carry source resources, so
    /// we expose this `internal` accessor for `@testable` callers. Not a
    /// production API.
    internal static let _resourceBundleForTesting: Bundle = .module
}

private struct WireFormat: Decodable {
    let version: Int
    let generatedBy: String
    let seed: Int
    let entries: [ContextKeywordsLoader.Entry]
    enum CodingKeys: String, CodingKey {
        case version, seed, entries
        case generatedBy = "generated_by"
    }
}
