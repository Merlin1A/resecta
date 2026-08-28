import Foundation
import OSLog

// JSON-backed ZIP → state loader. Consumes `zip_scf_states.json`
// produced by DataPipeline's src/resecta_data/gazetteers/zip_scf/. The
// JSON carries two tables:
//
//   * `scf_table` — 3-digit SCF prefix → 2-letter state code. Primary lookup.
//   * `overrides` — 5-digit ZIP → 2-letter state code. Applied first for
//     full-ZIP queries; corrects the handful of ZIPs whose state disagrees
//     with their SCF prefix (e.g., 82063 is in CO, not WY).
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
}

// MARK: - Wire format

private struct WireFormat: Decodable {
    let version: Int
    let scf_table: [String: String]
    let overrides: [String: String]?
}

private let logger = Logger(subsystem: "app.resecta.engine", category: "ZIPStateTableLoader")
