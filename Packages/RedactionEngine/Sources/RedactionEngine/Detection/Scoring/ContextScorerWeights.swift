import CryptoKit
import Foundation
import OSLog

// B03 — on-device consumer of the context-scorer wire (plan 04 §4.4;
// DataPipeline specs/FORMAT_CONTRACTS.md §15). The C1 augment scorer is one
// additive log-odds term at the posterior seam:
//
//   finalConfidence = sigmoid(logit(raw) + logit(prior) + learnedContextLogit)
//   learnedContextLogit = w_family * (bias + sum_i weights[i] * z_i)
//   z_i = (features[i] - feature_means[i]) / feature_scales[i]
//
// Per-family logistic weights are decoded BY NAME and keyed by
// PresetThresholdVector.wireName(for:). `features` is the [Double] vector that
// ContextFeatures.contextFeatures(...) returns, positional in
// ContextFeatureContract.featureOrder order — the loader pins that order so the
// index alignment holds.
//
// Rollback is fail-open and whole-scorer: any missing resource / decode /
// arity / scale / hash / version problem yields the identity scorer (every
// learnedContextLogit is 0 ⇒ exactly the S3 baseline behavior). A per-family
// `w_family == 0` is the finer, deliberate per-family off switch.
//
// B05 shipped the calibrated artifact (d2786a4) — the bundled weights are the
// trained per-family values, no longer the B03 all-zero placeholder. A family
// can still be switched off individually via `w_family == 0`.
//
// Privacy (ARCH §12.2): logs emit mechanism metadata + error.localizedDescription
// only — never document text, PII values, or coordinates.

struct ContextScorerWeights: Sendable {

    /// One per-family logistic block. `support` is provenance only and is not
    /// decoded here (the Swift side reads only the scoring fields).
    struct FamilyWire: Decodable, Sendable {
        let weights: [Double]
        let bias: Double
        let featureMeans: [Double]
        let featureScales: [Double]
        let wFamily: Double

        enum CodingKeys: String, CodingKey {
            case weights
            case bias
            case featureMeans = "feature_means"
            case featureScales = "feature_scales"
            case wFamily = "w_family"
        }
    }

    private let families: [String: FamilyWire]

    static let logger = Logger(subsystem: "app.resecta.engine", category: "context-scorer")

    /// SHA-256 of the bundled `context-scorer.json` bytes. Maintained by
    /// Scripts/update-context-scorer-hash.sh; equals the DataPipeline
    /// asset_hashes.lock entry for classifier/context_scorer.json (one number,
    /// two homes — the bundled file is the emitted artifact byte-for-byte).
    private static let expectedSHA256 =
        "fecd89b6a790d9895e7081e99b448d9245096aa435e2389252f7c5f5eab2acb8"

    /// Supported wire versions; a version outside the range falls back to identity.
    static let supportedVersions: ClosedRange<Int> = 1...1

    /// The identity scorer: no families ⇒ every learnedContextLogit is 0.
    static let identity = ContextScorerWeights(families: [:])

    private init(families: [String: FamilyWire]) {
        self.families = families
    }

    /// Load from the RedactionEngine bundle; whole-scorer identity on any problem.
    static func loadFromEngineBundle() -> ContextScorerWeights {
        load(from: .module)
    }

    static func load(from bundle: Bundle) -> ContextScorerWeights {
        guard let url = bundle.url(
            forResource: "context-scorer",
            withExtension: "json",
            subdirectory: "Classifier"
        ) else {
            logger.info("context-scorer.json not bundled; using identity scorer")
            return .identity
        }
        do {  // LegalPhrases:safe — Swift error-handling keyword, not a claim.
            let data = try Data(contentsOf: url)
            return make(from: data, verifyingHash: expectedSHA256)
        } catch {  // LegalPhrases:safe — Swift error-handling keyword, not a claim.
            logger.warning(
                "context-scorer.json unreadable; using identity scorer (metadata: \(error.localizedDescription, privacy: .public))"
            )
            return .identity
        }
    }

    /// Decode + validate raw bytes into a scorer, or the identity scorer on any
    /// problem. `verifyingHash` is the compiled-in SHA-256 self-check (pass nil
    /// to skip it — tests exercise the decode/version/arity paths that way).
    static func make(from data: Data, verifyingHash expected: String?) -> ContextScorerWeights {
        if let expected {
            var hasher = SHA256()
            hasher.update(data: data)
            let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard hex == expected else {
                logger.warning("context-scorer.json hash mismatch; using identity scorer")
                return .identity
            }
        }
        do {  // LegalPhrases:safe — Swift error-handling keyword, not a claim.
            let decoded = try JSONDecoder().decode(WireFormat.self, from: data)
            try LoaderVersionFence.assert(
                actual: decoded.version,
                supported: supportedVersions,
                assetName: "context-scorer",
                logger: logger,
                throwing: { actual, range in LoadError.unsupportedVersion(actual, range) }
            )
            guard decoded.featureOrder == ContextFeatureContract.featureOrder else {
                logger.warning("context-scorer.json feature_order drift; using identity scorer")
                return .identity
            }
            let width = decoded.featureOrder.count
            for (name, family) in decoded.families {
                guard family.weights.count == width,
                      family.featureMeans.count == width,
                      family.featureScales.count == width else {
                    logger.warning(
                        "context-scorer.json family \(name, privacy: .public) arity mismatch; using identity scorer"
                    )
                    return .identity
                }
                guard family.featureScales.allSatisfy({ $0 > 0 }) else {
                    logger.warning(
                        "context-scorer.json family \(name, privacy: .public) non-positive scale; using identity scorer"
                    )
                    return .identity
                }
            }
            return ContextScorerWeights(families: decoded.families)
        } catch {  // LegalPhrases:safe — Swift error-handling keyword, not a claim.
            logger.warning(
                "context-scorer.json decode problem; using identity scorer (metadata: \(error.localizedDescription, privacy: .public))"
            )
            return .identity
        }
    }

    /// The additive log-odds term for one match: `w_family * (bias + Σ wᵢ·zᵢ)`,
    /// `zᵢ = (featuresᵢ − meansᵢ)/scalesᵢ`. Returns 0 for an unknown family, a
    /// disabled family (`w_family == 0`), or an arity mismatch — so it is exactly
    /// 0 under the B03 placeholder (every family disabled).
    ///
    /// - Parameters:
    ///   - family: the wire-name family (`PresetThresholdVector.wireName(for:)`).
    ///   - features: the 13-vector from `contextFeatures(...)`, positional in
    ///     `ContextFeatureContract.featureOrder` order.
    func learnedContextLogit(family: String, features: [Double]) -> Double {
        guard let block = families[family], block.wFamily != 0 else { return 0 }
        guard features.count == block.weights.count else { return 0 }
        var acc = block.bias
        for i in features.indices {
            let z = (features[i] - block.featureMeans[i]) / block.featureScales[i]  // scales[i] > 0 (loader-checked)
            acc += block.weights[i] * z
        }
        return block.wFamily * acc
    }

    private struct WireFormat: Decodable {
        let version: Int
        let featureOrder: [String]
        let families: [String: FamilyWire]

        enum CodingKeys: String, CodingKey {
            case version
            case featureOrder = "feature_order"
            case families
        }
    }

    private enum LoadError: Error {
        case unsupportedVersion(Int, ClosedRange<Int>)
    }
}
