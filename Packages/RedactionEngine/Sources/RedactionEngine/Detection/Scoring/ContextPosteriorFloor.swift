import Foundation

// SRCH-S2 — D02-scorer-posterior-F1 (account, P1) + D02-scorer-posterior-F2 (phone, P2).
//
// The B05/B06 learned context scorer (context-scorer.json `fecd89b6`) composes a
// standardized log-odds term into the detection posterior at two seams:
//   • DetectionOrchestrator.detectPage (Auto-Detect)
//   • DocumentSearcher.composedSurvivors (Search)
// For the two keyword-only families (account, phone) a single length/separator
// feature can drive a structurally-valid, keyword-confirmed match far below the
// preset gate on its own — e.g. a separator-less phone collapses ≈ −7.43 on the
// standardized `has_separator` term, and a short keyword-confirmed account
// collapses on `digit_run_length`. Such a match is dropped, so the targeted PII
// is left in the output (the under-redaction leak).
//
// This is the code-side mitigation. It re-floors only a keyword-confirmed
// (raw ≥ keywordConfirmedRaw) account/phone to the raw bar it already cleared,
// sourced from the CONSERVATIVE preset so the floor is preset-invariant. It is
// pure code: it reads cutoffs already produced by PresetThresholdVector and edits
// no model artifact. The deeper distribution mismatch (account `digit_run_length`
// retrain / phone `has_separator` corpus recalibration) is the deferred B05/Jesse
// blob retrain, not a launch change.
//
// DESIGN-DECISIONS DQ2 — the RAW-BAR form is the shipped default (the fixed
// aggressive-cutoff and the `contextFloorDelta` delta forms in the two member
// proposals are rejected). Mirrors the A1-parity floor the rule-based scorer
// already applies (ContextWindowScorer.profile.floor): a confirmed match is not
// driven below the bar it earned by a context term alone.
enum ContextPosteriorFloor {

    /// The raw bar a match must already have cleared for the floor to apply.
    /// A keyword-confirmed account raw is 0.75 and a keyword-confirmed phone raw
    /// is 0.80, both above this bar; a bare, no-keyword phone (raw 0.60) and a
    /// no-keyword digit run (raw ≈ 0) fall below it and are left untouched, so the
    /// floor only re-admits a match the detector itself surfaced with keyword
    /// confirmation — never a bare digit run.
    static let keywordConfirmedRaw = 0.70

    /// Families whose detector emits a strong keyword-driven boost with no
    /// intrinsic checksum, so a learned length/separator feature must not have
    /// veto power over them. Account is the broad keyword-only family; phone is
    /// the separator-less slice. A deliberate, non-blanket extension point —
    /// extend per measured result, never blanket-apply to checksum-bearing families.
    static let flooredFamilies: Set<String> = ["account", "phone"]

    /// CONSERVATIVE-preset cutoffs from the shipped preset-thresholds.json
    /// (`28921a52`), read once. The floor always sources the conservative vector,
    /// independent of the active preset, so a floored posterior is the SAME value
    /// at aggressive / balanced / conservative (preset-invariant). Sourcing the
    /// active-preset cutoff instead would degenerate to "always survive the active
    /// preset". Loader fail-open already returns built-in defaults on any error;
    /// the empty-vector fallback makes `conservativeCutoff` read 1.0 (the floor
    /// then caps at raw — still bounded by what the detector earned).
    private static let conservativeVector: PresetThresholdVector =
        PresetThresholdBundle.loadFromEngineBundle().presets[.conservative]
        ?? PresetThresholdVector(thresholdsByWireName: [:])

    /// The CONSERVATIVE-preset cutoff for a wire family (a static
    /// PresetThresholdVector lookup, preset-invariant — NOT the active cutoff in
    /// scope at the W4 gate / `composedSurvivors` guard).
    static func conservativeCutoff(forWire wire: String) -> Double {
        conservativeVector.threshold(forWireName: wire) ?? 1.0
    }

    /// Raw-bar floor. For a floored family whose raw cleared `keywordConfirmedRaw`,
    /// lifts the posterior to the conservative cutoff but no higher than the raw
    /// bar itself (`min(raw, conservativeCutoff)`), so the floor never reports a
    /// score above what the detector earned and never lowers an already-higher
    /// posterior (`max`). Every other case returns the posterior unchanged.
    ///
    /// - Parameters:
    ///   - posterior: the composed posterior from `CalibratedScorer.posterior`.
    ///   - family: the wire-name family (`PresetThresholdVector.wireName(for:)`).
    ///   - raw: the detector's pre-posterior confidence (`PIIMatch.confidence`).
    ///   - conservativeCutoff: the family's conservative-preset cutoff
    ///     (`conservativeCutoff(forWire:)`).
    static func apply(_ posterior: Double,
                      family: String,
                      raw: Double,
                      conservativeCutoff: Double) -> Double {
        guard flooredFamilies.contains(family), raw >= keywordConfirmedRaw else {
            return posterior
        }
        return max(posterior, min(raw, conservativeCutoff))
    }
}
