import Foundation

// G2a: Codable manifest for the bundled detection assets.
// Loaded from Resources/Gazetteers/gazetteer-manifest.json via Bundle.module.

/// Metadata for the bundled detection assets.
///
/// The manifest records the Bloom filters' provenance and parameters
/// (`filters`) and, since version 1.1.0, the SHA-256 and size of every other
/// asset the pipeline installs into this bundle (`assets`). Written by the
/// data pipeline (`resecta-data build bloom` + `manifest-assets`) and signed
/// there; `GazetteerLoader` verifies the signature and `AssetIntegrity`
/// verifies each listed file against its entry at first load.
public struct GazetteerManifest: Codable, Sendable, Equatable {

    /// The manifest `version` values this engine accepts — the single source
    /// of truth for every loader that fences the manifest (`NameGazetteer`'s
    /// two initializers and `AssetIntegrity` read it here). The field is a
    /// semver String, so the Int-range `LoaderVersionFence` does not apply;
    /// membership is the check. Only the version that carries `assets` is
    /// accepted: a digest-less manifest would pass the signature check and
    /// silently skip the per-asset verification.
    public static let supportedVersions: Set<String> = ["1.1.0"]

    /// Semantic version of the manifest format (e.g. "1.1.0").
    public let version: String

    /// Hash algorithm used for Bloom filter construction.
    /// Expected: "MurmurHash3_x64_128".
    public let hashAlgorithm: String

    /// Seed passed to the hash function.
    public let seed: Int

    /// Per-filter metadata entries.
    public let filters: [FilterEntry]

    /// Every installed asset except the manifest, its signature and the
    /// public key: bundle-relative path, SHA-256 and byte count of the bytes
    /// the pipeline shipped. Optional in the decoder so a pre-1.1.0 manifest
    /// still decodes and is refused by the version fence with the precise
    /// reason rather than by a decoding error.
    public let assets: [AssetEntry]?

    /// One installed asset as the pipeline recorded it.
    public struct AssetEntry: Codable, Sendable, Equatable {
        /// Bundle-relative path (e.g. "Gazetteers/surnames.bloom").
        public let path: String
        /// Lowercase hex SHA-256 of the installed bytes.
        public let sha256: String
        /// Byte count of the installed file.
        public let bytes: Int
    }

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
