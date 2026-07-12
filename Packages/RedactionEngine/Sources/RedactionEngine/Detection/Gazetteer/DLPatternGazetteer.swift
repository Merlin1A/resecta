import Foundation
import OSLog

// Driver's-license-pattern gazetteer. Loads `dl_patterns.json`
// produced by DataPipeline's src/resecta_data/gazetteers/dl_patterns/build.py
// (DP commit 9940520, 2026-04-26). 51 rows = 50 states + DC.
//
// Spec authority: the DataPipeline data-requirements spec §1.15 + §7.3
//   (F-25 closed by Disposition §2 — NC/TN/UT statute-anchored;
//    AK/MT/SC/SD/WV/WY/DC envelope.
//    F-39 closed by Disposition §8 — IL/WA/NV/NJ envelope.)
// Schema: ../resecta-datapipeline/schemas/dl_patterns.schema.json
//
// Layered onto the existing inline label-prefix detector at
// PIIDetector.detectDriversLicenses; this gazetteer supplies per-state
// validation patterns (W1 strategy: candidate from inline regex must match
// at least one state's pattern, otherwise it is suppressed).
//
// SSN/DLN two-way ambiguity: five rows (AR/HI/ID/LA/MS) carry
// `dln_overlap_note`.
// `matches(_:anyState:)` surfaces this — a 9-digit candidate may match
// multiple states' patterns; engine-side mitigation routes through the
// label-anchor work, not this loader.
//
// `@unchecked Sendable`: the struct stores `[NSRegularExpression]` per
// state. NSRegularExpression is not formally `Sendable` in Swift 6
// (NSObject-bridged) but Apple's documentation declares it thread-safe
// once initialised; the regexes are loaded once and never mutated.

public struct DLPatternGazetteer: @unchecked Sendable {

    public enum LoaderError: Error {
        case resourceMissing
        case decodingFailed(underlying: Error)
        case schemaInvariantViolation(String)
        case unsupportedVersion(actual: Int, supported: ClosedRange<Int>)
    }

    private static let supportedVersions: ClosedRange<Int> = 1...1

    /// Engineer-facing audit metadata for a state row. Not consumed at
    /// detection time — surfaced so review tooling can inspect per-row
    /// attestation, license posture, F-flag context, and the F-35 SSN/DLN
    /// overlap note where present (AR/HI/ID/LA/MS only).
    public struct StateMetadata: Sendable {
        public let attestation: String
        public let licensePosture: String
        public let stateFormatClaimed: Bool
        public let confidence: String
        public let piiSeverity: String?
        public let dlnOverlapNote: String?
        public let fFlags: [String]
    }

    private let patternsByState: [String: [NSRegularExpression]]
    private let metadataByState: [String: StateMetadata]
    private let advisoryNoteValue: String?

    /// Canonical AAMVA M1 envelope per legal-ref §8.4 / §8.4a. Locked at
    /// load time for every `aamva-envelope` row (defense-in-depth beyond
    /// the build-side schema check).
    private static let canonicalEnvelopePattern = "^[A-Z0-9]{8,13}$"

    // MARK: - Init

    /// Load from the module bundle.
    public init() throws {
        try self.init(bundle: .module)
    }

    /// Testing / composition init — inject a custom bundle.
    init(bundle: Bundle) throws {
        guard let url = bundle.url(
            forResource: "dl_patterns",
            withExtension: "json",
            subdirectory: "Gazetteers"
        ) else {
            logger.info("dl_patterns.json not bundled; DL pattern gazetteer inert")
            throw LoaderError.resourceMissing
        }

        let wire: WireFormat
        do {
            let bytes = try Data(contentsOf: url)
            wire = try JSONDecoder().decode(WireFormat.self, from: bytes)
        } catch {
            logger.warning("dl_patterns.json decode failed: \(String(describing: error), privacy: .public)")
            throw LoaderError.decodingFailed(underlying: error)
        }

        try LoaderVersionFence.assert(
            actual: wire.version,
            supported: Self.supportedVersions,
            assetName: "dl_patterns",
            logger: logger,
            throwing: { LoaderError.unsupportedVersion(actual: $0, supported: $1) }
        )

        var patterns: [String: [NSRegularExpression]] = [:]
        var metadata: [String: StateMetadata] = [:]

        for row in wire.rows {
            // Envelope-rule lock. Schema enforces this at DataPipeline
            // build; this guard catches an out-of-band or hand-edited
            // artifact before the engine starts trusting it.
            if row.licensePosture == "aamva-envelope"
                && row.patterns != [Self.canonicalEnvelopePattern] {
                logger.warning(
                    "dl_patterns.json envelope row \(row.stateCode, privacy: .public) violates AAMVA M1 lock"
                )
                throw LoaderError.schemaInvariantViolation(
                    "row \(row.stateCode) license_posture=aamva-envelope but patterns=\(row.patterns)"
                )
            }

            var compiled: [NSRegularExpression] = []
            compiled.reserveCapacity(row.patterns.count + (row.historicalVariants?.count ?? 0))
            do {
                for pattern in row.patterns {
                    compiled.append(try NSRegularExpression(pattern: pattern))
                }
                // Historical variants (3 rows: MA, NH, RI) sit inside the
                // active renewal window per the d13-DONE record — the
                // legacy_pattern still matches DLs in real circulation.
                if let variants = row.historicalVariants {
                    for variant in variants {
                        compiled.append(try NSRegularExpression(pattern: variant.legacyPattern))
                    }
                }
            } catch {
                logger.warning(
                    "dl_patterns.json regex compile failed for \(row.stateCode, privacy: .public)"
                )
                throw LoaderError.schemaInvariantViolation(
                    "row \(row.stateCode) regex compilation failed: \(error)"
                )
            }

            patterns[row.stateCode] = compiled
            metadata[row.stateCode] = StateMetadata(
                attestation: row.attestation,
                licensePosture: row.licensePosture,
                stateFormatClaimed: row.stateFormatClaimed,
                confidence: row.confidence,
                piiSeverity: row.piiSeverity,
                dlnOverlapNote: row.dlnOverlapNote,
                fFlags: row.fFlags
            )
        }

        self.patternsByState = patterns
        self.metadataByState = metadata
        self.advisoryNoteValue = wire.advisoryNote
    }

