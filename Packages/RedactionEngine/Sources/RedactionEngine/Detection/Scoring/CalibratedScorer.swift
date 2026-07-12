import Foundation
import OSLog

// Plan Stage 0 + Stage 6 — temperature scaling of doctype softmax and
// posterior composition of raw detection scores with prior beliefs.
//
// Temperature source: `Resources/Classifier/doctype-temperature.json`
// (Phase-3b output from DataPipeline `make calibrate-temperature`).
// Missing or malformed JSON → identity (T = 1.0). This is a graceful
// degradation — Stage 0 rankings are preserved, Stage 6 still composes
// prior with raw score.
//
// Schema (minimal, keys are DoctypeClass rawValue):
//   { "version": 1, "temperature": 1.23 }
// The implementation ignores other fields.

public struct CalibratedScorer: Sendable {

    private static let logger = Logger(subsystem: "resecta.engine", category: "calibrated-scorer")

    /// Single scalar temperature applied to all five classes. Future work
    /// (per DataPipeline CLAUDE.md §2.4) may move to per-class vector
    /// temperature; schema leaves room.
    private let temperature: Double

    public init() {
        self.temperature = Self.loadTemperature(from: .module)
    }

    /// Testing init — inject a bundle.
    init(bundle: Bundle) {
        self.temperature = Self.loadTemperature(from: bundle)
    }

    /// Direct-inject init (tests).
    init(temperature: Double) {
        self.temperature = temperature > 0 ? temperature : 1.0
    }

    /// Apply calibrated softmax: divide logits by T, then softmax. When T =
    /// 1 this is the identity of the regular softmax.
    public func calibratedSoftmax(logits: [DoctypeClass: Double]) -> [DoctypeClass: Double] {
        guard !logits.isEmpty else { return [:] }
        let scaled = logits.mapValues { $0 / temperature }
        let maxVal = scaled.values.max() ?? 0
        let exps = scaled.mapValues { exp($0 - maxVal) }
        let sum = exps.values.reduce(0, +)
        guard sum > 0 else { return logits.mapValues { _ in 1.0 / Double(logits.count) } }
        return exps.mapValues { $0 / sum }
    }

    /// Posterior = σ(logit(raw) + logit(prior) + contextLogit). A calibrated
    /// Bayesian update that preserves the raw detector signal while anchoring
    /// toward what the user's history says about this category. `contextLogit`
    /// is the C1 augment term (the learned context log-odds); it defaults to 0,
    /// so every existing caller and the w=0 placeholder path are unchanged.
    public func posterior(raw: Double, priorMean: Double, contextLogit: Double = 0) -> Double {
        let combined = Logit.logit(raw) + Logit.logit(priorMean) + contextLogit
        return Logit.sigmoid(combined)
    }

    /// Threshold comparison shim. Kept trivial so callers can swap in
    /// custom policy without reshaping the return type.
    public func meets(threshold: Double, posterior: Double) -> Bool {
        posterior >= threshold
    }

    public var effectiveTemperature: Double { temperature }

    // MARK: - Loader

    private static func loadTemperature(from bundle: Bundle) -> Double {
        guard let url = bundle.url(
            forResource: "doctype-temperature",
            withExtension: "json",
            subdirectory: "Classifier"
        ) else {
            Self.logger.info("doctype-temperature.json not bundled; using identity T=1.0")
            return 1.0
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(TemperaturePayload.self, from: data)
            guard decoded.temperature.isFinite, decoded.temperature > 0 else {
                Self.logger.warning("doctype-temperature.json has non-positive/NaN T; using identity")
                return 1.0
            }
            return decoded.temperature
        } catch {
            Self.logger.warning("doctype-temperature.json unreadable; using identity (metadata: \(error.localizedDescription, privacy: .public))")
            return 1.0
        }
    }

    private struct TemperaturePayload: Decodable {
        let version: Int
        let temperature: Double
    }
}
