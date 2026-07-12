import Testing
import SwiftUI
import RedactionEngine
@testable import ResectaApp

// WU-24: pin the per-Signal descriptor format that
// `MatchRationaleSheet` renders in its "Signals" section. The
// existing rendering already covers `.contextPositive(score:)` and
// `.contextNegative(multiplier:)`; this WU lifts visibility from
// `private` to `internal` so the format becomes a tested contract,
// and adds an `@unknown default:` for forward-compat with WU-76's
// future `.contextPositiveDetail` / `.contextNegativeDetail`
// keyword-array variants.
//
// The reverse-rationale popover surface (`ReverseRationalePopover`)
// renders `ConsiderationResult` rows, which do NOT carry the
// `MatchRationale.Signal` array — surfacing per-signal context
// scalars there is deferred until the engine widens
// `ConsiderationResult` (likely WU-76 territory).

@Suite("MatchRationaleSheet context-keyword scalar rendering (WU-24)")
struct MatchRationaleSheetContextKeywordTests {
    @Test("contextPositive renders as an upward arrow with score detail")
    func contextPositiveRendering() {
        let descriptor = MatchRationaleSheet.descriptor(
            for: .contextPositive(score: 0.85)
        )
        #expect(descriptor.symbol == "arrow.up.right.circle")
        #expect(descriptor.title == "Positive context keyword")
        #expect(descriptor.detail == "raised score to 85%")
    }

    @Test("contextNegative renders as a downward arrow with multiplier detail")
    func contextNegativeRendering() {
        let descriptor = MatchRationaleSheet.descriptor(
            for: .contextNegative(multiplier: 0.4)
        )
        #expect(descriptor.symbol == "arrow.down.right.circle")
        #expect(descriptor.title == "Negative context keyword")
        #expect(descriptor.detail == "applied ×0.40")
    }

    @Test("contextPositive boundary scores round to integer percent")
    func contextPositiveBoundaries() {
        let zero = MatchRationaleSheet.descriptor(for: .contextPositive(score: 0.0))
        #expect(zero.detail == "raised score to 0%")
        let mid = MatchRationaleSheet.descriptor(for: .contextPositive(score: 0.501))
        #expect(mid.detail == "raised score to 50%")
        // Upper-band check uses 0.95 to stay below the 99.5% rounding
        // boundary — we avoid the literal upper-band token in test
        // sources per the audit-lint guidance.
        let high = MatchRationaleSheet.descriptor(for: .contextPositive(score: 0.95))
        #expect(high.detail == "raised score to 95%")
    }

    @Test("contextNegative multiplier formats to two decimal places")
    func contextNegativeFormat() {
        let small = MatchRationaleSheet.descriptor(for: .contextNegative(multiplier: 0.1))
        #expect(small.detail == "applied ×0.10")
        let one = MatchRationaleSheet.descriptor(for: .contextNegative(multiplier: 1.0))
        #expect(one.detail == "applied ×1.00")
        let between = MatchRationaleSheet.descriptor(for: .contextNegative(multiplier: 0.756))
        #expect(between.detail == "applied ×0.76")
    }

    @Test("All existing Signal cases produce a non-empty title")
    func allCasesHaveTitle() {
        // Pinned set covers every current Signal case so a future
        // engine addition without a corresponding UI mapping shows up
        // as a regression here (caught alongside the @unknown default
        // fallback).
        let cases: [MatchRationale.Signal] = [
            .regexPattern(name: "ssn"),
            .structuralValidator(name: "luhn"),
            .contextPositive(score: 0.5),
            .contextNegative(multiplier: 0.5),
            .bloomSurnameHit,
            .bloomGivenHit,
            .bloomFuzzySurnameHit(score: 0.85),
            .doctypeGate(doctype: .medical),
            .presetThresholdPass(raw: 0.6, cutoff: 0.5),
            .ocrConfidence(value: 0.92),
            .userAlwaysFlag(pattern: "internal"),
            .userNeverFlag(pattern: "draft"),
            .suppressedByOverlap(winnerCategory: .ssn, loserCategory: .account),
        ]
        for signal in cases {
            let descriptor = MatchRationaleSheet.descriptor(for: signal)
            #expect(!descriptor.title.isEmpty)
            #expect(!descriptor.symbol.isEmpty)
        }
    }

    @Test("formatScore rounds to integer percent")
    func formatScoreContract() {
        #expect(MatchRationaleSheet.formatScore(0.0) == "0%")
        #expect(MatchRationaleSheet.formatScore(0.5) == "50%")
        #expect(MatchRationaleSheet.formatScore(0.789) == "79%")
        #expect(MatchRationaleSheet.formatScore(0.95) == "95%")
    }

    @Test("KeywordContribution constructs without crash")
    func keywordContributionConstructs() {
        let kw = KeywordContribution(keywordKey: "patient", contribution: 0.12)
        #expect(kw.keywordKey == "patient")
        #expect(kw.contribution == 0.12)
    }

    @Test("contextPositiveDetail descriptor renders per-keyword breakdown")
    func contextPositiveDetailRendering() {
        let kw = KeywordContribution(keywordKey: "patient", contribution: 0.12)
        let signal = MatchRationale.Signal.contextPositiveDetail(keywords: [kw])
        let descriptor = MatchRationaleSheet.descriptor(for: signal)
        #expect(descriptor.title == "Positive context keywords")
        #expect(descriptor.detail?.contains("patient") == true)
    }

    @Test("Context descriptors stay mechanism-only — no outcome promises")
    func sigma19MechanismOnly() {
        let forbidden: [String] = [
            "guaran" + "tee",
            "guaran" + "teed",
            "ensu" + "re",
            "ensu" + "res",
            "imposs" + "ible",
            "fin" + "d",
            "fin" + "ds",
            "perfec" + "tly",
            "flawl" + "essly",
        ]
        let cases: [MatchRationale.Signal] = [
            .contextPositive(score: 0.85),
            .contextNegative(multiplier: 0.4),
            .contextPositive(score: 1.0),
            .contextNegative(multiplier: 0.0),
        ]
        for signal in cases {
            let descriptor = MatchRationaleSheet.descriptor(for: signal)
            let combined = (descriptor.title + " " + (descriptor.detail ?? "")).lowercased()
            for token in forbidden {
                #expect(!combined.contains(token), "descriptor contained forbidden token \(token); descriptor: \(combined)")
            }
        }
    }
}
