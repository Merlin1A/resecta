import Testing
@testable import RedactionEngine

// Plan Phase 3 / §6 — CalibratedScorer math.

@Suite("CalibratedScorer")
struct CalibratedScorerTests {

    @Test("Loaded temperature when doctype-temperature.json bundled (post-S5)")
    func loadedTemperature() {
        // doctype-temperature.json ships
        // in Resources/Classifier; default init loads T from the JSON.
        // Identity-case (T=1.0) coverage lives in the explicit-T tests below
        // (softmaxIdentity, neutralPosterior, monotonicComposition,
        // thresholdGate). The cutover triage rewrote this test.
        let scorer = CalibratedScorer()
        #expect(scorer.effectiveTemperature > 0.0)
        #expect(scorer.effectiveTemperature <= 1.0)
    }

    @Test("calibratedSoftmax with T=1 equals regular softmax")
    func softmaxIdentity() {
        let scorer = CalibratedScorer(temperature: 1.0)
        let logits: [DoctypeClass: Double] = [
            .court: 2.0, .medical: 1.0, .financial: 0.5, .foia: 0.0, .generic: -0.5,
        ]
        let softmax = scorer.calibratedSoftmax(logits: logits)
        let sum = softmax.values.reduce(0, +)
        #expect(abs(sum - 1.0) < 1e-9)
        // Primary class has max logit.
        #expect(softmax.max(by: { $0.value < $1.value })?.key == .court)
    }

    @Test("posterior(0.5, 0.5) == 0.5")
    func neutralPosterior() {
        let scorer = CalibratedScorer(temperature: 1.0)
        let p = scorer.posterior(raw: 0.5, priorMean: 0.5)
        #expect(abs(p - 0.5) < 1e-6)
    }

    @Test("High raw + high prior → higher posterior")
    func monotonicComposition() {
        let scorer = CalibratedScorer(temperature: 1.0)
        let weak = scorer.posterior(raw: 0.7, priorMean: 0.5)
        let strong = scorer.posterior(raw: 0.7, priorMean: 0.9)
        #expect(strong > weak)
    }

    @Test("Threshold gate returns true when posterior meets threshold")
    func thresholdGate() {
        let scorer = CalibratedScorer(temperature: 1.0)
        #expect(scorer.meets(threshold: 0.7, posterior: 0.75))
        #expect(!scorer.meets(threshold: 0.7, posterior: 0.65))
    }

    // MARK: - S7 / design 03 §3.6 — absorbing-state floor

