import Testing
@testable import RedactionEngine

// Regression guard — name-detection surfacing (root-caused 2026-06-01).
//
// The shipped Balanced preset's `name` posterior cutoff had been 0.98, but the
// NLTagger name detector emits raw confidences in [0.65, 0.85] (PIIDetector
// .runNLTagger: 0.70 base + ≤0.15 gazetteer boost; legal-prefix path 0.65). On
// a fresh document the per-category prior mean is 0.5, so the calibrated
// posterior equals the raw score (sigmoid(logit(raw) + logit(0.5)) == raw). A
// 0.98 cutoff therefore dropped every name in DetectionOrchestrator's W4 gate
// (`finalConfidence < cutoff` → drop), so no name reached the triage surface.
//
// These tests pin the SHIPPED Balanced `name` cutoff inside the detector's
// reachable range so the auto-detect path can surface names for triage.
@Suite("Name threshold surfacing")
struct NameThresholdSurfacingTests {

    /// NLTagger base confidence with no gazetteer boost — the common name case.
    private static let unboostedNameConfidence = 0.70
    /// Max raw confidence a name can reach (0.70 base + 0.15 exact surname+given).
    private static let maxNameConfidence = 0.85

    @Test("Shipped Balanced `name` cutoff leaves headroom for an unboosted name")
    func balancedNameCutoffIsReachable() throws {
        let bundle = PresetThresholdBundle.loadFromEngineBundle()
        let balanced = try #require(
            bundle.presets[.balanced],
            "Balanced preset must be present in the shipped threshold vector"
        )
        let cutoff = try #require(
            balanced.threshold(forWireName: "name"),
            "Balanced preset must carry a `name` cutoff"
        )
        // The cutoff must sit strictly below the unboosted-name confidence, or
        // the W4 gate drops common (gazetteer-unconfirmed) names outright. This
        // is the exact condition that regressed when the cutoff was 0.98.
        #expect(
            cutoff < Self.unboostedNameConfidence,
            "Balanced name cutoff \(cutoff) ≥ unboosted name confidence \(Self.unboostedNameConfidence): names cannot surface (0.98-cutoff regression)"
        )
    }

    @Test("A fresh-prior NLTagger name survives the shipped Balanced gate")
    func freshPriorNameSurvivesBalancedGate() throws {
        let bundle = PresetThresholdBundle.loadFromEngineBundle()
        let cutoff = try #require(bundle.presets[.balanced]?.threshold(forWireName: "name"))

        // Reproduce DetectionOrchestrator.detectPage's W4 gate exactly: compose
        // the raw score against the fresh-document prior, then compare to cutoff.
        let priorMean = PerCategoryPriors().mean(.name) // 0.5 on a fresh document
        let posterior = CalibratedScorer().posterior(
            raw: Self.unboostedNameConfidence, priorMean: priorMean
        )
        // The gate drops when `finalConfidence < cutoff`; the name must survive.
        #expect(
            posterior >= cutoff,
            "Unboosted NLTagger name (posterior \(posterior)) is dropped by Balanced name cutoff \(cutoff)"
        )
    }
}
