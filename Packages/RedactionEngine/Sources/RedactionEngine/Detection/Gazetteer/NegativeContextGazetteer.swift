import Foundation
import OSLog

// Plan A6 / G4 — per-category, per-doctype negative-context keyword gazetteer.
// Schema at DataPipeline/schemas/negative_context.schema.json. Entries have
// four fields: keyword, category_scope, doctype_scope, precedence_weight
// (floor 0.25 per A1 — context alone never fully suppresses a structurally
// valid match).
//
// Integration: composed as a complementary source on top of the existing
// hardcoded `SSNContextKeywords.profile` in ContextWindowScorer. Missing JSON
// → `suppressionScore` returns 1.0 (no suppression) for every query.

public struct NegativeContextGazetteer: Sendable {

    /// Keyed by (category_scope, doctype_scope) → per-keyword weight list.
    /// Weight order mirrors `keywords` order so a single scan produces both
    /// the match verdict and the associated weight without a secondary lookup.
    struct ScopedEntries: Sendable {
        let keywords: [String]
        let weights: [Double]
        /// Bucket-level maximum — retained for the index builder; NOT used in
        /// suppression scoring (the per-matched-keyword semantics fix, S3).
        let maxPrecedenceWeight: Double
    }

    public enum LoaderError: Error {
        case resourceMissing
        case decodingFailed(underlying: Error)
        case unsupportedVersion(actual: Int, supported: ClosedRange<Int>)
    }

    private static let supportedVersions: ClosedRange<Int> = 1...1

    private let byScope: [ScopeKey: ScopedEntries]
    private let isEmpty: Bool
    private let institutions: InstitutionGazetteer?

    struct ScopeKey: Hashable, Sendable {
        let category: String     // "ssn" | "npi" | "dea" | "name" | "address" | "dob"
        let doctype: String      // "court" | "medical" | "financial" | "foia" | "generic"
    }

    public init() throws {
        try self.init(bundle: .module, institutions: try? InstitutionGazetteer())
    }

    /// Testing init — inject a custom bundle and (optionally) a pre-built
    /// institution gazetteer. Passing `nil` for `institutions` leaves the
    /// L4 anchor paths inert, which is the right default for unit tests
    /// that aren't exercising the anchor.
    init(bundle: Bundle, institutions: InstitutionGazetteer? = nil) throws {
        self.byScope = try Self.load(from: bundle)
        self.isEmpty = byScope.isEmpty
        self.institutions = institutions
    }

    // MARK: - Suppression lookup

    /// Returns a multiplicative suppression factor in [0.25, 1.0].
    /// `1.0` = no suppression (keyword absent or gazetteer unavailable);
    /// `0.25` = maximum suppression (precedence-weight floor per A1).
    ///
    /// The scorer applies: `adjusted = base * suppressionScore(...)`, then
    /// floors at category-specific confidence floor (SSN: 0.25).
    public func suppressionScore(
        category: PIICategory,
        doctype: DoctypeClass,
        context: String
    ) -> Double {
        guard !isEmpty,
              let wire = Self.wireName(for: category) else {
            return 1.0
        }
        let key = ScopeKey(category: wire, doctype: doctype.rawValue)
        guard let entry = byScope[key] else { return 1.0 }
        let lowered = context.lowercased()
        // Per-matched-keyword semantics (S3 semantics fix, design §1):
        // collect the weights of every keyword actually found in the context
        // window and use the MAX matched weight — not the bucket max.
        // Rationale: the bucket max was precomputed at index time and made
        // every keyword in a bucket suppress at the strongest member's weight,
        // rendering per-keyword weight values decorative.
        var maxMatchedWeight: Double? = nil
        for (kw, weight) in zip(entry.keywords, entry.weights) where lowered.contains(kw) {
            maxMatchedWeight = max(maxMatchedWeight ?? 0.0, weight)
        }
        guard let matched = maxMatchedWeight else { return 1.0 }
        // Formula: factor = max(0.25, 1.0 - matchedWeight * 0.75)
        // At weight=0.25 → factor 0.8125 (light tap); weight=1.0 → factor 0.25 (floor).
        return max(0.25, 1.0 - matched * 0.75)
    }

    /// Internal variant that returns the suppression factor alongside the
    /// matched keyword and its weight, for attaching a `MatchRationale.Signal`
    /// in `ContextWindowScorer`. When no keyword matches, `keyword` and
    /// `weight` are nil (factor == 1.0). Internal — not part of the public API.
    func suppressionDetail(
        category: PIICategory,
        doctype: DoctypeClass,
        context: String
    ) -> (factor: Double, keyword: String?, weight: Double?) {
        guard !isEmpty,
              let wire = Self.wireName(for: category) else {
            return (1.0, nil, nil)
        }
        let key = ScopeKey(category: wire, doctype: doctype.rawValue)
        guard let entry = byScope[key] else { return (1.0, nil, nil) }
        let lowered = context.lowercased()
        var maxMatchedWeight: Double? = nil
        var maxMatchedKeyword: String? = nil
        for (kw, weight) in zip(entry.keywords, entry.weights) where lowered.contains(kw) {
            if weight > (maxMatchedWeight ?? -1.0) {
                maxMatchedWeight = weight
                maxMatchedKeyword = kw
            }
        }
        guard let matched = maxMatchedWeight, let keyword = maxMatchedKeyword else {
            return (1.0, nil, nil)
        }
        return (max(0.25, 1.0 - matched * 0.75), keyword, matched)
    }

