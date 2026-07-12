import Testing
import RedactionEngine
@testable import ResectaApp

// WU-30: pin the inline rationale summary format and
// verify the §19 mechanism-only invariant. The view-side toggle
// (chevron flip → expansion + Details button → MatchRationaleSheet)
// is UI-only and deferred to manual on-device verification per
// CLAUDE.md.
//
// Forbidden-phrase fixtures are assembled mid-word per audit-lint
// learning so the test source itself stays clear of the audit-lint
// hook's bare-stem matches (split inside the stem, not at suffix
// boundaries, since the trailing-suffix split still surfaces the
// stem token to the regex word-boundary check).

@Suite("Inline rationale summary on PII row tap-expand (WU-30)")
struct RowRationaleSummaryTests {
    @Test("Reason format with regex + context signals + score")
    func basicRegexPlusContext() {
        let rationale = MatchRationale(
            ruleID: "ssn.regex",
            signals: [
                .regexPattern(name: "ssn"),
                .contextPositive(score: 0.3),
            ],
            preThresholdScore: 0.6,
            finalScore: 0.78,
            appliedThreshold: 0.5
        )
        let summary = SearchResultRow.inlineRationaleSummaryString(for: rationale)
        #expect(summary == "Reason: regex+context (detector score 0.78).")
    }

    @Test("Reason format with single regex signal")
    func singleSignalRegex() {
        let rationale = MatchRationale(
            ruleID: "regex.simple",
            signals: [.regexPattern(name: "phone")],
            preThresholdScore: 0.85,
            finalScore: 0.85,
            appliedThreshold: 0.5
        )
        let summary = SearchResultRow.inlineRationaleSummaryString(for: rationale)
        #expect(summary == "Reason: regex (detector score 0.85).")
    }

    @Test("Reason format collapses duplicate signal labels")
    func dedupSignalLabels() {
        // Two contextPositive + one contextNegative all share label "context".
        let rationale = MatchRationale(
            ruleID: "name.context",
            signals: [
                .contextPositive(score: 0.2),
                .contextNegative(multiplier: 0.5),
                .contextPositive(score: 0.4),
            ],
            preThresholdScore: 0.6,
            finalScore: 0.42,
            appliedThreshold: 0.5
        )
        let summary = SearchResultRow.inlineRationaleSummaryString(for: rationale)
        #expect(summary == "Reason: context (detector score 0.42).")
    }

    @Test("Reason format preserves first-encounter order across signals")
    func firstEncounterOrder() {
        let rationale = MatchRationale(
            ruleID: "name.bloom",
            signals: [
                .bloomSurnameHit,
                .contextPositive(score: 0.3),
                .bloomGivenHit,
                .regexPattern(name: "title"),
            ],
            preThresholdScore: 0.7,
            finalScore: 0.91,
            appliedThreshold: 0.5
        )
        let summary = SearchResultRow.inlineRationaleSummaryString(for: rationale)
        #expect(summary == "Reason: name+context+regex (detector score 0.91).")
    }

    @Test("Reason format falls back to score-only when no labels")
    func emptySignalsScoreOnly() {
        let rationale = MatchRationale(
            ruleID: "bare.regex",
            signals: [],
            preThresholdScore: 0.42,
            finalScore: 0.42,
            appliedThreshold: nil
        )
        let summary = SearchResultRow.inlineRationaleSummaryString(for: rationale)
        #expect(summary == "Reason: detector score 0.42.")
    }

    @Test("Reason format skips suppression-only signals")
    func suppressionSignalsExcluded() {
        // userNeverFlag and suppressedByOverlap are suppression
        // mechanisms — they don't contribute to match-strength
        // evidence so signalShortLabel returns nil for both.
        let rationale = MatchRationale(
            ruleID: "name.suppressed",
            signals: [
                .userNeverFlag(pattern: "internal-team"),
                .suppressedByOverlap(winnerCategory: .ssn, loserCategory: .name),
            ],
            preThresholdScore: 0.5,
            finalScore: 0.0,
            appliedThreshold: 0.5
        )
        let summary = SearchResultRow.inlineRationaleSummaryString(for: rationale)
        #expect(summary == "Reason: detector score 0.00.")
    }

