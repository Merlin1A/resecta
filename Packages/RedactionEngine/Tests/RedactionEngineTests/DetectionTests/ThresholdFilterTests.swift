import Testing
import Foundation
@testable import RedactionEngine

// W4 — threshold post-filter for the search path.
//
// Validates the five behaviors that DocumentSearcher relies on:
//   1. nil vector → full pass-through (back-compat)
//   2. calibration category, score < cutoff → dropped
//   3. calibration category, score ≥ cutoff → kept, rationale annotated
//   4. non-calibration category (no wire-name) → kept unchanged
//   5. vector missing entry for a calibration category → kept unchanged

@Suite("ThresholdFilter (W4)")
struct ThresholdFilterTests {

    // MARK: - Fixtures

    private func rationale(ruleID: String, score: Double) -> MatchRationale {
        MatchRationale(
            ruleID: ruleID,
            signals: [.regexPattern(name: ruleID)],
            preThresholdScore: score,
            finalScore: score
        )
    }

    private func match(
        _ kind: RedactionRegion.PIIKind,
        confidence: Double,
        text: String = "sample",
        rationale: MatchRationale? = nil
    ) -> PIIDetector.PIIMatch {
        PIIDetector.PIIMatch(
            text: text,
            range: NSRange(location: 0, length: text.count),
            kind: kind,
            confidence: confidence,
            rationale: rationale
        )
    }

    // MARK: - Tests

    @Test("Nil vector passes every match through unchanged")
    func nilVectorIsNoOp() {
        let matches: [PIIDetector.PIIMatch] = [
            match(.ssn, confidence: 0.50, rationale: rationale(ruleID: "ssn.state-machine", score: 0.50)),
            match(.name, confidence: 0.70, rationale: rationale(ruleID: "name.nltagger", score: 0.70)),
            match(.email, confidence: 0.90, rationale: rationale(ruleID: "email.regex", score: 0.90)),
        ]
        let filtered = matches.applying(thresholdVector: nil)
        #expect(filtered.count == 3)
        // Rationale still carries no appliedThreshold.
        for m in filtered {
            #expect(m.rationale?.appliedThreshold == nil)
        }
    }

    @Test("Below-cutoff calibration match is dropped")
    func belowCutoffIsDropped() {
        let vector = PresetThresholdVector(thresholdsByWireName: ["ssn": 0.80])
        let matches = [match(.ssn, confidence: 0.72,
                             rationale: rationale(ruleID: "ssn.state-machine", score: 0.72))]
        let filtered = matches.applying(thresholdVector: vector)
        #expect(filtered.isEmpty)
    }

    @Test("At-or-above-cutoff match survives with annotated rationale")
    func survivorGetsAnnotation() {
        let vector = PresetThresholdVector(thresholdsByWireName: ["name": 0.70])
        let matches = [match(.name, confidence: 0.85,
                             rationale: rationale(ruleID: "name.nltagger", score: 0.85))]
        let filtered = matches.applying(thresholdVector: vector)
        #expect(filtered.count == 1)
        let survivor = try! #require(filtered.first)
        let annotated = try! #require(survivor.rationale)
        #expect(annotated.appliedThreshold == 0.70)
        #expect(annotated.signals.contains(.presetThresholdPass(raw: 0.85, cutoff: 0.70)))
        // Original regex signal preserved.
        #expect(annotated.signals.contains(.regexPattern(name: "name.nltagger")))
    }

