import Foundation

// Per-category Beta priors threaded into detection scoring.
// Sendable value type. Priors update on triage accept/reject (never during
// detection). Passed by value into @concurrent `detectPage`.
//
// G10 hardening invariants (defend against prior poisoning on adversarial
// streams):
//   • α ≥ 1.0 floor (never let the accept arm collapse to zero).
//   • α + β ≤ 50 ESS cap (scaled proportionally when exceeded; prevents a
//     long session from making priors unmoveable).
//   • ≤ 5 consecutive same-direction updates (streak limit; further updates
//     in the same direction are dropped until direction changes).
//   • 0.95 · Beta + 0.05 · Uniform mixture at read-time (keeps the mean
//     from ever pinning to the extremes).
//
// Default mean (no observations) = 0.5 (maximally uncertain).

public enum Decision: Sendable, Equatable {
    case accepted
    case rejected
}

public struct PerCategoryPriors: Sendable, Equatable {

    public struct Beta: Sendable, Equatable {
        public var alpha: Double
        public var beta: Double
        /// +1 = accepts; -1 = rejects; 0 = no history yet.
        public var streakDir: Int8
        public var streakLen: UInt8

        public init(alpha: Double = 1.0, beta: Double = 1.0, streakDir: Int8 = 0, streakLen: UInt8 = 0) {
            self.alpha = max(1.0, alpha)
            self.beta = max(1.0, beta)
            self.streakDir = streakDir
            self.streakLen = streakLen
        }

        static let initial = Beta()
    }

    /// Per-category Beta observations. Missing categories default to the
    /// uniform Beta(1, 1) prior — mean 0.5.
    public var byCategory: [PIICategory: Beta]

    public init(byCategory: [PIICategory: Beta] = [:]) {
        self.byCategory = byCategory
    }

    /// Posterior mean under the 0.95·Beta + 0.05·Uniform mixture.
    public func mean(_ category: PIICategory) -> Double {
        guard let beta = byCategory[category] else { return 0.5 }
        let betaMean = beta.alpha / (beta.alpha + beta.beta)
        return 0.95 * betaMean + 0.05 * 0.5
    }

    /// Return a new priors value with the decision applied to the given
    /// category. Enforces all G10 invariants.
    public func updated(category: PIICategory, decision: Decision) -> PerCategoryPriors {
        var current = byCategory[category] ?? .initial
        let dir: Int8 = decision == .accepted ? 1 : -1

        // Streak limit: if same direction for ≥5 consecutive, drop this update.
        if current.streakDir == dir && current.streakLen >= 5 {
            return self
        }

        switch decision {
        case .accepted: current.alpha += 1
        case .rejected: current.beta += 1
        }

        // ESS cap: if α+β exceeds 50, scale both down proportionally so
        // further updates retain influence.
        let total = current.alpha + current.beta
        if total > 50 {
            let scale = 50 / total
            current.alpha = max(1.0, current.alpha * scale)
            current.beta = max(1.0, current.beta * scale)
        }

        // Streak accounting.
        if current.streakDir == dir {
            current.streakLen = min(255, current.streakLen + 1)
        } else {
            current.streakDir = dir
            current.streakLen = 1
        }

        var updated = byCategory
        updated[category] = current
        return PerCategoryPriors(byCategory: updated)
    }
}
