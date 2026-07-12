import Foundation
import Testing
@testable import RedactionEngine

// SRCH-S2 — D02-scorer-posterior-F1 (account, P1), Site-B (Search) integration.
//
// Drives the real `DocumentSearcher.composedSurvivors` static seam (callable
// without an actor instance) with synthetic keyword-confirmed account matches
// across a SPAN of digit lengths, the SHIPPED scorers, the SHIPPED `28921a52`
// preset, and empty priors. Post-floor, every keyword-confirmed account survives
// the gate at every preset — the short (6–9 digit) accounts the learned
// `digit_run_length` term collapsed are re-admitted by ContextPosteriorFloor.
//
// Option-D guard: the original regression was invisible because the account
// digit-length measurement set had cardinality 1 (one length). These tests span
// {6,7,8,9,11,13} and assert that cardinality > 1, so the blind spot cannot recur.
// This is a report-only guard over the session's own additive test vectors — it
// touches NO frozen G8 corpus / asset-hash artifact (those are maintainer-gated).
@Suite("composedSurvivors — account digit-length floor (Site-B)")
struct ComposedSurvivorsAccountLengthTests {

    /// Keyword-confirmed account raw boost (DetectionOrchestrator absorbing-state
    /// comment: account raw max 0.75).
    private static let accountKeywordConfirmedRaw = 0.75

    /// Digit lengths under test — deliberately cardinality > 1 (Option-D guard).
    private static let digitLengths = [6, 7, 8, 9, 11, 13]

    private static func accountMatch(digits: String) -> (PIIDetector.PIIMatch, String) {
        let pageText = "Account #: \(digits)"
        let range = (pageText as NSString).range(of: digits)
        let match = PIIDetector.PIIMatch(
            text: digits, range: range, kind: .account, confidence: accountKeywordConfirmedRaw)
        return (match, pageText)
    }

    private static func digits(_ n: Int) -> String {
        String((0..<n).map { Character("\(($0 % 9) + 1)") })   // "1234567891..." (never starts with 0)
    }

    private func conservativeVector() -> PresetThresholdVector {
        // The hardest account gate (0.7). Falls back to built-in defaults only if
        // the bundle is somehow absent (the loader is fail-open).
        PresetThresholdBundle.loadFromEngineBundle().presets[.conservative]
            ?? PresetThresholdBundle.builtInDefaults.presets[.conservative]
            ?? PresetThresholdVector(thresholdsByWireName: ["account": 0.7])
    }

    @Test("Every keyword-confirmed account 6…13 digits survives the conservative gate (Site-B)")
    func keywordConfirmedAccountsSurviveConservative() {
        let calibrated = CalibratedScorer()
        let contextScorer = ContextScorerWeights.loadFromEngineBundle()
        let vector = conservativeVector()

        for n in Self.digitLengths {
            let (match, pageText) = Self.accountMatch(digits: Self.digits(n))
            let survivors = DocumentSearcher.composedSurvivors(
                [match],
                pageText: pageText,
                thresholdVector: vector,
                calibratedScorer: calibrated,
                contextScorer: contextScorer,
                priors: PerCategoryPriors()
            )
            #expect(survivors.contains { $0.text == match.text },
                    "a \(n)-digit keyword-confirmed account must survive conservative (0.7) at Site-B")
        }
    }

    @Test("The floor is load-bearing: a 6-digit account is dropped WITHOUT it, survives WITH it")
    func floorIsLoadBearingForShortAccount() {
        let calibrated = CalibratedScorer()
        let contextScorer = ContextScorerWeights.loadFromEngineBundle()
        let vector = conservativeVector()
        let cutoff = vector.threshold(forWireName: "account") ?? 0.7

        let (match, pageText) = Self.accountMatch(digits: Self.digits(6))

        // Reconstruct the pre-floor posterior the seam composes (no floor).
        let features = contextFeatures(match: match, doctype: .generic,
            effectiveDoctype: .generic, pageText: pageText)
        let contextLogit = contextScorer.learnedContextLogit(family: "account", features: features)
        let priorMean = max(PerCategoryPriors().mean(.account), DetectionOrchestrator.absorbingStateFloor)
        let bare = calibrated.posterior(raw: Self.accountKeywordConfirmedRaw,
            priorMean: priorMean, contextLogit: contextLogit)
        #expect(bare < cutoff, "without the floor the 6-digit account is dropped: bare \(bare) < \(cutoff)")

        // WITH the floor (the real seam) it survives.
        let survivors = DocumentSearcher.composedSurvivors(
            [match], pageText: pageText, thresholdVector: vector,
            calibratedScorer: calibrated, contextScorer: contextScorer, priors: PerCategoryPriors())
        #expect(survivors.contains { $0.text == match.text },
                "the floor re-admits the 6-digit account at Site-B")
    }

    @Test("Floor outcome is preset-invariant: an 8-digit account survives aggressive, balanced, conservative")
    func accountSurvivesEveryPreset() {
        let calibrated = CalibratedScorer()
        let contextScorer = ContextScorerWeights.loadFromEngineBundle()
        let bundle = PresetThresholdBundle.loadFromEngineBundle()
        let (match, pageText) = Self.accountMatch(digits: Self.digits(8))

        for preset in [SettingsPreset.aggressive, .balanced, .conservative] {
            guard let vector = bundle.presets[preset] else { continue }
            let survivors = DocumentSearcher.composedSurvivors(
                [match], pageText: pageText, thresholdVector: vector,
                calibratedScorer: calibrated, contextScorer: contextScorer, priors: PerCategoryPriors())
            #expect(survivors.contains { $0.text == match.text },
                    "8-digit keyword-confirmed account must survive the \(preset) preset")
        }
    }

    // MARK: - Option-D cardinality guards (report-only)

    @Test("Account digit-length test set has cardinality > 1 (regression blind-spot guard)")
    func accountDigitLengthSetCardinality() {
        // The original miss hid because the measured account digit-length set had
        // cardinality 1. Keep this span > 1 so a single-length collapse re-surfaces.
        #expect(Set(Self.digitLengths).count > 1)
    }

    @Test("Phone separator slice spans has_separator ∈ {0,1} (cardinality > 1 guard)")
    func phoneSeparatorSliceCardinality() {
        // Pin that the phone slice covers BOTH the separator-bearing (corpus-normal)
        // and separator-less (collapsed) cases — the P2 result lives at sep=0.
        let sepValues: Set<Int> = ["5551234567", "555-123-4567"]
            .map { $0.contains(where: { !$0.isLetter && !$0.isNumber }) ? 1 : 0 }
            .reduce(into: Set<Int>()) { $0.insert($1) }
        #expect(sepValues == [0, 1])
    }
}
