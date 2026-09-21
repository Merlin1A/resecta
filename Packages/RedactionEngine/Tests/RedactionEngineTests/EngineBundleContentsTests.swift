import Foundation
import Testing
@testable import RedactionEngine

// Engine-side bundle-contents guard. The app
// target's BundleContentsTests can only resolve the APP bundle (Bundle(for:)),
// so the two reviewed, drift-prone search-config resources that ship in the
// RedactionEngine resource bundle get their semantic-invariant guard here. Both
// resources are reached through the engine's own loadFromEngineBundle() accessors
// (which capture the SOURCE module's Bundle.module — a test-target Bundle.module
// would point at the test bundle, not the shipped resources). The byte-exact pin
// lives in Scripts/verify-shipped-asset-hashes.sh (git blob / SHA-256); these
// assert the invariant that pin stands for, so a legitimate re-calibration only
// updates the shell constants once. Complementary to (not a copy of)
// ContextScorerIdentityReproductionTests, which pins the per-family arithmetic.

@Suite("Engine bundle contents")
struct EngineBundleContentsTests {

    // Arity-13 non-zero feature vector so a calibrated promoted family
    // contributes a non-zero trained term (mirrors the arbitrary vector in
    // ContextScorerIdentityReproductionTests).
    private static let nonZeroFeatures: [Double] =
        [1, 1, 0.8333333333333334, 0.5, 10, 1, 1, 1, 1, 0, 0, 0, 0]

    @Test("preset-thresholds.json is the calibrated 17-category blob (not the degenerate sweep)")
    func presetThresholdsIsCalibratedBlob() throws {
        let bundle = PresetThresholdBundle.loadFromEngineBundle()
        // .calibrated (not .placeholder) proves the shipped resource decoded — a
        // missing / corrupt file falls back to .builtInDefaults (.placeholder).
        #expect(bundle.status == .calibrated)
        let balanced = try #require(bundle.presets[.balanced])
        // All 17 schema categories carry a threshold row in the balanced preset.
        #expect(balanced.thresholdsByWireName.count == 17)
        // name is the calibrated value, NOT the degenerate 0.98 sweep output.
        let name = try #require(balanced.threshold(forWireName: "name"))
        #expect(name <= 0.90)
    }

    @Test("The shipped manifest lists every bundled asset, each digest and size match, and the corpus is trusted")
    func shippedManifestListsEveryAssetAndVerifies() throws {
        // The shipped bundle's own verdict (memoized in the engine module).
        let verdict = GazetteerTrust.shippedCorpusVerdict()
        #expect(verdict.isTrusted, "\(verdict)")
        let report = try #require(verdict.report)
        #expect(report.ungated.isEmpty, "\(report.ungated)")
        // Fifteen installed assets: the two Bloom filters and eight JSON tables
        // under Gazetteers/, the four Classifier/ files, the Audit/ catalog —
        // everything except the manifest, its signature and the public key.
        #expect(report.verifiedCount == 15)

        // The same tree as the test target carries it: every entry's file
        // present with the recorded size; the trust-gated set fully listed.
        let manifestURL = try #require(Bundle.module.url(
            forResource: "gazetteer-manifest", withExtension: "json", subdirectory: "Gazetteers"))
        let manifest = try JSONDecoder().decode(GazetteerManifest.self, from: Data(contentsOf: manifestURL))
        let entries = try #require(manifest.assets)
        #expect(GazetteerManifest.supportedVersions.contains(manifest.version))
        #expect(entries.count == 15)
        #expect(entries.map(\.path) == entries.map(\.path).sorted(), "entries are sorted by path")
        let listed = Set(entries.map(\.path))
        let gatedShipped = AssetIntegrity.trustGatedPaths.subtracting(["Gazetteers/nicknames.json"])
        #expect(gatedShipped.isSubset(of: listed), "\(gatedShipped.subtracting(listed))")
        #expect(!listed.contains("Gazetteers/gazetteer-manifest.json"))
        #expect(!listed.contains("Gazetteers/gazetteer_manifest.sig"))
        #expect(!listed.contains("Gazetteers/manifest_public_key.pem"))
        let root = try #require(Bundle.module.resourceURL)
        for entry in entries {
            let size = try FileManager.default.attributesOfItem(atPath: root.appending(path: entry.path).path())[.size] as? Int
            #expect(size == entry.bytes, "\(entry.path)")
        }
    }

    @Test("context-scorer.json loads as the calibrated (non-identity) scorer")
    func contextScorerLoadsAsCalibratedNonIdentity() throws {
        // loadFromEngineBundle() falls open to .identity on any missing-resource /
        // decode / arity / scale / version / SHA-256 problem (the compiled
        // fecd89b6 self-check at ContextScorerWeights line 59). A non-zero trained
        // term for a promoted family proves the shipped bytes are present and the
        // self-check still matches — i.e. update-context-scorer-hash.sh was not
        // forgotten after a scorer-bytes change.
        let scorer = ContextScorerWeights.loadFromEngineBundle()
        #expect(scorer.learnedContextLogit(family: "account", features: Self.nonZeroFeatures) != 0)
    }
}
