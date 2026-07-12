import Foundation
import OSLog

// L6 / C12 — JSON-backed ZIP → state loader. Consumes `zip_scf_states.json`
// produced by DataPipeline's src/resecta_data/gazetteers/zip_scf/ (C11). The
// JSON carries two tables:
//
//   * `scf_table` — 3-digit SCF prefix → 2-letter state code. Primary lookup.
//   * `overrides` — 5-digit ZIP → 2-letter state code. Applied first for
//     full-ZIP queries; corrects the handful of ZIPs whose state disagrees
//     with their SCF prefix (e.g., 82063 is in CO, not WY).
//
// W-Q (§D12 = L3 full) — the loader now accepts an optional per-profile
// `userOverrides: [String: String]` map (5-digit ZIP → 2-letter state).
// `state(forZIP:)` resolves in three tiers under P1 semantics: user wins
// over shipped, shipped wins over SCF.
//
// If the bundle resource is missing or decoding fails, the loader throws and
// `ZIPStateTable` falls back to its hardcoded enum (pattern mirrors
// `DocumentTypeClassifier.loadData(from:)` graceful-degradation path).

public struct ZIPStateTableLoader: Sendable {

    public enum LoaderError: Error {
        case resourceMissing
        case decodingFailed(underlying: Error)
        case unsupportedVersion(actual: Int, supported: ClosedRange<Int>)
    }

    private static let supportedVersions: ClosedRange<Int> = 1...1

    private let scfTable: [String: String]
    private let overrides: [String: String]
    private let userOverrides: [String: String]

    // MARK: - Init

    /// Load from the module bundle without any per-profile user overrides.
    public init() throws {
        try self.init(bundle: .module, userOverrides: [:])
    }

    /// Load from the module bundle with a per-profile `userOverrides` map
    /// (5-digit ZIP → 2-letter state). User entries take precedence over
    /// the shipped 5-digit overrides table on `state(forZIP:)` lookups.
    public init(userOverrides: [String: String]) throws {
        try self.init(bundle: .module, userOverrides: userOverrides)
    }

    /// Testing / composition init — inject a custom bundle.
    init(bundle: Bundle, userOverrides: [String: String] = [:]) throws {
        guard let url = bundle.url(
            forResource: "zip_scf_states",
            withExtension: "json",
            subdirectory: "Gazetteers"
        ) else {
            logger.info("zip_scf_states.json not bundled; ZIP loader inert")
            throw LoaderError.resourceMissing
        }

        do {
            let bytes = try Data(contentsOf: url)
            let wire = try JSONDecoder().decode(WireFormat.self, from: bytes)
            try LoaderVersionFence.assert(
                actual: wire.version,
                supported: Self.supportedVersions,
                assetName: "zip_scf_states",
                logger: logger,
                throwing: { LoaderError.unsupportedVersion(actual: $0, supported: $1) }
            )
            self.scfTable = wire.scf_table
            self.overrides = wire.overrides ?? [:]
            self.userOverrides = userOverrides
        } catch let error as LoaderError {
            throw error
        } catch {
            logger.warning("zip_scf_states.json decode failed: \(String(describing: error), privacy: .public)")
            throw LoaderError.decodingFailed(underlying: error)
        }
    }

    // MARK: - Lookup

    /// Map a 3-digit ZIP prefix to a 2-letter state code. Returns `nil` for
    /// unknown prefixes — callers treat `nil` as "no cross-check".
    public func state(forZIPPrefix prefix: String) -> String? {
        guard prefix.count == 3 else { return nil }
        return scfTable[prefix]
    }

    /// Map a full ZIP (or ZIP+4) to a 2-letter state code. Resolves in three
    /// tiers (W-Q / §D12 = L3): per-profile user overrides → shipped 5-digit
    /// overrides → 3-digit SCF prefix. User entries take precedence so an
    /// editor-entered fix overrides shipped data without requiring a
    /// gazetteer rebuild.
    public func state(forZIP zip: String) -> String? {
        let trimmed = zip.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = String(trimmed.prefix { $0.isWholeNumber })
        if digits.count >= 5 {
            let key = String(digits.prefix(5))
            if let hit = userOverrides[key] { return hit }
            if let hit = overrides[key] { return hit }
        }
        guard digits.count >= 3 else { return nil }
        return scfTable[String(digits.prefix(3))]
    }
}

// MARK: - Wire format

private struct WireFormat: Decodable {
    let version: Int
    let scf_table: [String: String]
    let overrides: [String: String]?
}

private let logger = Logger(subsystem: "app.resecta.engine", category: "ZIPStateTableLoader")
