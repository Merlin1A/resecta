import Foundation
import OSLog

// Passport-pattern gazetteer. Loads `passport_patterns.json`
// produced by DataPipeline's src/resecta_data/gazetteers/passport_patterns/
// (DP commit 5b19a84, 2026-04-26). 11 issuers = CA/CN/DO/GB/IN/KR/MX/PH/SV/US/VN.
//
// Spec authority: the DataPipeline data-requirements spec §1.16.
//   Substrate substituted to ICAO Doc 9303 Ed. 8 (2021) Part 4 §4.7
//   per Disposition §4 cite-swap (treaty-PD-equivalent fact-extraction
//   per legal-ref §9.4.12 + §10.4; verbatim ICAO expression categorically
//   excluded per §10.5). F-38 GB pending_decision_memo is a V1-MOOT
//   metadata carrier — not consumed at detection time.
// Schema: ../resecta-datapipeline/schemas/passport_patterns.schema.json
//
// Layered onto the existing inline labeled-prefix detector at
// PIIDetector.detectPassports; this gazetteer supplies per-issuer
// validation patterns (W1 strategy: candidate from inline regex must
// match at least one issuer's pattern, otherwise it is suppressed).
//
// `recent_format_changes` rows (6 of 11: CA/CN/KR/MX/PH/US) keep the
// legacy arm in active circulation under 10-year passport validity.
// The row's `patterns` field already covers both arms via alternation;
// each variant's `legacy_pattern` is compiled alongside as defense-in-
// depth (analogous to DLPatternGazetteer's historical_variants handling).
//
// `@unchecked Sendable`: the struct stores `[NSRegularExpression]` per
// issuer. NSRegularExpression is not formally `Sendable` in Swift 6
// (NSObject-bridged) but Apple's documentation declares it thread-safe
// once initialised; the regexes are loaded once and never mutated.

public struct PassportPatternGazetteer: @unchecked Sendable {

    public enum LoaderError: Error {
        case resourceMissing
        case decodingFailed(underlying: Error)
        case schemaInvariantViolation(String)
        case unsupportedVersion(actual: Int, supported: ClosedRange<Int>)
    }

    private static let supportedVersions: ClosedRange<Int> = 1...1

    /// Engineer-facing audit metadata for an issuer row. Not consumed at
    /// detection time — surfaced so review tooling can inspect per-row
    /// license posture, confidence, recent-format-changes context, and
    /// any pending decision memo (GB only — F-38 V1-MOOT carrier).
    public struct IssuerMetadata: Sendable {
        public let licensePosture: String
        public let licenseNotes: String
        public let confidence: String
        public let checkDigitPolicy: String
        public let recentFormatChanges: [RecentFormatChange]
        public let pendingDecisionMemo: PendingDecisionMemo?
        public let ceilingRationale: String?
        public let postV1Task: String?
        public let postV1Tasks: [String]?
    }

    public struct RecentFormatChange: Sendable {
        public let transitionDate: String
        public let legacyPattern: String
        public let currentPattern: String
        public let coexistenceWindowNotes: String
    }

    public struct PendingDecisionMemo: Sendable {
        public let fItem: String
        public let groundingFacts: [String]
        public let options: [String]
        public let precedents: [String]
        public let defaultRecommendation: String
        public let rationale: String
    }

    /// Closed enum of the 11 V1 shipping issuer codes. Mirrors the
    /// `issuer_code` enum in passport_patterns.schema.json. Cuba (CU) is
    /// candidates-file-only per F-37 OFAC sanctions posture; Guatemala
    /// (GT) is V1.1+ swap candidate per W-R-4.1.
    private static let validIssuerCodes: Set<String> = [
        "CA", "CN", "DO", "GB", "IN", "KR", "MX", "PH", "SV", "US", "VN",
    ]

    private let patternsByIssuer: [String: [NSRegularExpression]]
    private let metadataByIssuer: [String: IssuerMetadata]

    // MARK: - Init

    /// Load from the module bundle.
    public init() throws {
        try self.init(bundle: .module)
    }

