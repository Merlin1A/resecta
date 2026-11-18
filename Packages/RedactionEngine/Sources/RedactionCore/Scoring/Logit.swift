import Foundation

// Logit / sigmoid helpers. Used by CalibratedScorer to compose
// `posterior = σ(logit(raw) + logit(prior))`. Clamped away from {0, 1} to
// avoid ±∞.

package enum Logit {
    package static let epsilon: Double = 1e-6

    package static func clamp(_ p: Double) -> Double {
        min(max(p, epsilon), 1 - epsilon)
    }

    package static func logit(_ p: Double) -> Double {
        let clamped = clamp(p)
        return log(clamped / (1 - clamped))
    }

    package static func sigmoid(_ x: Double) -> Double {
        if x >= 0 {
            let e = exp(-x)
            return 1 / (1 + e)
        } else {
            let e = exp(x)
            return e / (1 + e)
        }
    }
}
