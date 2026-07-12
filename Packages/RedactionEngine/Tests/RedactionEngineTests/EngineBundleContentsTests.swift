import Foundation
import Testing
@testable import RedactionEngine

// D11-config-golive-F6 Phase A — engine-side bundle-contents guard. The app
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

@Suite("Engine bundle contents (D11-F6 Phase A)")
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