    /// Testing / composition init — inject a custom bundle.
    init(bundle: Bundle) throws {
        guard let url = bundle.url(
            forResource: "passport_patterns",
            withExtension: "json",
            subdirectory: "Gazetteers"
        ) else {
            logger.info("passport_patterns.json not bundled; passport pattern gazetteer inert")
            throw LoaderError.resourceMissing
        }

        let wire: WireFormat
        do {
            let bytes = try Data(contentsOf: url)
            wire = try JSONDecoder().decode(WireFormat.self, from: bytes)
        } catch {
            logger.warning("passport_patterns.json decode failed: \(String(describing: error), privacy: .public)")
            throw LoaderError.decodingFailed(underlying: error)
        }

        try LoaderVersionFence.assert(
            actual: wire.version,
            supported: Self.supportedVersions,
            assetName: "passport_patterns",
            logger: logger,
            throwing: { LoaderError.unsupportedVersion(actual: $0, supported: $1) }
        )

        var patterns: [String: [NSRegularExpression]] = [:]
        var metadata: [String: IssuerMetadata] = [:]

        for row in wire.rows {
            // Closed-enum guard. Schema enforces this at DataPipeline
            // build; this catches an out-of-band or hand-edited artifact
            // before the engine starts trusting it.
            if !Self.validIssuerCodes.contains(row.issuerCode) {
                logger.warning(
                    "passport_patterns.json row \(row.issuerCode, privacy: .public) outside the closed V1 issuer set"
                )
                throw LoaderError.schemaInvariantViolation(
                    "row issuer_code=\(row.issuerCode) outside closed V1 enum {CA,CN,DO,GB,IN,KR,MX,PH,SV,US,VN}"
                )
            }

            // Anchored-pattern guard. Schema enforces `^...$` shape; this
            // mirrors the closed-enum guard as a second defense layer.
            for pattern in row.patterns {
                if !pattern.hasPrefix("^") || !pattern.hasSuffix("$") {
                    logger.warning(
                        "passport_patterns.json row \(row.issuerCode, privacy: .public) carries unanchored pattern"
                    )
                    throw LoaderError.schemaInvariantViolation(
                        "row \(row.issuerCode) pattern \(pattern) is not anchored ^...$"
                    )
                }
            }

            var compiled: [NSRegularExpression] = []
            compiled.reserveCapacity(row.patterns.count + (row.recentFormatChanges?.count ?? 0))
            do {
                for pattern in row.patterns {
                    compiled.append(try NSRegularExpression(pattern: pattern))
                }
                if let changes = row.recentFormatChanges {
                    for change in changes {
                        compiled.append(try NSRegularExpression(pattern: change.legacyPattern))
                    }
                }
            } catch {
                logger.warning(
                    "passport_patterns.json regex compile failed for \(row.issuerCode, privacy: .public)"
                )
                throw LoaderError.schemaInvariantViolation(
                    "row \(row.issuerCode) regex compilation failed: \(error)"
                )
            }

            patterns[row.issuerCode] = compiled
            metadata[row.issuerCode] = IssuerMetadata(
                licensePosture: row.licensePosture,
                licenseNotes: row.licenseNotes,
                confidence: row.confidence,
                checkDigitPolicy: row.checkDigitPolicy,
                recentFormatChanges: (row.recentFormatChanges ?? []).map {
                    RecentFormatChange(
                        transitionDate: $0.transitionDate,
                        legacyPattern: $0.legacyPattern,
                        currentPattern: $0.currentPattern,
                        coexistenceWindowNotes: $0.coexistenceWindowNotes
                    )
                },
                pendingDecisionMemo: row.pendingDecisionMemo.map {
                    PendingDecisionMemo(
                        fItem: $0.fItem,
                        groundingFacts: $0.groundingFacts,
                        options: $0.options,
                        precedents: $0.precedents,
                        defaultRecommendation: $0.defaultRecommendation,
                        rationale: $0.rationale
                    )
                },
                ceilingRationale: row.ceilingRationale,
                postV1Task: row.postV1Task,
                postV1Tasks: row.postV1Tasks
            )
        }

        self.patternsByIssuer = patterns
        self.metadataByIssuer = metadata
    }

    // MARK: - Lookup

