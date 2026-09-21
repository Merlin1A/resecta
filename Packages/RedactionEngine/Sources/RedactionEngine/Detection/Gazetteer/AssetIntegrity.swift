import CryptoKit
import Foundation
import OSLog

// One pass over the signed manifest's `assets[]`: every listed file's size
// and SHA-256 checked against its entry. Runs behind `GazetteerTrust`'s
// memoized verdict, after the manifest signature has verified — the digests
// are only worth reading once the manifest that carries them is known to be
// the pipeline's.
//
// Two classes of entry:
//   - TRUST-GATED: the files the five signature-gated loaders read (the two
//     Bloom filters and their sidecars, the DL and passport pattern tables,
//     the context keywords, the negative-context gazetteer). A failure on one
//     of these makes the corpus verdict false — exactly what a bad signature
//     does: the five loaders are withheld and named, the banner fires.
//   - UNGATED: every other listed asset (the reference tables, the four
//     Classifier files, the audit rule catalog). A failure is reported under
//     the asset's own diagnostics case and raises the banner; the asset's
//     loader keeps its fail-open fallback.
//
// What this is, precisely: pipeline-to-bundle provenance, verified once per
// process. Tamper detection of the installed app at runtime is the app-bundle
// code signature, which seals these same files (ENGINEERING.md §8).
public enum AssetIntegrity {

    /// Bundle-relative paths the five signature-gated loaders read. A listed
    /// entry on one of these that is missing or mismatched — or one of these
    /// files present in the bundle but absent from `assets[]` — makes the
    /// corpus verdict false. `nicknames.json` is an optional sidecar: it is
    /// gated only when present.
    static let trustGatedPaths: Set<String> = [
        "Gazetteers/surnames.bloom",
        "Gazetteers/given-names.bloom",
        "Gazetteers/name-common-words.json",
        "Gazetteers/nicknames.json",
        "Gazetteers/dl_patterns.json",
        "Gazetteers/passport_patterns.json",
        "Gazetteers/context-keywords.json",
        "Gazetteers/negative-context.json",
    ]

    public enum Failure: Equatable, Sendable, CustomStringConvertible {
        case manifestUnreadable(reason: String)
        case unsupportedManifestVersion(actual: String, supported: Set<String>)
        case noAssetSection(version: String)
        /// A trust-gated file is present in the bundle but has no entry.
        case unlisted(path: String)
        case missing(path: String)
        case sizeMismatch(path: String, expected: Int, actual: Int)
        case digestMismatch(path: String)

        /// Mechanism only: paths are bundle-relative asset names, never
        /// document content.
        public var description: String {
            switch self {
            case .manifestUnreadable(let reason):
                return "manifest unreadable: \(reason)"
            case .unsupportedManifestVersion(let actual, let supported):
                return "manifest version \(actual) outside the supported set \(supported.sorted())"
            case .noAssetSection(let version):
                return "manifest \(version) carries no assets[] section"
            case .unlisted(let path):
                return "\(path): present but not listed in the signed manifest"
            case .missing(let path):
                return "\(path): listed in the signed manifest but not bundled"
            case .sizeMismatch(let path, let expected, let actual):
                return "\(path): size \(actual) B differs from the signed manifest's \(expected) B"
            case .digestMismatch(let path):
                return "\(path): SHA-256 differs from the signed manifest"
            }
        }

        /// The asset the failure is about, when it is about one asset.
        public var path: String? {
            switch self {
            case .unlisted(let path), .missing(let path), .digestMismatch(let path):
                return path
            case .sizeMismatch(let path, _, _):
                return path
            case .manifestUnreadable, .unsupportedManifestVersion, .noAssetSection:
                return nil
            }
        }
    }

    public struct Report: Equatable, Sendable {
        /// Failures that make the corpus verdict false: manifest-level
        /// failures and failures on trust-gated entries.
        public let gated: [Failure]
        /// Failures on every other listed asset — reported, never withheld.
        public let ungated: [Failure]
        /// Entries whose file matched its size and digest.
        public let verifiedCount: Int

        public var corpusIntact: Bool { gated.isEmpty }

        static let empty = Report(gated: [], ungated: [], verifiedCount: 0)
    }

    private static let logger = Logger(subsystem: "app.resecta.engine", category: "AssetIntegrity")

