import Foundation
import OSLog

// Posterior composition of raw detection scores with prior beliefs.
//
// The doctype softmax temperature file
// (`Resources/Classifier/doctype-temperature.json`, written by the data
// pipeline) is read here only for the startup diagnostics: a missing or
// malformed file reports a reason; no scoring path reads the value.
//
// Schema (minimal):
//   { "version": 1, "temperature": 1.23 }
// The implementation ignores other fields.

struct CalibratedScorer: Sendable {

    private static let logger = Logger(subsystem: "resecta.engine", category: "calibrated-scorer")

    init() {}

    /// Posterior = σ(logit(raw) + logit(prior) + contextLogit). A calibrated
    /// Bayesian update that preserves the raw detector signal while anchoring
    /// toward what the user's history says about this category. `contextLogit`
    /// is the learned context log-odds; it defaults to 0,
    /// so every existing caller and the w=0 placeholder path are unchanged.
    func posterior(raw: Double, priorMean: Double, contextLogit: Double = 0) -> Double {
        let combined = Logit.logit(raw) + Logit.logit(priorMean) + contextLogit
        return Logit.sigmoid(combined)
    }

    // MARK: - Loader

    /// The temperature file's value plus, on any fallback to the
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
            // Wire-version fence: a payload from a future or stale schema
            // falls back to the identity temperature by name.
            try LoaderVersionFence.assert(
                actual: decoded.version,
                supported: supportedWireVersions,
                assetName: "doctype-temperature",
                logger: Self.logger,
                throwing: { LoaderError.unsupportedVersion(actual: $0, supported: $1) }
            )
            guard decoded.temperature.isFinite, decoded.temperature > 0 else {
                Self.logger.warning("doctype-temperature.json has non-positive/NaN T; using identity")
                return (1.0, "doctype-temperature.json has non-positive/NaN T")
            }
            return (decoded.temperature, nil)
        } catch {
            Self.logger.warning("doctype-temperature.json unreadable; using identity (metadata: \(String(describing: error), privacy: .public))")
            return (1.0, "doctype-temperature.json unreadable: \(String(describing: error))")
        }
    }

    /// `TemperaturePayload.version` values this decoder understands
    /// (`DataPipeline/schemas/doctype_temperature.schema.json`).
    static let supportedWireVersions: ClosedRange<Int> = 1...1

    enum LoaderError: Error {
        case unsupportedVersion(actual: Int, supported: ClosedRange<Int>)
    }

    private struct TemperaturePayload: Decodable {
        let version: Int
        let temperature: Double
    }
}
