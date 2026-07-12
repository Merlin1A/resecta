import Foundation
import Testing
@testable import RedactionEngine

// B03 — loader fail-open fallback (the rollback unit).
//
// Any missing resource / decode / version / arity / scale / hash problem must
// yield the WHOLE-SCORER identity (every learnedContextLogit 0 ⇒ exactly the S3
// baseline), never a crash. Each case uses a w=1 "account" block that WOULD
// score 13.0 if loaded, so a 0 result proves the fallback actually fired (the
// positive control below shows a clean payload does load and score 13.0).
// `make(from:verifyingHash:)` is the testable core; `verifyingHash: nil` skips
// only the compiled-in SHA self-check so the decode/version/arity paths are
// reachable in a unit test.

@Suite("Context scorer loader fallback")
struct ContextScorerLoaderMismatchTests {

    private static let feats13 = [Double](repeating: 1.0, count: 13)

    private static func familyDict(
        weights: [Double], scales: [Double], wFamily: Double, bias: Double = 0
    ) -> [String: Any] {
        [
            "weights": weights,
            "bias": bias,
            "feature_means": [Double](repeating: 0.0, count: weights.count),
            "feature_scales": scales,
            "w_family": wFamily,
            "support": ["redact": 0, "suppress": 0],
        ]
    }

    private static func identityDict() -> [String: Any] {
        familyDict(
            weights: [Double](repeating: 0.0, count: 13),
            scales: [Double](repeating: 1.0, count: 13),
            wFamily: 0.0)
    }

    /// A live account block (w=1, unit weights/scales) that scores 13.0 on feats13.
    private static var liveAccount: [String: Any] {
        familyDict(
            weights: [Double](repeating: 1.0, count: 13),
            scales: [Double](repeating: 1.0, count: 13),
            wFamily: 1.0)
    }

    private static func envelopeData(
        version: Int = 1, featureOrder: [String]? = nil, account: [String: Any]? = nil
    ) -> Data {
        let order = featureOrder ?? ContextFeatureContract.featureOrder
        let obj: [String: Any] = [
            "version": version,
            "generated_by": "test",
            "seed": 0,
            "status": "candidates",
            "feature_order": order,
            "families": [
                "account": account ?? identityDict(),
                "phone": identityDict(),
                "mrn": identityDict(),
                "ein": identityDict(),
                "itin": identityDict(),
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }

    private func accountLogit(_ scorer: ContextScorerWeights) -> Double {
        scorer.learnedContextLogit(family: "account", features: Self.feats13)
    }

    @Test("Positive control: a well-formed w=1 payload loads and scores 13.0")
    func wellFormedLoadsNonZero() {
        let scorer = ContextScorerWeights.make(from: Self.envelopeData(account: Self.liveAccount),
                                               verifyingHash: nil)
        #expect(accountLogit(scorer) == 13.0)
    }

    @Test("Version outside 1...1 is converted to identity (LoaderVersionFence wired)")
    func unsupportedVersionFallsBack() {
        let scorer = ContextScorerWeights.make(
            from: Self.envelopeData(version: 2, account: Self.liveAccount), verifyingHash: nil)
        #expect(accountLogit(scorer) == 0)
    }

    @Test("Arity mismatch falls back to identity")
    func arityMismatchFallsBack() {
        let bad = Self.familyDict(
            weights: [Double](repeating: 1.0, count: 12),
            scales: [Double](repeating: 1.0, count: 12), wFamily: 1.0)
        let scorer = ContextScorerWeights.make(
            from: Self.envelopeData(account: bad), verifyingHash: nil)
        #expect(accountLogit(scorer) == 0)
    }

    @Test("Non-positive feature scale falls back to identity")
    func nonPositiveScaleFallsBack() {
        var scales = [Double](repeating: 1.0, count: 13)
        scales[3] = 0.0
        let bad = Self.familyDict(
            weights: [Double](repeating: 1.0, count: 13), scales: scales, wFamily: 1.0)
        let scorer = ContextScorerWeights.make(
            from: Self.envelopeData(account: bad), verifyingHash: nil)
        #expect(accountLogit(scorer) == 0)
    }

    @Test("feature_order drift falls back to identity")
    func featureOrderDriftFallsBack() {
        let drifted = Array(ContextFeatureContract.featureOrder.reversed())
        let scorer = ContextScorerWeights.make(
            from: Self.envelopeData(featureOrder: drifted, account: Self.liveAccount),
            verifyingHash: nil)
        #expect(accountLogit(scorer) == 0)
    }

    @Test("SHA-256 self-check mismatch falls back to identity")
    func hashMismatchFallsBack() {
        let wrong = String(repeating: "0", count: 64)
        let scorer = ContextScorerWeights.make(
            from: Self.envelopeData(account: Self.liveAccount), verifyingHash: wrong)
        #expect(accountLogit(scorer) == 0)
    }

    @Test("Corrupt bytes fall back to identity without a crash")
    func corruptBytesFallBack() {
        let scorer = ContextScorerWeights.make(
            from: Data("this is not json".utf8), verifyingHash: nil)
        #expect(accountLogit(scorer) == 0)
    }

    @Test("A bundle without the resource falls back to identity")
    func missingResourceFallsBack() {
        let scorer = ContextScorerWeights.load(from: Bundle.main)
        #expect(accountLogit(scorer) == 0)
    }
}
