import Testing
@testable import RedactionEngine

// Plan Phase 3 / §2 / G10 — PerCategoryPriors invariants.

@Suite("PerCategoryPriors (G10 hardening)")
struct PerCategoryPriorsTests {

    @Test("Empty prior has mean 0.5")
    func emptyMean() {
        let priors = PerCategoryPriors()
        #expect(priors.mean(.ssn) == 0.5)
    }

    @Test("Accept bumps mean toward 1; reject toward 0")
    func updateDirection() {
        let priors = PerCategoryPriors()
        let afterAccept = priors.updated(category: .ssn, decision: .accepted)
        let afterReject = priors.updated(category: .ssn, decision: .rejected)
        #expect(afterAccept.mean(.ssn) > 0.5)
        #expect(afterReject.mean(.ssn) < 0.5)
    }

    @Test("Alpha floor ≥ 1.0 after successive rejects")
    func alphaFloor() {
        var priors = PerCategoryPriors()
        for _ in 0..<10 {
            priors = priors.updated(category: .name, decision: .rejected)
        }
        let beta = priors.byCategory[.name]!
        #expect(beta.alpha >= 1.0)
    }

    @Test("Streak limit drops updates after 5 consecutive same-direction")
    func streakLimit() {
        var priors = PerCategoryPriors()
        for _ in 0..<20 {
            priors = priors.updated(category: .npi, decision: .accepted)
        }
        // After 5 accepts, further accepts are dropped; α should be ≤ 1 + 5 = 6.
        let beta = priors.byCategory[.npi]!
        #expect(beta.alpha <= 6.0)
    }

    @Test("ESS cap prevents α+β from exceeding 50")
    func essCap() {
        var priors = PerCategoryPriors()
        // Alternate decisions to bypass the streak limit; keep both arms growing.
        for i in 0..<100 {
            priors = priors.updated(
                category: .dea,
                decision: i % 2 == 0 ? .accepted : .rejected
            )
        }
        let beta = priors.byCategory[.dea]!
        #expect(beta.alpha + beta.beta <= 50.0 + 1e-6)
    }

    @Test("Mixture mean stays bounded away from extremes")
    func mixtureBounds() {
        var priors = PerCategoryPriors()
        for _ in 0..<5 {
            priors = priors.updated(category: .dea, decision: .accepted)
        }
        // Even after 5 accepts, mixture keeps mean below 1.
        #expect(priors.mean(.dea) < 1.0)
        #expect(priors.mean(.dea) > 0.5)
    }

    @Test("Merge is commutative on commutative inputs")
    func mergeCommutative() {
        var a = PerCategoryPriors()
        a = a.updated(category: .ssn, decision: .accepted)
        a = a.updated(category: .ssn, decision: .accepted)

        var b = PerCategoryPriors()
        b = b.updated(category: .ssn, decision: .rejected)

        let ab = a.merged(b)
        let ba = b.merged(a)

        let abBeta = ab.byCategory[.ssn]!
        let baBeta = ba.byCategory[.ssn]!
        #expect(abs(abBeta.alpha - baBeta.alpha) < 1e-9)
        #expect(abs(abBeta.beta - baBeta.beta) < 1e-9)
    }
}