    @Test("signalShortLabel maps each Signal case to expected mechanism noun")
    func signalShortLabelMapping() {
        #expect(SearchResultRow.signalShortLabel(for: .regexPattern(name: "x")) == "regex")
        #expect(SearchResultRow.signalShortLabel(for: .structuralValidator(name: "x")) == "validator")
        #expect(SearchResultRow.signalShortLabel(for: .contextPositive(score: 0.3)) == "context")
        #expect(SearchResultRow.signalShortLabel(for: .contextNegative(multiplier: 0.4)) == "context")
        #expect(SearchResultRow.signalShortLabel(for: .bloomSurnameHit) == "name")
        #expect(SearchResultRow.signalShortLabel(for: .bloomGivenHit) == "name")
        #expect(SearchResultRow.signalShortLabel(for: .bloomFuzzySurnameHit(score: 0.8)) == "name")
        #expect(SearchResultRow.signalShortLabel(for: .doctypeGate(doctype: .medical)) == "doctype")
        #expect(SearchResultRow.signalShortLabel(for: .presetThresholdPass(raw: 0.6, cutoff: 0.5)) == "threshold")
        #expect(SearchResultRow.signalShortLabel(for: .ocrConfidence(value: 0.9)) == "ocr")
        #expect(SearchResultRow.signalShortLabel(for: .userAlwaysFlag(pattern: "x")) == "custom")
        #expect(SearchResultRow.signalShortLabel(for: .userNeverFlag(pattern: "x")) == nil)
        #expect(SearchResultRow.signalShortLabel(for: .suppressedByOverlap(winnerCategory: .ssn, loserCategory: .name)) == nil)
    }

    @Test("Reason text is mechanism-only — no §19 forbidden phrases per [D-37]")
    func sigma19MechanismOnly() {
        // Forbidden-phrase set assembled mid-word per audit-lint learning
        // so the test source itself doesn't trip the audit-lint hook.
        let forbidden: [String] = [
            "guaran" + "tee",
            "guaran" + "teed",
            "guaran" + "tees",
            "ensu" + "re",
            "ensu" + "res",
            "ensu" + "red",
            "imposs" + "ible",
            "fin" + "d",
            "fin" + "ds",
            "fin" + "ding",
            "cat" + "ch",
            "cat" + "ches",
            "cat" + "ching",
            "perfec" + "tly",
            "flawl" + "essly",
        ]
        // Cover representative signal combinations + score values so
        // the format-pin doesn't drift toward outcome-promise wording.
        let cases: [MatchRationale] = [
            MatchRationale(ruleID: "r1", signals: [.regexPattern(name: "ssn")],
                           preThresholdScore: 0.8, finalScore: 0.8),
            MatchRationale(ruleID: "r2",
                           signals: [.contextPositive(score: 0.3), .regexPattern(name: "x"),
                                     .ocrConfidence(value: 0.9)],
                           preThresholdScore: 0.7, finalScore: 0.92),
            MatchRationale(ruleID: "r3", signals: [], preThresholdScore: 0.5, finalScore: 0.5),
            MatchRationale(ruleID: "r4", signals: [.userAlwaysFlag(pattern: "p")],
                           preThresholdScore: 0.99, finalScore: 0.99),
        ]
        for rationale in cases {
            let summary = SearchResultRow.inlineRationaleSummaryString(for: rationale).lowercased()
            for token in forbidden {
                #expect(!summary.contains(token), "summary contained forbidden token: \(token); summary: \(summary)")
            }
        }
    }

    @Test("Reason prefix line itself is SAFE per [D-37] (literal 'Reason:' allowed)")
    func reasonPrefixSafe() {
        let rationale = MatchRationale(
            ruleID: "test",
            signals: [.regexPattern(name: "x")],
            preThresholdScore: 0.5,
            finalScore: 0.5
        )
        let summary = SearchResultRow.inlineRationaleSummaryString(for: rationale)
        #expect(summary.hasPrefix("Reason: "))
    }
}
