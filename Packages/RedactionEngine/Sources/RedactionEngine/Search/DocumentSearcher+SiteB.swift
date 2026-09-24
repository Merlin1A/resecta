import Foundation

// The Site-B posterior composition: the search path's gate over the five scored
// families, composing the SAME posterior + learned-context term the detection path
// applies. Moved whole from DocumentSearcher.swift; the composition is never re-derived.

extension DocumentSearcher {

    // MARK: - Site-B posterior composition

    /// Site-B gate for the five scored families, composing the SAME
    /// posterior + learned-context term the detection path applies at
    /// DetectionOrchestrator.swift:432-446 + the posterior threshold gate at :455-460.
    ///
    /// For each match whose category resolves to a vector cutoff:
    ///   finalConfidence = posterior(raw, priorMean, contextLogit)
    ///   priorMean       = max(searchPriors.mean(category), absorbingStateFloor)
    ///   contextLogit    = contextScorer.learnedContextLogit(family:, features:)
    /// and the match survives iff finalConfidence >= cutoff. Survivors get the
    /// identical rationale annotation `ThresholdFilter.applying` writes (the
    /// `.presetThresholdPass(raw:cutoff:)` signal keyed on the RAW confidence,
    /// plus `appliedThreshold`).
    ///
    /// A match with no vector cutoff (nil vector, or no entry for the category's
    /// wire name) passes through unchanged — the same fall-through
    /// `ThresholdFilter.applying` takes, so a non-gated scored family stays
    /// byte-identical to the raw path.
    ///
    /// DOCTYPE: `DocumentSearcher` carries no doctype (the text-layer merge runs
    /// with `doctype: nil`) and the search path has no classifier output to
    /// mirror Site-A's `effectiveDoctype`, so the feature builder is fed
    /// `.generic` for BOTH the `doctype` and `effectiveDoctype` parameters (the
    /// value the detection seam uses for an unknown doctype). The SAME value is
    /// passed to both params, mirroring the orchestrator passing `effectiveDoctype`
    /// to both. CONSEQUENCE: Site-B parity is exact for generic-doctype documents
    /// and for `account` (whose only non-zero weights are
    /// `nearest_positive_distance` / `digit_run_length`); for `phone` the trained
    /// doctype one-hots carry non-zero weight (e.g. `doctype_is_court` +1.11,
    /// `doctype_is_medical` -0.82), so a phone match on a court/medical/foia
    /// document composes a different posterior at Site B than at Site A. That is an
    /// accepted limitation of the doctype-blind search path, not a measured no-op.
    /// Pure, dependency-injected core of `composedSurvivors`. Static so the
    /// observation-only test seam can drive it with a chosen scorer (identity
    /// vs the installed calibrated artifact) without an actor instance, and so
    /// production and the harness exercise the SAME composition code.
    static func composedSurvivors(
        _ matches: [PIIDetector.PIIMatch],
        pageText: String,
        thresholdVector: PresetThresholdVector?,
        calibratedScorer: CalibratedScorer,
        contextScorer: ContextScorerWeights,
        priors: PerCategoryPriors
    ) -> [PIIDetector.PIIMatch] {
        matches.compactMap { match in
            guard let category = match.category,
                  let cutoff = thresholdVector?.threshold(for: category)
            else { return match }

            let priorMean = max(priors.mean(category), DetectionOrchestrator.absorbingStateFloor)
            let wire = PresetThresholdVector.wireName(for: category) ?? ""
            let contextLogit = contextScorer.learnedContextLogit(
                family: wire,
                features: contextFeatures(
                    match: match,
                    effectiveDoctype: .generic,
                    pageText: pageText
                )
            )
            // Under-redaction posterior floor,
            // the Search-path twin of the Site-A (DetectionOrchestrator) seam. The
            // SAME raw-bar helper, so a keyword-confirmed
            // account/phone the learned term collapsed is re-floored to the
            // preset-invariant conservative cutoff before the gate. Flooring at
            // BOTH seams keeps Auto-Detect and Search symmetric — leaving either
            // unfloored re-opens the leak on one path. The local `cutoff` stays the
            // ACTIVE-preset gate; the floor's source is the separate conservative
            // lookup. Pure code, no blob change. See ContextPosteriorFloor.
            let scored = calibratedScorer.posterior(
                raw: match.confidence,
                priorMean: priorMean,
                contextLogit: contextLogit
            )
            let finalConfidence = ContextPosteriorFloor.apply(
                scored,
                family: wire,
                raw: match.confidence,
                conservativeCutoff: ContextPosteriorFloor.conservativeCutoff(forWire: wire)
            )
            guard finalConfidence >= cutoff else { return nil }

            // The survival decision above is on the POSTERIOR (finalConfidence),
            // but the annotation records `.presetThresholdPass(raw:cutoff:)` keyed
            // on the RAW confidence (the same signal shape ThresholdFilter.applying
            // writes). For a scored family the posterior can carry a raw below the
            // cutoff over it, so this recorded `raw` may be < `cutoff` by design —
            // the audit trail's raw is pre-posterior, not the value that survived.
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
}
