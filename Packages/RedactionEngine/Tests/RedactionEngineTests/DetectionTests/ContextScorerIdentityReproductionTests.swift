import Foundation
import Testing
@testable import RedactionEngine

// B03/B05 — context-scorer unit-level invariants.
//
// B03 shipped a w=0 placeholder; B05 promoted the trained calibrated scorer
// (account/phone w_family 1, mrn/ein/itin identity). Two invariants are pinned
// here at the unit level:
//   1. The IDENTITY scorer — the loader's fail-open value — contributes exactly 0
//      for every family. A 0 additive term cannot move any finalConfidence, so a
//      hash-mismatch fallback reproduces the bare posterior bit-for-bit. This is
//      the durable kill-switch property, independent of what is bundled.
//   2. The bundled calibrated scorer contributes the trained log-odds for the
//      promoted families (account, phone) and exactly 0 for the w=0 families
//      (mrn, ein, itin) and for unknown / empty wire-names.

@Suite("Context scorer identity + calibrated bundle")
struct ContextScorerIdentityReproductionTests {

    private static let arbitraryFeatures: [Double] =
        [1, 1, 0.8333333333333334, 0.5, 10, 1, 1, 1, 1, 0, 0, 0, 0]

    private static let allFamilies = ["account", "phone", "mrn", "ein", "itin"]
    private static let promotedFamilies = ["account", "phone"]
    private static let zeroFamilies = ["mrn", "ein", "itin"]

    @Test("The identity scorer adds 0 for every family (and unknown families)")
    func identityAddsZero() {
        let scorer = ContextScorerWeights.identity
        for family in Self.allFamilies {
            #expect(scorer.learnedContextLogit(family: family, features: Self.arbitraryFeatures) == 0,
                    "family \(family) must contribute 0 under the identity scorer")
        }
        // An unknown wire-name and the empty-string fallback also add 0.
        #expect(scorer.learnedContextLogit(family: "name", features: Self.arbitraryFeatures) == 0)
        #expect(scorer.learnedContextLogit(family: "", features: Self.arbitraryFeatures) == 0)
    }

    @Test("The bundled calibrated scorer adds the trained term for promoted families, 0 otherwise")
    func calibratedBundleContributions() {
        let scorer = ContextScorerWeights.loadFromEngineBundle()
        for family in Self.promotedFamilies {
            #expect(scorer.learnedContextLogit(family: family, features: Self.arbitraryFeatures) != 0,
                    "promoted family \(family) must contribute a non-zero trained term")
        }
        for family in Self.zeroFamilies {
            #expect(scorer.learnedContextLogit(family: family, features: Self.arbitraryFeatures) == 0,
                    "w=0 family \(family) must contribute 0")
        }
        // Unknown wire-name and the empty-string fallback still add 0.
        #expect(scorer.learnedContextLogit(family: "name", features: Self.arbitraryFeatures) == 0)
        #expect(scorer.learnedContextLogit(family: "", features: Self.arbitraryFeatures) == 0)
    }

    @Test("Seam posterior: a w=0 family matches the bare posterior; a promoted family shifts it")
    func seamPosteriorReflectsPromotion() {
        let scorer = ContextScorerWeights.loadFromEngineBundle()
        let calibrated = CalibratedScorer()
        let raws = [0.05, 0.20, 0.50, 0.75, 0.90]
        let priors = [0.16, 0.35, 0.50, 0.80]
        for raw in raws {
            for prior in priors {
                let bare = calibrated.posterior(raw: raw, priorMean: prior)

                // A w=0 family (mrn) contributes 0 → seam == bare.
                let zeroLogit = scorer.learnedContextLogit(
                    family: "mrn", features: Self.arbitraryFeatures)
                let zeroSeam = calibrated.posterior(
                    raw: raw, priorMean: prior, contextLogit: zeroLogit)
                #expect(zeroSeam == bare, "raw \(raw) prior \(prior): w=0 family must match bare posterior")

                // A promoted family (account, w=1) contributes a non-zero term → seam shifts.
                let trainedLogit = scorer.learnedContextLogit(
                    family: "account", features: Self.arbitraryFeatures)
                let trainedSeam = calibrated.posterior(
                    raw: raw, priorMean: prior, contextLogit: trainedLogit)
                #expect(trainedSeam != bare,
                        "raw \(raw) prior \(prior): promoted family must shift the posterior")
            }
        }
    }
}