    /// Verify every `assets[]` entry of `bundle`'s manifest. Reads the whole
    /// tree once (the two Bloom filters dominate: ≈ 42 MB hashed, mapped not
    /// copied). Never throws: every problem is a `Failure` in the report.
    static func verify(bundle: Bundle) -> Report {
        guard let manifestURL = bundle.url(
            forResource: "gazetteer-manifest", withExtension: "json", subdirectory: "Gazetteers"
        ), let resourceRoot = bundle.resourceURL else {
            return Report(
                gated: [.manifestUnreadable(reason: "Gazetteers/gazetteer-manifest.json not bundled")],
                ungated: [], verifiedCount: 0)
        }
        let manifest: GazetteerManifest
        do {
            manifest = try JSONDecoder().decode(GazetteerManifest.self, from: Data(contentsOf: manifestURL))
        } catch { // LegalPhrases:safe — Swift catch clause, not English
            let failure = Failure.manifestUnreadable(reason: String(describing: error))
            logger.warning("asset integrity: \(failure.description, privacy: .public)")
            return Report(gated: [failure], ungated: [], verifiedCount: 0)
        }
        guard GazetteerManifest.supportedVersions.contains(manifest.version) else {
            let failure = Failure.unsupportedManifestVersion(
                actual: manifest.version, supported: GazetteerManifest.supportedVersions)
            logger.warning("asset integrity: \(failure.description, privacy: .public)")
            return Report(gated: [failure], ungated: [], verifiedCount: 0)
        }
        guard let entries = manifest.assets else {
            let failure = Failure.noAssetSection(version: manifest.version)
            logger.warning("asset integrity: \(failure.description, privacy: .public)")
            return Report(gated: [failure], ungated: [], verifiedCount: 0)
        }

        var gated: [Failure] = []
        var ungated: [Failure] = []
        var verified = 0
        for entry in entries {
            let failure = check(entry, under: resourceRoot)
            if let failure {
                logger.warning("asset integrity: \(failure.description, privacy: .public)")
                if trustGatedPaths.contains(entry.path) { gated.append(failure) } else { ungated.append(failure) }
            } else {
                verified += 1
            }
        }
        // A trust-gated file the manifest does not list: the manifest must
        // cover what is there, or a swapped-in file would go unverified.
        let listed = Set(entries.map(\.path))
        for path in trustGatedPaths.sorted() where !listed.contains(path) {
            if FileManager.default.fileExists(atPath: resourceRoot.appending(path: path).path()) {
                let failure = Failure.unlisted(path: path)
                logger.warning("asset integrity: \(failure.description, privacy: .public)")
                gated.append(failure)
            }
        }
        return Report(gated: gated, ungated: ungated, verifiedCount: verified)
    }

    /// Size first (cheap), then the digest over a mapped read.
    private static func check(_ entry: GazetteerManifest.AssetEntry, under root: URL) -> Failure? {
        let url = root.appending(path: entry.path)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path()),
              let size = attributes[.size] as? Int
        else { return .missing(path: entry.path) }
        guard size == entry.bytes else {
            return .sizeMismatch(path: entry.path, expected: entry.bytes, actual: size)
        }
        guard let bytes = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return .missing(path: entry.path)
        }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard digest == entry.sha256.lowercased() else {
            return .digestMismatch(path: entry.path)
        }
        return nil
    }

    /// The diagnostics case an UNGATED failure on `path` reports under: the
    /// asset's own loader where one exists, `assetIntegrity` otherwise (the
    /// audit rule catalog has no detection loader).
    static func diagnosticsCase(forPath path: String) -> GazetteerLoadDiagnostics.Gazetteer {
        switch path {
        case "Gazetteers/institutions.json": return .institutionGazetteer
        case "Gazetteers/address_components.json": return .addressComponentsGazetteer
        case "Gazetteers/zip_scf_states.json": return .zipStateTableLoader
        case "Classifier/doctype-keywords.json": return .documentTypeClassifier
        case "Classifier/context-scorer.json": return .contextScorerWeights
        case "Classifier/doctype-temperature.json": return .doctypeTemperature
        case "Classifier/preset-thresholds.json": return .presetThresholds
        default: return .assetIntegrity
        }
    }
}
