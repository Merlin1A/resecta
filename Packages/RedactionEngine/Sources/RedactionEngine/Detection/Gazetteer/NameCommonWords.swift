import Foundation
import OSLog

// Common-word curation for the surname Bloom filter.
// Loads `name-common-words.json` from `Gazetteers/` in the module bundle: a
// list of ordinary English words ("the", "table", "employer") that the multilingual
// surname filter may also carry as genuine inventory rows. The filter's
// structural false-positive rate sits at its design target; the MEMBERSHIP
// of an English word list is a different quantity, and this sidecar is the
// curation read on top of it. `NameGazetteer.queryBoosted` withholds the
// surname credit — exact and fuzzy — for a candidate whose surname token is
// an exact member, and the first tagger pass does not count such membership
// as inventory support. The Bloom filters themselves are never edited by
// this file: demote, never strip.
//
// The file is a standalone sidecar (not part of the signed Bloom manifest).
// Absent or unreadable → the gazetteer runs without it → no demotion
// (fail-open, matching the nickname sidecar's posture).
//
// Keys are NFKC-normalized and lowercased at load time, the same key the
// Bloom lookup uses, so membership and curation read the same string.

/// The common-word curation list the name gazetteer consults beside the
/// surname Bloom filter.
public struct NameCommonWords: Sendable {

    public enum LoaderError: Error {
        case resourceMissing
        case decodingFailed(underlying: Error)
        case unsupportedVersion(actual: Int, supported: ClosedRange<Int>)
    }

    /// The loader-version fence: bump when the sidecar's shape changes.
    public static let supportedVersions: ClosedRange<Int> = 1...1

    private let members: Set<String>

    /// Number of distinct curated words.
    public var count: Int { members.count }

    /// The curated words, NFKC-lowercased — exposed for audit and tests.
    public var entries: Set<String> { members }

    // MARK: - Init

    /// Load from the module bundle.
    public init() throws {
        try self.init(bundle: .module)
    }

    /// Testing / composition init — inject a custom bundle.
    init(bundle: Bundle) throws {
        guard let url = bundle.url(
            forResource: "name-common-words",
            withExtension: "json",
            subdirectory: "Gazetteers"
        ) else {
            logger.info("name-common-words.json not bundled; common-word curation inert")
            throw LoaderError.resourceMissing
        }

        do {
            let bytes = try Data(contentsOf: url)
            let wire = try JSONDecoder().decode(WireFormat.self, from: bytes)
            try LoaderVersionFence.assert(
                actual: wire.version,
                supported: Self.supportedVersions,
                assetName: "name-common-words",
                logger: logger,
                throwing: { LoaderError.unsupportedVersion(actual: $0, supported: $1) }
            )
            self.members = Set(wire.entries.map(Self.normalize))
        } catch let error as LoaderError { // LegalPhrases:safe
            throw error
        } catch { // LegalPhrases:safe
            logger.warning(
                "name-common-words.json decode failed: \(String(describing: error), privacy: .public)")
            throw LoaderError.decodingFailed(underlying: error)
        }
    }

    /// Direct init for tests — normalizes at construction time.
    public init(words: [String]) {
        self.members = Set(words.map(Self.normalize))
    }

    // MARK: - Lookup

    /// Whether `token` (any casing, any Unicode form) is a curated common word.
    public func contains(_ token: String) -> Bool {
        members.contains(Self.normalize(token))
    }

    /// The lookup key: NFKC-normalized and lowercased, as the Bloom filter hashes it.
    static func normalize(_ token: String) -> String {
        TextNormalizer.normalize(token).lowercased()
    }
}

private struct WireFormat: Decodable {
    let version: Int
    let generatedBy: String
    let seed: Int
    let entries: [String]
    enum CodingKeys: String, CodingKey {
        case version, seed, entries
        case generatedBy = "generated_by"
    }
}

private let logger = Logger(subsystem: "app.resecta.engine", category: "NameCommonWords")
