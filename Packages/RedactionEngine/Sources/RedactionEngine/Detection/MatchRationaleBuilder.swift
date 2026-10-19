import Foundation

// One assembly for every rationale the family detectors emit: the rule id,
// the signals in emission order (a nil signal — a scorer with nothing to
// say — is not appended), the pre-threshold score, and the final score once
// it is known. The doctype-gate annotation and the overlap loser's mark are
// copies of an existing rationale with one signal appended.

extension MatchRationale {
    /// Collects a detector's evidence in emission order and builds the
    /// rationale once the final score is known.
    struct Builder {
        let ruleID: String
        let preThresholdScore: Double
        private(set) var signals: [Signal]

        init(ruleID: String, preThresholdScore: Double, signals: [Signal] = []) {
            self.ruleID = ruleID
            self.preThresholdScore = preThresholdScore
            self.signals = signals
        }

        /// Append a signal; nil is skipped.
        mutating func append(_ signal: Signal?) {
            if let signal { signals.append(signal) }
        }

        func build(finalScore: Double, appliedThreshold: Double? = nil) -> MatchRationale {
            MatchRationale(
                ruleID: ruleID, signals: signals,
                preThresholdScore: preThresholdScore, finalScore: finalScore,
                appliedThreshold: appliedThreshold
            )
        }
    }

    /// The explanation of a context-scored pattern match, assembled in the
    /// order every family detector emits: the rule's own pattern signal,
    /// its structural validators, the scorer's context signal, then the
    /// per-keyword detail and the gazetteer signal where the detector has
    /// one (a nil is skipped).
    static func contextScored(
        ruleID: String,
        preThresholdScore: Double,
        validators: [String] = [],
        contextSignal: Signal?,
        keywordDetail: Signal? = nil,
        gazetteerSignal: Signal? = nil,
        finalScore: Double
    ) -> MatchRationale {
        var builder = Builder(
            ruleID: ruleID, preThresholdScore: preThresholdScore,
            signals: [.regexPattern(name: ruleID)] + validators.map { .structuralValidator(name: $0) }
        )
        builder.append(contextSignal)
        builder.append(keywordDetail)
        builder.append(gazetteerSignal)
        return builder.build(finalScore: finalScore)
    }

    /// A copy with `signal` appended; every other field is kept.
    func appending(_ signal: Signal) -> MatchRationale {
        MatchRationale(
            ruleID: ruleID, signals: signals + [signal],
            preThresholdScore: preThresholdScore, finalScore: finalScore,
            appliedThreshold: appliedThreshold
        )
    }
}