    /// Match `candidate` against the patterns for a single issuer.
    /// Patterns are evaluated verbatim — callers normalize case if needed
    /// (every row has an A-Z alphabet).
    public func matches(_ candidate: String, issuedBy issuerCode: String) -> Bool {
        guard let regexes = patternsByIssuer[issuerCode] else { return false }
        let range = NSRange(location: 0, length: (candidate as NSString).length)
        return regexes.contains { $0.firstMatch(in: candidate, range: range) != nil }
    }

    /// Match `candidate` against every issuer; return the matching issuer
    /// codes in ascending order. Used by the W1 validation gate (any-
    /// issuer acceptance) and to surface multi-issuer ambiguity (e.g. an
    /// 8-char `^[A-Z]{2}[0-9]{6}$` candidate matching CA-legacy).
    public func matches(_ candidate: String, anyIssuer: ()) -> [String] {
        let range = NSRange(location: 0, length: (candidate as NSString).length)
        var hits: [String] = []
        for issuer in patternsByIssuer.keys.sorted() {
            guard let regexes = patternsByIssuer[issuer] else { continue }
            if regexes.contains(where: { $0.firstMatch(in: candidate, range: range) != nil }) {
                hits.append(issuer)
            }
        }
        return hits
    }

    /// Engineer-facing audit metadata for an issuer row. Not consumed at
    /// detection time; available for review tooling.
    public func metadata(for issuerCode: String) -> IssuerMetadata? {
        metadataByIssuer[issuerCode]
    }

    /// All issuer codes carried by this gazetteer (sorted). Useful for
    /// tests and audit tooling that need to iterate the row set.
    public var issuerCodes: [String] {
        patternsByIssuer.keys.sorted()
    }
}

// MARK: - Wire format

private struct WireFormat: Decodable {
    let version: Int
    let generatedBy: String
    let generatedDate: String
    let seed: Int
    let sourceBriefs: [String]
    let rows: [Row]

    enum CodingKeys: String, CodingKey {
        case version
        case generatedBy = "generated_by"
        case generatedDate = "generated_date"
        case seed
        case sourceBriefs = "source_briefs"
        case rows
    }

    struct Row: Decodable {
        let issuerCode: String
        let issuerName: String
        let patterns: [String]
        let alphabet: String
        let checkDigitPolicy: String
        let sample: String
        let licensePosture: String
        let licenseNotes: String
        let sourceUrl: String
        let sourceVerifiedDate: String
        let confidence: String
        let recentFormatChanges: [RecentFormatChange]?
        let pendingDecisionMemo: PendingDecisionMemo?
        let ceilingRationale: String?
        let postV1Task: String?
        let postV1Tasks: [String]?

        enum CodingKeys: String, CodingKey {
            case issuerCode = "issuer_code"
            case issuerName = "issuer_name"
            case patterns
            case alphabet
            case checkDigitPolicy = "check_digit_policy"
            case sample
            case licensePosture = "license_posture"
            case licenseNotes = "license_notes"
            case sourceUrl = "source_url"
            case sourceVerifiedDate = "source_verified_date"
            case confidence
            case recentFormatChanges = "recent_format_changes"
            case pendingDecisionMemo = "pending_decision_memo"
            case ceilingRationale = "ceiling_rationale"
            case postV1Task = "post_v1_task"
            case postV1Tasks = "post_v1_tasks"
        }
    }

    struct RecentFormatChange: Decodable {
        let transitionDate: String
        let legacyPattern: String
        let currentPattern: String
        let coexistenceWindowNotes: String

        enum CodingKeys: String, CodingKey {
            case transitionDate = "transition_date"
            case legacyPattern = "legacy_pattern"
            case currentPattern = "current_pattern"
            case coexistenceWindowNotes = "coexistence_window_notes"
        }
    }

    struct PendingDecisionMemo: Decodable {
        let fItem: String
        let groundingFacts: [String]
        let options: [String]
        let precedents: [String]
        let defaultRecommendation: String
        let rationale: String

        enum CodingKeys: String, CodingKey {
            case fItem = "f_item"
            case groundingFacts = "grounding_facts"
            case options
            case precedents
            case defaultRecommendation = "default_recommendation"
            case rationale
        }
    }
}

private let logger = Logger(subsystem: "app.resecta.engine", category: "PassportPatternGazetteer")
