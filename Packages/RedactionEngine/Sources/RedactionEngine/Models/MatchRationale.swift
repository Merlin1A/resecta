import Foundation

// MARK: - MatchRationale
//
// Explainability record attached to PII detector hits. Drives the
// MatchRationaleSheet power-user disclosure and feeds the audit export.
// Designed to be cheap (value type, nil for non-PII rows) and stable enough
// that snapshot tests don't churn on every detector tweak.

/// Why a PII hit was emitted — the rule, the aggregated signals, and the
/// score journey from raw detector output to the final confidence that
/// was compared against the preset threshold.
public struct MatchRationale: Sendable, Equatable, Hashable, Codable {
    /// Stable identifier for the rule/pass that produced the hit
    /// (e.g. "ssn.state-machine", "name.nltagger", "mrn.regex.v1").
    public let ruleID: String
    /// The individual pieces of evidence that contributed to the score.
    /// Order is not significant. Empty is legal for a bare regex hit.
    public let signals: [Signal]
    /// Raw score from the detector before calibration or threshold comparison.
    public let preThresholdScore: Double
    /// Score used for the threshold decision. For detectors with no
    /// calibration step this equals `preThresholdScore`.
    public let finalScore: Double
    /// The cutoff this hit was compared against. nil when the scan did not
    /// apply a preset (e.g. back-compat callers, or a pass that skips the
    /// threshold gate).
    public let appliedThreshold: Double?

    public init(
        ruleID: String,
        signals: [Signal] = [],
        preThresholdScore: Double,
        finalScore: Double,
        appliedThreshold: Double? = nil
    ) {
        self.ruleID = ruleID
        self.signals = signals
        self.preThresholdScore = preThresholdScore
        self.finalScore = finalScore
        self.appliedThreshold = appliedThreshold
    }

    /// Return a copy carrying the applied threshold and an extra
    /// signal (typically `.presetThresholdPass(raw:cutoff:)`). Keeps all
    /// existing fields `let` so the struct's invariants are preserved.
    public func with(appliedThreshold: Double, addingSignal signal: Signal) -> MatchRationale {
        var appended = signals
        appended.append(signal)
        return MatchRationale(
            ruleID: ruleID,
            signals: appended,
            preThresholdScore: preThresholdScore,
            finalScore: finalScore,
            appliedThreshold: appliedThreshold
        )
    }

    /// Evidence types recorded during detection. Stable set — adding a case
    /// is additive (old rationale blobs decode fine) but renaming a case is
    /// an audit-log break.
    public enum Signal: Sendable, Equatable, Hashable, Codable {
        /// A named regex pattern matched (e.g. "ssn.sep", "mrn.prefix").
        case regexPattern(name: String)
        /// A structural validator accepted the candidate (SSN area/group,
        /// Luhn, NPI 80840, DEA letter check, etc.).
        case structuralValidator(name: String)
        /// Positive context keywords raised the score.
        case contextPositive(score: Double)
        /// Negative context keywords multiplicatively suppressed the score.
        case contextNegative(multiplier: Double)
        /// Surname Bloom filter hit.
        case bloomSurnameHit
        /// Given-name Bloom filter hit.
        case bloomGivenHit
        /// Fuzzy (Levenshtein-1) surname hit, with the score multiplier
        /// `NameGazetteer.fuzzyContains` returned.
        case bloomFuzzySurnameHit(score: Double)
        /// The doctype gating rule that admitted this pass.
        case doctypeGate(doctype: DoctypeClass)
        /// Preset-threshold comparison recorded at decision time.
        case presetThresholdPass(raw: Double, cutoff: Double)
        /// OCR confidence folded in when the hit came from the OCR path.
        case ocrConfidence(value: Double)
        /// A user-defined always-flag term matched.
        case userAlwaysFlag(pattern: String)
        /// A user-defined never-flag term matched.
        case userNeverFlag(pattern: String)
        /// The overlap resolver picked a winner in this match's range;
        /// the associated `winnerCategory` is the surviving match's category.
        /// Mirrors `ConsiderationResult.overlapWinner` for the `MatchRationale`
        /// consumer.
        ///
        /// `loserCategory` is the suppressed
        /// match's OWN category, carried in the signal so audit/rationale
        /// surfaces can label the loser as itself ("Account, suppressed
        /// via Phone overlap") rather than showing only the winner's
        /// label. Optional: `.other` / non-text kinds have no
        /// `PIICategory`. Optional associated values decode as `nil` when
        /// absent, so rationale blobs recorded before this field existed still decode.
        case suppressedByOverlap(winnerCategory: PIICategory, loserCategory: PIICategory?)
        /// Per-keyword breakdown of the positive context
        /// contribution. Emitted alongside the existing scalar
        /// `.contextPositive(score:)` so consumers can render which
        /// specific gazetteer keywords drove the score. Each
        /// `KeywordContribution.keywordKey` is sourced from the
        /// gazetteer/profile — NEVER from page-extracted text. Closed-vocabulary
        /// invariant; pinned by
        /// `KeywordContributionTests.keywordsClosedVocab`.
        case contextPositiveDetail(keywords: [KeywordContribution])
        /// Negative-context counterpart of
        /// `contextPositiveDetail`. Same closed-vocabulary invariant.
        case contextNegativeDetail(keywords: [KeywordContribution])
        /// The NegativeContextGazetteer fired and suppressed
        /// this hit. Carries the matched keyword (gazetteer data, closed
        /// vocabulary — not document content) and its
        /// `precedence_weight` (the per-matched-keyword value from the
        /// current context-scoring semantics, not the bucket max). The `ContextWindowScorer`
        /// attaches this signal when `suppressionDetail` returns a non-nil
        /// keyword. The header-anchor path is deferred.
        case negativeContextSuppressed(keyword: String, weight: Double)
    }
}

/// A single keyword's contribution to a context-scoring pass.
/// `keywordKey` is sourced from the closed gazetteer/profile vocabulary;
/// `contribution` is a scalar in [0, 1] representing this
/// keyword's share of the band-adjustment. Codable so the audit
/// path can round-trip the new detail signals.
public struct KeywordContribution: Sendable, Equatable, Hashable, Codable {
    public let keywordKey: String
    public let contribution: Double

    public init(keywordKey: String, contribution: Double) {
        self.keywordKey = keywordKey
        self.contribution = contribution
    }
}