    // MARK: - Lookup

    /// Match `candidate` against the patterns for a single jurisdiction.
    /// Patterns are evaluated verbatim — callers normalize case if needed
    /// (most rows have an A-Z alphabet).
    public func matches(_ candidate: String, in stateCode: String) -> Bool {
        guard let regexes = patternsByState[stateCode] else { return false }
        let range = NSRange(location: 0, length: (candidate as NSString).length)
        return regexes.contains { $0.firstMatch(in: candidate, range: range) != nil }
    }

    /// Match `candidate` against every jurisdiction; return the matching
    /// state codes in ascending order. Used by the W1 validation gate
    /// (any-state acceptance) and to surface the F-35 SSN/DLN ambiguity
    /// for AR/HI/ID/LA/MS-shaped 9-digit candidates.
    public func matches(_ candidate: String, anyState: ()) -> [String] {
        let range = NSRange(location: 0, length: (candidate as NSString).length)
        var hits: [String] = []
        for state in patternsByState.keys.sorted() {
            guard let regexes = patternsByState[state] else { continue }
            if regexes.contains(where: { $0.firstMatch(in: candidate, range: range) != nil }) {
                hits.append(state)
            }
        }
        return hits
    }

    /// File-root advisory note (F-32 Tier 2 advisory per legal-ref §13.6 /
    /// §12.3, delegation 2026-04-26). A single string at the JSON root,
    /// not a per-row field — `nil` if the artifact omits it.
    public func advisoryNote() -> String? {
        advisoryNoteValue
    }

    /// Engineer-facing audit metadata for a state row. Not consumed at
    /// detection time; available for review tooling.
    public func metadata(for stateCode: String) -> StateMetadata? {
        metadataByState[stateCode]
    }

    /// All state codes carried by this gazetteer (sorted). Useful for
    /// tests and audit tooling that need to iterate the row set.
    public var stateCodes: [String] {
        patternsByState.keys.sorted()
    }
}

// MARK: - Wire format

private struct WireFormat: Decodable {
    let version: Int
    let generatedBy: String
    let generatedDate: String
    let seed: Int
    let sourceBriefs: [String]
    let advisoryNote: String?
    let rows: [Row]

    enum CodingKeys: String, CodingKey {
        case version
        case generatedBy = "generated_by"
        case generatedDate = "generated_date"
        case seed
        case sourceBriefs = "source_briefs"
        case advisoryNote = "_advisory_note"
        case rows
    }

    struct Row: Decodable {
        let stateCode: String
        let stateName: String
        let patterns: [String]
        let lengthRange: LengthRange
        let alphabet: String
        let sample: String
        let sourceUrl: String
        let sourceVerifiedDate: String
        let licensePosture: String
        let licenseNotes: String
        let attestation: String
        let stateFormatClaimed: Bool
        let historicalVariants: [HistoricalVariant]?
        let confidence: String
        let piiSeverity: String?
        let dlnOverlapNote: String?
        let fFlags: [String]

        enum CodingKeys: String, CodingKey {
            case stateCode = "state_code"
            case stateName = "state_name"
            case patterns
            case lengthRange = "length_range"
            case alphabet
            case sample
            case sourceUrl = "source_url"
            case sourceVerifiedDate = "source_verified_date"
            case licensePosture = "license_posture"
            case licenseNotes = "license_notes"
            case attestation
            case stateFormatClaimed = "state_format_claimed"
            case historicalVariants = "historical_variants"
            case confidence
            case piiSeverity = "pii_severity"
            case dlnOverlapNote = "dln_overlap_note"
            case fFlags = "f_flags"
        }
    }

    struct LengthRange: Decodable {
        let min: Int
        let max: Int
    }

    struct HistoricalVariant: Decodable {
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
}

private let logger = Logger(subsystem: "app.resecta.engine", category: "DLPatternGazetteer")
