import Foundation
import OSLog

// Nickname sidecar gazetteer.
// Loads `nicknames.json` from `Gazetteers/` in the module bundle and exposes
// a single lookup: given an alias surface form (e.g. "bill"), return the list
// of canonical given names it is used by the nickname table to resolve
// (e.g. ["william"]).  The file is a standalone sidecar — not part of the
// signed bloom manifest — so its absence does not affect bloom correctness.
//
// Keys are NFKC-normalized and lowercased at load time so callers can pass
// raw OCR text and hit case-insensitively.

/// JSON nickname sidecar gazetteer for given-name alias resolution.
///
/// Used by `NameGazetteer.queryBoosted` to widen given-name bloom queries:
/// when a given-name token misses the bloom, the detector re-queries each
/// canonical form returned by this table.  The false-positive cost is bounded
/// by NLTagger — `queryBoosted` is only reached when NLTagger has already
/// tagged the token as `.personalName`; common English homophones of nickname
/// forms ("bob" as a verb, "bill" as a noun) are filtered before the bloom
/// query.  The FPR increase is small.
public struct NicknameGazetteer: Sendable {

    public enum LoaderError: Error {
        case resourceMissing
        case decodingFailed(underlying: Error)
        case unsupportedVersion(actual: Int, supported: ClosedRange<Int>)
    }

    private static let supportedVersions: ClosedRange<Int> = 1...1

    private let entries: [String: [String]]

    // MARK: - Init

    /// Load from the module bundle.
    public init() throws {
        try self.init(bundle: .module)
    }

    /// Testing / composition init — inject a custom bundle.
    init(bundle: Bundle) throws {
        guard let url = bundle.url(
            forResource: "nicknames",
            withExtension: "json",
            subdirectory: "Gazetteers"
        ) else {
            logger.info("nicknames.json not bundled; nickname gazetteer inert")
            throw LoaderError.resourceMissing
        }

        do {
            let bytes = try Data(contentsOf: url)
            let wire = try JSONDecoder().decode(WireFormat.self, from: bytes)
            try LoaderVersionFence.assert(
                actual: wire.version,
                supported: Self.supportedVersions,
                assetName: "nicknames",
                logger: logger,
                throwing: { LoaderError.unsupportedVersion(actual: $0, supported: $1) }
            )
            var normalized: [String: [String]] = [:]
            for (key, values) in wire.entries {
                normalized[Self.normalize(key)] = values
            }
            self.entries = normalized
        } catch let error as LoaderError { // LegalPhrases:safe
            throw error
        } catch { // LegalPhrases:safe
            logger.warning(
                "nicknames.json decode failed: \(String(describing: error), privacy: .public)")
            throw LoaderError.decodingFailed(underlying: error)
        }
    }

    /// Direct init for tests — normalize keys at construction time.
    public init(entries: [String: [String]]) {
        var normalized: [String: [String]] = [:]
        for (key, values) in entries {
            normalized[Self.normalize(key)] = values
        }
        self.entries = normalized
    }

    // MARK: - Lookup

    /// Return canonical given names the alias is used to resolve, or an empty array.
    ///
    /// Input is NFKC-normalized and lowercased before lookup, matching the build
    /// pipeline's preprocessing.  Returns `[]` if the alias is not in the table.
    public func canonicals(for alias: String) -> [String] {
        entries[Self.normalize(alias)] ?? []
    }

    // MARK: - Normalization

    private static func normalize(_ s: String) -> String {
        TextNormalizer.normalize(s)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Wire format

private struct WireFormat: Decodable {
    let version: Int
    let entries: [String: [String]]
    // generated_by, seed, sources are present in the JSON but not consumed by
    // the Swift decoder — Decodable ignores unknown keys by default.
}

private let logger = Logger(subsystem: "app.resecta.engine", category: "NicknameGazetteer")