    @Test("Floored prior rescues account raw max at balanced (design math pin)")
    func absorbingStateFloorRescuesAccountAtBalanced() {
        // The design's recomputed account-at-balanced vector: raw max 0.75,
        // floor 0.35 → posterior ≈ 0.618 > 0.60 balanced. The unfloored
        // worst case (mixture mean after 5 rejections ≈ 0.161 → ≈ 0.366)
        // stays below the threshold, which is exactly the absorbing state
        // the floor removes.
        let scorer = CalibratedScorer(temperature: 1.0)

        let floored = scorer.posterior(raw: 0.75, priorMean: DetectionOrchestrator.absorbingStateFloor)
        #expect(abs(floored - 0.618) < 0.005, "design math pin: got \(floored)")
        #expect(floored > 0.60, "floored account raw-max must clear balanced")

        let unfloored = scorer.posterior(raw: 0.75, priorMean: 0.161)
        #expect(unfloored < 0.60, "unfloored worst case stays absorbed: \(unfloored)")

        #expect(DetectionOrchestrator.absorbingStateFloor == 0.35,
                "shipped floor value is the Jesse-decided 0.35")
    }

    @Test("Five consecutive rejections then floor: posterior clears balanced")
    func fiveRejectionStreakWithFloorClearsBalanced() {
        // End-to-end over the live PerCategoryPriors type: 5 rejections from
        // Beta(1,1) drive the mixture mean to ≈ 0.161; the orchestrator call
        // site composes max(mean, floor) before posterior.
        var priors = PerCategoryPriors()
        for _ in 0..<5 {
            priors = priors.updated(category: .account, decision: .rejected)
        }
        let mean = priors.mean(.account)
        #expect(abs(mean - 0.161) < 0.005, "post-streak mixture mean: got \(mean)")

        // Streak limit: a 6th rejection is dropped (no further drift).
        let sixth = priors.updated(category: .account, decision: .rejected)
        #expect(sixth == priors, "6th same-direction update must be dropped")

        let scorer = CalibratedScorer(temperature: 1.0)
        let effectivePrior = max(mean, DetectionOrchestrator.absorbingStateFloor)
        let posterior = scorer.posterior(raw: 0.75, priorMean: effectivePrior)
        #expect(posterior > 0.60,
                "account raw max must resurface at balanced after the floor: \(posterior)")
    }

    // MARK: - SRCH-S2 D02-scorer-posterior-F1/F2 — under-redaction raw-bar floor
    //
    // The learned context term collapses a structurally-valid, keyword-confirmed
    // account/phone below the gate on one length/separator feature. The
    // ContextPosteriorFloor raw-bar form (DESIGN-DECISIONS DQ2) re-floors a match
    // whose raw cleared 0.70 to its CONSERVATIVE-preset cutoff, capped at raw.
    // CORRECTED cutoffs (the proposals said 0.55/0.70/0.85 — WRONG): shipped
    // 28921a52 is account 0.01/0.6/0.7 and phone 0.55/0.7/0.75.

    @Test("Unfloored: a separator-less, no-keyword phone collapses to ≈ 0.0006")
    func phoneUnflooredCollapses() {
        let scorer = CalibratedScorer(temperature: 1.0)
        // contextLogit computed from the shipped fecd89b6 phone weights for a
        // separator-less / no-keyword / generic / mid-line phone — the standardized
        // has_separator term (≈ −7.43) dominates. Drives a valid raw 0.60 phone to
        // the measured ≈ 0.0006 (the under-redaction bug this floor mitigates).
        let barePhoneContextLogit = -7.829
        let unfloored = scorer.posterior(raw: 0.60, priorMean: 0.5, contextLogit: barePhoneContextLogit)
        #expect(abs(unfloored - 0.0006) < 0.0002, "measured collapse: \(unfloored)")
    }

    @Test("Post-floor: keyword-confirmed phone AND account survive every preset (one raw-bar helper)")
    func flooredPhoneAndAccountSurvive() {
        // DQ2 §453 — the single raw-bar helper satisfies BOTH families.
        // Phone: raw 0.80 → min(0.80, 0.75) = 0.75 → survives 0.55 / 0.7 / 0.75.
        let phone = ContextPosteriorFloor.apply(0.0006, family: "phone", raw: 0.80, conservativeCutoff: 0.75)
        #expect(abs(phone - 0.75) < 1e-9, "phone floors to 0.75; got \(phone)")
        for cutoff in [0.55, 0.7, 0.75] { #expect(phone >= cutoff) }
        // Account: raw 0.75 → min(0.75, 0.7) = 0.7 → survives 0.01 / 0.6 / 0.7.
        let account = ContextPosteriorFloor.apply(0.0006, family: "account", raw: 0.75, conservativeCutoff: 0.7)
        #expect(abs(account - 0.7) < 1e-9, "account floors to 0.7; got \(account)")
        for cutoff in [0.01, 0.6, 0.7] { #expect(account >= cutoff) }
    }

    @Test("With-separator phone is unchanged by the floor (no corpus-norm regression)")
    func withSeparatorPhoneUnchangedByFloor() {
        // A separator-bearing phone keeps a strong posterior; the floor's max is a
        // no-op, so the corpus-normal case is byte-for-byte unchanged.
        let strong = 0.93
        #expect(ContextPosteriorFloor.apply(strong, family: "phone", raw: 0.80, conservativeCutoff: 0.75) == strong)
    }

    @Test("Bare no-keyword phone (raw 0.60) stays dropped — below the 0.70 keyword bar")
    func bareNoKeywordPhoneStaysDropped() {
        // The P2 slice the floor closes is the KEYWORD-CONFIRMED separator-less phone
        // (raw boosted to 0.80). A truly bare phone (raw 0.60, no keyword) is below
        // keywordConfirmedRaw, so the floor does NOT re-admit it — it stays dropped.
        let floored = ContextPosteriorFloor.apply(0.0006, family: "phone", raw: 0.60, conservativeCutoff: 0.75)
        #expect(floored == 0.0006)
        for cutoff in [0.55, 0.7, 0.75] { #expect(floored < cutoff) }
    }
}
