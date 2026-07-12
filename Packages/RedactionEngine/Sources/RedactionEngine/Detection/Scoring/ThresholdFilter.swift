import Foundation

// W4 — preset-threshold post-filter for the search path.
//
// Used by `DocumentSearcher` to gate raw PIIMatches against a
// `PresetThresholdVector` (preset defaults merged with any per-category
// user override) before they reach the UI. Survivors get their rationale
// annotated with the applied cutoff so the MatchRationaleSheet can show
// which threshold the hit cleared.
//
// The orchestrator path (`DetectionOrchestrator.detectPage`) runs a
// posterior-composition step after PIIDetector returns, so it applies
// the threshold inline against `finalConfidence` rather than reusing this
// helper. Keeping the two paths visually distinct is deliberate — the
// searcher filters raw, the orchestrator filters post-posterior.
//
// B06 — Site-B / Search parity: the five scored families
// {account, phone, mrn, ein, itin} no longer reach this raw gate at the
// `DocumentSearcher` call sites. `DocumentSearcher.composedSurvivors(...)`
// composes the SAME posterior + learned-context term the orchestrator applies
// (DetectionOrchestrator.swift:432-446) for those families BEFORE the threshold
// comparison; every OTHER category still flows through `applying(...)` below
// unchanged. `partitionedByScoredFamily()` is the split that routes them.

extension Array where Element == PIIDetector.PIIMatch {
    /// Drop matches whose raw confidence is below the per-category cutoff
    /// in `thresholdVector`. Annotates survivors with `appliedThreshold`
    /// and a `.presetThresholdPass(raw:cutoff:)` signal.
    ///
    /// - Passes through unchanged when `thresholdVector` is nil.
    /// - Passes through unchanged when the match's category has no
    ///   wire-name mapping (non-calibration: email / phone / creditCard /
    ///   ein / itin / driversLicense / passport).
    /// - Passes through unchanged when the vector has no entry for the
    ///   category's wire name (missing key = "no gate for this category").
    func applying(thresholdVector: PresetThresholdVector?) -> [PIIDetector.PIIMatch] {
        guard let vector = thresholdVector else { return self }
        return compactMap { match in
            guard let category = match.category,
                  let cutoff = vector.threshold(for: category)
            else { return match }
            guard match.confidence >= cutoff else { return nil }
            guard let rationale = match.rationale else { return match }
            let annotated = rationale.with(
                appliedThreshold: cutoff,
                addingSignal: .presetThresholdPass(
                    raw: match.confidence, cutoff: cutoff
                )
            )
            return match.withRationale(annotated)
        }
    }

    /// D06-F2 Part 1 — same gate as `applying(thresholdVector:)` but also returns
    /// the number of matches dropped for falling below their per-category cutoff.
    /// Matches with no category / no wire-name / no vector entry pass through and
    /// are NOT counted as below-threshold (no gate is applied to them). The
    /// survivor output is byte-identical to `applying(thresholdVector:)` — the
    /// only added behavior is the drop tally (parity pinned by a unit test).
    func applyingCountingDrops(thresholdVector: PresetThresholdVector?)
        -> (survivors: [PIIDetector.PIIMatch], droppedBelowThreshold: Int) {
        guard let vector = thresholdVector else { return (self, 0) }
        var dropped = 0
        let survivors: [PIIDetector.PIIMatch] = compactMap { match in
            guard let category = match.category,
                  let cutoff = vector.threshold(for: category)
            else { return match }
            guard match.confidence >= cutoff else { dropped += 1; return nil }
            guard let rationale = match.rationale else { return match }
            let annotated = rationale.with(
                appliedThreshold: cutoff,
                addingSignal: .presetThresholdPass(
                    raw: match.confidence, cutoff: cutoff
                )
            )
            return match.withRationale(annotated)
        }
        return (survivors, dropped)
    }

    /// B06 — split the matches into the five scored families
    /// (`ContextFeatureContract.scoredFamilies`, keyed by `wireName(for:)`) and
    /// everything else, each preserving relative order. The scored partition
    /// routes through `DocumentSearcher.composedSurvivors(...)` (posterior +
    /// learned context); the rest keep `applying(thresholdVector:)`. A match
    /// with no category or no wire-name maps to a non-scored family, so it stays
    /// on the raw path — byte-for-byte unchanged.
    func partitionedByScoredFamily() -> (scored: [Element], rest: [Element]) {
        var scored: [Element] = []
        var rest: [Element] = []
        for match in self {
            let family = match.category.flatMap { PresetThresholdVector.wireName(for: $0) }
            if let family, ContextFeatureContract.scoredFamilies.contains(family) {
                scored.append(match)
            } else {
                rest.append(match)
            }
        }
        return (scored, rest)
    }
}
