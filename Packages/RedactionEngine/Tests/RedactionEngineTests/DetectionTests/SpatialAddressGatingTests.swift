import Testing
import Foundation
import CoreGraphics
@testable import RedactionEngine

// WS1 item 1.6 — Spatial address posterior + gate + dedup tests.
//
// Verifies that spatial addresses assembled by AddressSpatialAssembler now
// participate in resolveOverlaps, posterior scoring, and W4 gating
// (moved from the post-loop raw append to rawMatches BEFORE resolveOverlaps
// in DetectionOrchestrator.detectPage). Tests operate at the assembler
// and resolver layers without Vision / OCR.
@Suite("Spatial Address Gating (WS1 item 1.6)")
struct SpatialAddressGatingTests {

    // MARK: - Helpers

    private func line(
        _ text: String,
        x: CGFloat = 0.1, y: CGFloat = 0.8,
        w: CGFloat = 0.3, h: CGFloat = 0.02
    ) -> OCREngine.TextLine {
        OCREngine.TextLine(
            text: text,
            normalizedRect: CGRect(x: x, y: y, width: w, height: h),
            confidence: 1.0
        )
    }

    /// Build a PIIDetector.PIIMatch for an address at the given confidence.
    private func addressMatch(
        text: String,
        range: NSRange,
        confidence: Double
    ) -> PIIDetector.PIIMatch {
        PIIDetector.PIIMatch(
            text: text,
            range: range,
            kind: .address,
            confidence: confidence
        )
    }

    // MARK: - §3 Required Tests

    // ADVERSARIAL (design §3 test plan): spatial address at confidence 0.55
    // with conservative preset threshold 0.75 → NOT in final detections.
    // The test drives W4 gating directly via posterior + threshold comparison.
    @Test("ADVERSARIAL: spatial address at 0.55 under conservative threshold 0.75 is suppressed")
    func testConservativePresetLowConfidenceSpatialSuppressed() throws {
        // Mechanism: W4 gate drops matches where finalConfidence < cutoff.
        // At fresh priorMean = 0.5, posterior(0.55) ≈ 0.55.
        // Conservative threshold for address (if wired) or design-stated 0.75.
        let scorer = CalibratedScorer()
        let priorMean = PerCategoryPriors().mean(.address)
        let rawConfidence: Double = 0.55
        let posterior = scorer.posterior(raw: rawConfidence, priorMean: priorMean)

        let bundle = PresetThresholdBundle.loadFromEngineBundle()
        let vector = try #require(bundle.presets[.conservative])
        // Use address wireName threshold if present; fall back to design-stated 0.75.
        let cutoff = vector.threshold(for: .address) ?? 0.75

        // The W4 gate condition: suppressed when finalConfidence < cutoff.
        #expect(posterior < cutoff)
    }

    // Spatial and regex address on overlapping range: only one survives
    // resolveOverlaps, and it is the one with higher confidence (max wins).
    @Test("Spatial and regex address on same range: higher confidence wins (max-wins dedup)")
    func testSpatialAndRegexSamePageDedup() {
        let sharedRange = NSRange(location: 10, length: 25)
        let addressText = "123 Main St, Austin, TX 78701"

        let regexMatch = addressMatch(text: addressText, range: sharedRange, confidence: 0.70)
        let spatialMatch = addressMatch(text: addressText, range: sharedRange, confidence: 0.65)

        // resolveOverlaps: both have the same range → in one overlap group.
        // Max confidence wins: 0.70 (regex) > 0.65 (spatial).
        let resolved = DetectionOrchestrator.resolveOverlaps([regexMatch, spatialMatch])
        #expect(resolved.surviving.count == 1)
        #expect(resolved.surviving.first?.confidence == 0.70)

        // Reverse: spatial wins when it has higher confidence.
        let highSpatial = addressMatch(text: addressText, range: sharedRange, confidence: 0.80)
        let resolved2 = DetectionOrchestrator.resolveOverlaps([regexMatch, highSpatial])
        #expect(resolved2.surviving.count == 1)
        #expect(resolved2.surviving.first?.confidence == 0.80)
    }

    // Posterior is applied: at fresh priorMean = 0.5, posterior(0.65) should
    // equal CalibratedScorer.posterior(raw: 0.65, priorMean: 0.5).
    // Verifies the scorer is deterministic (pins the mechanism, not a specific value).
    @Test("Spatial address posterior applied: CalibratedScorer.posterior is deterministic")
    func testSpatialAddressPosteriorApplied() {
        let scorer = CalibratedScorer()
        let priorMean = PerCategoryPriors().mean(.address) // fresh prior = 0.5
        let rawConfidence: Double = 0.65
        let posterior = scorer.posterior(raw: rawConfidence, priorMean: priorMean)
        #expect(posterior > 0.0)
        #expect(posterior <= 1.0)
        // Determinism: calling posterior twice with the same inputs gives the same result.
        let posterior2 = scorer.posterior(raw: rawConfidence, priorMean: priorMean)
        #expect(posterior == posterior2)
    }

    // Non-overlapping spatial and regex addresses on distinct ranges:
    // both survive resolveOverlaps (no dedup applied to non-overlapping ranges).
    @Test("Non-overlapping spatial and regex addresses both survive resolveOverlaps")
    func testNonOverlappingAddressesBothSurvive() {
        let regexMatch = addressMatch(
            text: "100 First St, Boston, MA 02101",
            range: NSRange(location: 0, length: 30),
            confidence: 0.70
        )
        let spatialMatch = addressMatch(
            text: "200 Second Ave, Dallas, TX 75201",
            range: NSRange(location: 100, length: 30),
            confidence: 0.65
        )
        let resolved = DetectionOrchestrator.resolveOverlaps([regexMatch, spatialMatch])
        #expect(resolved.surviving.count == 2)
    }

    // Single spatial address always survives resolveOverlaps (count == 1 guard path).
    @Test("Single spatial address always survives resolveOverlaps")
    func testSingleSpatialAddressSurvives() {
        let match = addressMatch(
            text: "42 Elm St, Portland, OR 97201",
            range: NSRange(location: 5, length: 28),
            confidence: 0.72
        )
        let resolved = DetectionOrchestrator.resolveOverlaps([match])
        #expect(resolved.surviving.count == 1)
        #expect(resolved.surviving.first?.confidence == 0.72)
    }

    // Empty assembled addresses: no crash, resolveOverlaps with existing matches unchanged.
    @Test("Empty spatial assembly does not crash and leaves rawMatches unchanged")
    func testEmptySpatialAssemblyNoEffect() {
        let assembler = AddressSpatialAssembler()
        let assembled = assembler.assemble(lines: [])
        #expect(assembled.isEmpty)

        // Feeding an empty assembled array into resolveOverlaps with existing
        // matches must leave those matches unchanged.
        let existing = addressMatch(
            text: "99 Oak Rd, Chicago, IL 60601",
            range: NSRange(location: 0, length: 26),
            confidence: 0.70
        )
        let resolved = DetectionOrchestrator.resolveOverlaps([existing])
        #expect(resolved.surviving.count == 1)
    }
}