    // MARK: - L4 institution anchoring

    /// Overload of `suppressionScore(...)` that additionally consults the
    /// document header for a known institution (via `InstitutionGazetteer`).
    ///
    /// Two anchor classes apply an extra 0.6 multiplier on top of the
    /// keyword-based suppression:
    ///
    /// - `.foia` anchor (``federal_agency``): suppresses `.ssn`, `.npi`, and
    ///   `.name` — federal-agency correspondence is a canonical false-positive
    ///   surface for body-text name and SSN/NPI matches.
    ///
    /// - `.financial` anchor (``financial_institution``, ``employer``): same
    ///   three categories — bank statement and W-2 / pay-stub headers are the
    ///   primary false-positive surface for financial documents.
    ///
    /// The `.npi` case is a low-priority edge for financial documents (NPI
    /// rarely appears there) but is included for consistency. The final factor
    /// is floored at 0.25 to preserve the A1 invariant.
    public func suppressionScore(
        category: PIICategory,
        doctype: DoctypeClass,
        context: String,
        documentHeader: String
    ) -> Double {
        let base = suppressionScore(
            category: category, doctype: doctype, context: context)

        guard let institutions,
              let entry = institutions.findInstitution(in: documentHeader),
              InstitutionGazetteer.anchoredDoctype(for: entry) == .foia
                || InstitutionGazetteer.anchoredDoctype(for: entry) == .financial,
              category == .ssn || category == .npi || category == .name
        else {
            return base
        }

        // Extra 0.6 multiplier = up to 40% additional suppression on top of
        // whatever keyword context has already applied. Paired with the 0.25
        // floor so the detector can still fire on a structurally valid match.
        return max(0.25, base * 0.6)
    }

    /// Forward-feedback hint for `DocumentTypeClassifier`: scan the document
    /// header for any known institution and return the doctype class that
    /// institution anchors. Today `federal_agency` → `.foia`; other
    /// categories return `nil` until their mapping is authorized.
    public func anchoredDoctype(documentHeader: String) -> DoctypeClass? {
        guard let institutions,
              let entry = institutions.findInstitution(in: documentHeader)
        else { return nil }
        return InstitutionGazetteer.anchoredDoctype(for: entry)
    }

    // MARK: - Wire name mapping

    /// The schema constrains category_scope to {ssn, npi, dea, name, address, dob}.
    /// Map PIICategory to these wire names; categories with no mapping
    /// (email/phone/CC/EIN/ITIN/DL/passport/MRN) always return nil →
    /// suppression factor 1.0.
    static func wireName(for category: PIICategory) -> String? {
        switch category {
        case .ssn:            "ssn"
        case .name:           "name"
        case .address:        "address"
        case .dateOfBirth:    "dob"
        case .npi:            "npi"
        case .dea:            "dea"
        case .account:        "account"
        case .routingNumber:  "routingNumber"
        case .creditCard, .email, .phone, .ein, .itin,
             .driversLicense, .passport, .medicalRecord,
             .licensePlate:
            nil
        }
    }

    // MARK: - Loader

    private static func load(from bundle: Bundle) throws -> [ScopeKey: ScopedEntries] {
        guard let url = bundle.url(
            forResource: "negative-context",
            withExtension: "json",
            subdirectory: "Gazetteers"
        ) else {
            logger.info("negative-context.json not bundled; suppression inert")
            throw LoaderError.resourceMissing
        }
        do {
            let bytes = try Foundation.Data(contentsOf: url)
            let wire = try JSONDecoder().decode(WireFormat.self, from: bytes)
            try LoaderVersionFence.assert(
                actual: wire.version,
                supported: Self.supportedVersions,
                assetName: "negative-context",
                logger: logger,
                throwing: { LoaderError.unsupportedVersion(actual: $0, supported: $1) }
            )
            return wire.indexed()
        } catch let error as LoaderError {
            throw error
        } catch {
            logger.warning("negative-context.json decode failed: \(String(describing: error), privacy: .public)")
            throw LoaderError.decodingFailed(underlying: error)
        }
    }
}

// MARK: - Wire format

private struct WireFormat: Decodable {
    let version: Int
    let entries: [Entry]

    struct Entry: Decodable {
        let keyword: String
        let category_scope: String
        let doctype_scope: String
        let precedence_weight: Double
    }

    func indexed() -> [NegativeContextGazetteer.ScopeKey: NegativeContextGazetteer.ScopedEntries] {
        var grouped: [NegativeContextGazetteer.ScopeKey: [Entry]] = [:]
        for entry in entries {
            let key = NegativeContextGazetteer.ScopeKey(
                category: entry.category_scope,
                doctype: entry.doctype_scope
            )
            grouped[key, default: []].append(entry)
        }
        return grouped.mapValues { bucket in
            let keywords = bucket.map { $0.keyword.lowercased() }
            let weights = bucket.map { $0.precedence_weight }
            let maxWeight = weights.max() ?? 0.25
            return NegativeContextGazetteer.ScopedEntries(
                keywords: keywords,
                weights: weights,
                maxPrecedenceWeight: maxWeight
            )
        }
    }
}

private let logger = Logger(subsystem: "app.resecta.engine", category: "NegativeContextGazetteer")
