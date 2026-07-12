import Foundation

// Plan §2 / G10 — per-category Beta priors threaded into detection scoring.
// Sendable value type. Priors update on triage accept/reject (never during
// detection). Passed by value into @concurrent `detectPage`; merged back on
// MainActor at yield via `merged(_:)` (commutative).
//
// G10 hardening invariants (defend against prior poisoning on adversarial
// streams — see plan §C):
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

    /// Pointwise merge. Commutative: α's add, β's add, streaks reset on
    /// direction disagreement. Used to fold per-page `priorsDelta` back into
    /// the MainActor instance after `detectPage` yields.
    public func merged(_ other: PerCategoryPriors) -> PerCategoryPriors {
        var result = byCategory
        for (category, otherBeta) in other.byCategory {
            guard let current = result[category] else {
                result[category] = otherBeta
                continue
            }
            // Subtract the shared Beta(1,1) prior once to avoid double-counting.
            let mergedAlpha: Double = current.alpha + (otherBeta.alpha - 1.0)
            let mergedBetaValue: Double = current.beta + (otherBeta.beta - 1.0)
            let dirMatches = current.streakDir == otherBeta.streakDir
            let newDir: Int8 = dirMatches ? current.streakDir : 0
            let newLen: UInt8 = dirMatches ? max(current.streakLen, otherBeta.streakLen) : 0
            var mergedBeta = Beta(
                alpha: mergedAlpha,
                beta: mergedBetaValue,
                streakDir: newDir,
                streakLen: newLen
            )
            // Re-apply ESS cap after merge.
            let total = mergedBeta.alpha + mergedBeta.beta
            if total > 50 {
                let scale = 50 / total
                mergedBeta.alpha = max(1.0, mergedBeta.alpha * scale)
                mergedBeta.beta = max(1.0, mergedBeta.beta * scale)
            }
            result[category] = mergedBeta
        }
        return PerCategoryPriors(byCategory: result)
    }
}
