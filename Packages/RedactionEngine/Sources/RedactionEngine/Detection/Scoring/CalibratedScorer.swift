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

    /// Posterior = σ(logit(raw) + logit(prior) + contextLogit). A calibrated
    /// Bayesian update that preserves the raw detector signal while anchoring
    /// toward what the user's history says about this category. `contextLogit`
    /// is the C1 augment term (the learned context log-odds); it defaults to 0,
    /// so every existing caller and the w=0 placeholder path are unchanged.
    public func posterior(raw: Double, priorMean: Double, contextLogit: Double = 0) -> Double {
        let combined = Logit.logit(raw) + Logit.logit(priorMean) + contextLogit
        return Logit.sigmoid(combined)
    }

    // MARK: - Loader

    private static func loadTemperature(from bundle: Bundle) -> Double {
        loadTemperatureWithDiagnostics(from: bundle).temperature
    }

    /// SEC-7 diagnostics variant: the temperature plus, on any fallback to the
    /// identity T=1.0, a mechanism-only reason string.
    /// `PIIDetector.loadWithDiagnostics(bundle:)` folds the reason into
    /// `GazetteerLoadDiagnostics` so the fallback surfaces through the existing
    /// degrade banner; the fallback value itself is unchanged.
    static func loadTemperatureWithDiagnostics(from bundle: Bundle)
        -> (temperature: Double, failureReason: String?)
    {
        guard let url = bundle.url(
            forResource: "doctype-temperature",
            withExtension: "json",
            subdirectory: "Classifier"
        ) else {
            Self.logger.info("doctype-temperature.json not bundled; using identity T=1.0")
            return (1.0, "doctype-temperature.json not bundled")
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(TemperaturePayload.self, from: data)
            guard decoded.temperature.isFinite, decoded.temperature > 0 else {
                Self.logger.warning("doctype-temperature.json has non-positive/NaN T; using identity")
                return (1.0, "doctype-temperature.json has non-positive/NaN T")
            }
            return (decoded.temperature, nil)
        } catch {
            Self.logger.warning("doctype-temperature.json unreadable; using identity (metadata: \(error.localizedDescription, privacy: .public))")
            return (1.0, "doctype-temperature.json unreadable: \(error.localizedDescription)")
        }
    }

    private struct TemperaturePayload: Decodable {
        let version: Int
        let temperature: Double
    }
}