    @Test("Category absent from vector passes through untouched")
    func nonCalibrationIsUntouched() {
        // Vector only has ssn/name; the email threshold is absent from this vector
        // (note: email does have a wire name as of S3, but the vector omits it).
        let vector = PresetThresholdVector(
            thresholdsByWireName: ["ssn": 0.80, "name": 0.70])
        let emailRationale = rationale(ruleID: "email.regex", score: 0.60)
        let matches = [match(.email, confidence: 0.60, rationale: emailRationale)]
        let filtered = matches.applying(thresholdVector: vector)
        #expect(filtered.count == 1)
        let survivor = try! #require(filtered.first?.rationale)
        #expect(survivor.appliedThreshold == nil)
        #expect(!survivor.signals.contains(where: {
            if case .presetThresholdPass = $0 { return true }
            return false
        }))
    }

    @Test("Vector with no entry for a calibration category passes it through")
    func missingWireNameIsNoGate() {
        // Vector has ssn only; name is calibration-eligible but absent here.
        let vector = PresetThresholdVector(thresholdsByWireName: ["ssn": 0.80])
        let matches = [match(.name, confidence: 0.40,
                             rationale: rationale(ruleID: "name.nltagger", score: 0.40))]
        let filtered = matches.applying(thresholdVector: vector)
        #expect(filtered.count == 1)
        #expect(filtered.first?.rationale?.appliedThreshold == nil)
    }

    @Test("Match with nil rationale still passes when above threshold")
    func nilRationaleSurvivorIsUnannotated() {
        let vector = PresetThresholdVector(thresholdsByWireName: ["ssn": 0.50])
        // No rationale — PIIDetector's ensureRationales would normally backfill,
        // but the filter must tolerate absent rationales for robustness.
        let matches = [match(.ssn, confidence: 0.90, rationale: nil)]
        let filtered = matches.applying(thresholdVector: vector)
        #expect(filtered.count == 1)
        #expect(filtered.first?.rationale == nil)
    }

    @Test("Mixed matches: drop below, keep above, pass-through non-calibration")
    func mixedMatchesRespectAllRules() {
        let vector = PresetThresholdVector(
            thresholdsByWireName: ["ssn": 0.80, "name": 0.70])
        let matches = [
            match(.ssn, confidence: 0.72,
                  rationale: rationale(ruleID: "ssn.state-machine", score: 0.72)),  // drop
            match(.name, confidence: 0.85,
                  rationale: rationale(ruleID: "name.nltagger", score: 0.85)),      // keep
            match(.email, confidence: 0.60,
                  rationale: rationale(ruleID: "email.regex", score: 0.60)),        // pass-through
        ]
        let filtered = matches.applying(thresholdVector: vector)
        #expect(filtered.count == 2)
        // Surviving SSN absent; Name present with annotation; Email pass-through.
        #expect(filtered.contains(where: { $0.kind == .name && $0.rationale?.appliedThreshold == 0.70 }))
        #expect(filtered.contains(where: { $0.kind == .email && $0.rationale?.appliedThreshold == nil }))
        #expect(!filtered.contains(where: { $0.kind == .ssn }))
    }

    // MARK: - D06-F2 Part 1: applyingCountingDrops (parity + drop count)

    @Test("applyingCountingDrops survivor output equals applying(thresholdVector:)")
    func countingDropsParityWithApplying() {
        let vector = PresetThresholdVector(
            thresholdsByWireName: ["ssn": 0.80, "name": 0.70])
        let matches = [
            match(.ssn, confidence: 0.72,
                  rationale: rationale(ruleID: "ssn.state-machine", score: 0.72)),  // drop
            match(.name, confidence: 0.85,
                  rationale: rationale(ruleID: "name.nltagger", score: 0.85)),      // keep + annotate
            match(.email, confidence: 0.60,
                  rationale: rationale(ruleID: "email.regex", score: 0.60)),        // pass-through
        ]
        let pure = matches.applying(thresholdVector: vector)
        let counted = matches.applyingCountingDrops(thresholdVector: vector)
        // Survivor list is byte-identical to the pure API (the only added behavior
        // is the drop tally).
        #expect(counted.survivors.count == pure.count)
        for (a, b) in zip(counted.survivors, pure) {
            #expect(a.kind == b.kind)
            #expect(a.confidence == b.confidence)
            #expect(a.range == b.range)
            #expect(a.rationale?.appliedThreshold == b.rationale?.appliedThreshold)
        }
    }

    @Test("applyingCountingDrops counts exactly the below-cutoff matches")
    func countingDropsCountsBelowCutoff() {
        let vector = PresetThresholdVector(
            thresholdsByWireName: ["ssn": 0.80, "name": 0.70])
        let matches = [
            match(.ssn, confidence: 0.72, rationale: rationale(ruleID: "ssn", score: 0.72)),    // drop
            match(.ssn, confidence: 0.10, rationale: rationale(ruleID: "ssn", score: 0.10)),    // drop
            match(.name, confidence: 0.85, rationale: rationale(ruleID: "name", score: 0.85)),  // keep
            match(.email, confidence: 0.20, rationale: rationale(ruleID: "email", score: 0.20)),// no-gate pass
        ]
        let counted = matches.applyingCountingDrops(thresholdVector: vector)
        #expect(counted.droppedBelowThreshold == 2)
        #expect(counted.survivors.count == 2)
    }

    @Test("applyingCountingDrops: nil vector is a no-op with zero drops")
    func countingDropsNilVectorIsNoOp() {
        let matches = [match(.ssn, confidence: 0.10,
                             rationale: rationale(ruleID: "ssn", score: 0.10))]
        let counted = matches.applyingCountingDrops(thresholdVector: nil)
        #expect(counted.survivors.count == 1)
        #expect(counted.droppedBelowThreshold == 0)
    }

    @Test("applyingCountingDrops: no-gate categories pass through and are not counted")
    func countingDropsNoGateNotCounted() {
        // Vector has ssn only: email has no entry (no gate) and name's key is
        // absent (no gate). Both pass through; neither counts as below-threshold
        // even though their confidences are tiny.
        let vector = PresetThresholdVector(thresholdsByWireName: ["ssn": 0.80])
        let matches = [
            match(.email, confidence: 0.05, rationale: rationale(ruleID: "email", score: 0.05)),
            match(.name, confidence: 0.05, rationale: rationale(ruleID: "name", score: 0.05)),
        ]
        let counted = matches.applyingCountingDrops(thresholdVector: vector)
        #expect(counted.droppedBelowThreshold == 0)
        #expect(counted.survivors.count == 2)
    }
}
