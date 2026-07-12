import Foundation

// G2a: Codable manifest for bundled gazetteer Bloom filters.
// Loaded from Resources/Gazetteers/gazetteer-manifest.json via Bundle.module.

/// Metadata for the bundled gazetteer Bloom filter assets.
///
/// The manifest records provenance (source datasets, licenses, build date),
/// filter parameters (n, m, k, FPR target), and a semantic version.
/// Built by `Scripts/gazetteer/build_bloom.py` at dev time.
public struct GazetteerManifest: Codable, Sendable, Equatable {

    /// Semantic version of the gazetteer asset bundle (e.g. "1.0.0").
    public let version: String

    /// Hash algorithm used for Bloom filter construction.
    /// Expected: "MurmurHash3_x64_128".
    public let hashAlgorithm: String

    /// Seed passed to the hash function.
    public let seed: Int

    /// Per-filter metadata entries.
    public let filters: [FilterEntry]

    /// Metadata for a single Bloom filter file.
    public struct FilterEntry: Codable, Sendable, Equatable {
        /// Filter name (e.g. "surnames", "given-names").
        public let name: String
        /// Filter type — "surname" or "givenName".
        public let type: String
        /// Number of unique entries inserted.
        public let n: Int
        /// Number of bits in the filter.
        public let m: Int
        /// Number of hash functions.
        public let k: Int
        /// Target false-positive rate (e.g. 0.001 for 0.1%).
        public let fprTarget: Double
        /// Source dataset identifiers.
        public let sources: [String]
        /// ISO 8601 build timestamp.
        public let builtAt: String
    }
}
