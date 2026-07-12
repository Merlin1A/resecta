import Testing
import Foundation
@testable import RedactionEngine

// P1 prereq — ContextWindowScorer.signal(...) factors the band-classification
// logic out of detector bodies. These tests pin the behavioral contract so
// future detectors adopting the helper match SSN's call-site semantics.

@Suite("ContextWindowScorer.signal band classification")
struct ContextWindowScorerSignalTests {

    private static let profile = KeywordProfile(
        positiveKeywords: ["ssn", "social security"],
        negativeKeywords: ["invoice", "case number"],
        windowRadius: 5,
        baseConfidence: 0.75,
        boostedConfidence: 0.95,
        floor: 0.25
    )

    private func range(of substring: String, in text: String) -> NSRange {
        let nsText = text as NSString
        return nsText.range(of: substring)
    }

    @Test("contextPositive emitted when positive keywords boost the score")
    func signalReturnsContextPositiveWhenStronglyBoosted() {
        let scorer = ContextWindowScorer()
        let text = "SSN: 123-45-6789"
        let signal = scorer.signal(
            text: text,
            matchRange: range(of: "123-45-6789", in: text),
            profile: Self.profile
        )
        guard case let .contextPositive(score) = signal else {
            Issue.record("expected .contextPositive, got \(String(describing: signal))")
            return
        }
        #expect(score >= 0.949)
    }

    @Test("contextNegative emitted when negative keywords suppress the score")
    func signalReturnsContextNegativeWhenSuppressed() {
        let scorer = ContextWindowScorer()
        let text = "Invoice number 123-45-6789 outstanding."
        let signal = scorer.signal(
            text: text,
            matchRange: range(of: "123-45-6789", in: text),
            profile: Self.profile
        )
        guard case let .contextNegative(multiplier) = signal else {
            Issue.record("expected .contextNegative, got \(String(describing: signal))")
            return
        }
        #expect(multiplier < 1.0)
    }

    @Test("nil returned in the neutral band (no keywords)")
    func signalReturnsNilInNeutralBand() {
        let scorer = ContextWindowScorer()
        let text = "abc 123-45-6789 xyz"
        let signal = scorer.signal(
            text: text,
            matchRange: range(of: "123-45-6789", in: text),
            profile: Self.profile
        )
        #expect(signal == nil)
    }

    @Test("signal classification matches the previously-inlined SSN call-site logic")
    func signalPositiveMatchesInlinedLogic() {
        let scorer = ContextWindowScorer()
        let fixtures: [(String, String)] = [
            ("SSN: 123-45-6789", "123-45-6789"),
            ("Invoice number 123-45-6789", "123-45-6789"),
            ("abc 123-45-6789 xyz", "123-45-6789"),
        ]
        for (text, needle) in fixtures {
            let matchRange = range(of: needle, in: text)
            let confidence = scorer.score(
                text: text,
                matchRange: matchRange,
                profile: Self.profile
            )
            let expected: MatchRationale.Signal?
            if confidence >= Self.profile.boostedConfidence - 0.001 {
                expected = .contextPositive(score: confidence)
            } else if confidence < Self.profile.baseConfidence - 0.001 {
                expected = .contextNegative(multiplier: confidence / Self.profile.baseConfidence)
            } else {
                expected = nil
            }
            let observed = scorer.signal(
                text: text,
                matchRange: matchRange,
                profile: Self.profile
            )
            #expect(observed == expected, "mismatch for fixture \(text)")
        }
    }

    @Test("empty profile returns nil for any text")
    func signalHandlesEmptyProfile() {
        let empty = KeywordProfile(
            positiveKeywords: [],
            negativeKeywords: [],
            windowRadius: 5,
            baseConfidence: 0.75,
            boostedConfidence: 0.95,
            floor: 0.25
        )
        let scorer = ContextWindowScorer()
        let text = "anything at all 123-45-6789"
        let signal = scorer.signal(
            text: text,
            matchRange: range(of: "123-45-6789", in: text),
            profile: empty
        )
        #expect(signal == nil)
    }

    // MARK: - W-N regression guard
    //
    // Aggregate-recall delta surrogate for the impl-plan §W-N `Done =`
    // row 5 ("G8 recall on SSN / MRN / LP unchanged ± 1 pt"). G8 carries
    // no licenseplate documents (`G8CorpusIngestionTests` declares the
    // 10-category set: ssn, npi, dea, dob, address, account, mrn, name,
    // phone, email — LP is out of corpus), so a true corpus-level recall
    // measurement can't bind on that category. Instead we assert the
    // structural equivalence that *implies* recall parity: the loader-
    // driven positive sets used at the W-N call sites (each invokes
    // `positiveKeywords(for:doctype: nil)`) equal the engine-side
    // `*ContextKeywords.profile.positiveKeywords` sets after case-folding.
    // If the sets are identical the scorer's `hasPositive` contains-check
    // produces identical bands → identical signals → identical recall by
    // construction.

    @Test("W-N parity: loader positive sets at runtime call sites equal engine-side baselines")
    func loaderPositivesMatchEngineSideAtRuntimeCallSites() throws {
        let loader = try ContextKeywordsLoader()

        let pairs: [(PIICategory, Set<String>, String)] = [
            (.ssn, SSNContextKeywords.profile.positiveKeywords, "SSN"),
            (.medicalRecord, MRNContextKeywords.profile.positiveKeywords, "MRN"),
            (.licensePlate, LicensePlateContextKeywords.profile.positiveKeywords, "LP"),
        ]

        for (category, swiftPositives, label) in pairs {
            let loaderPositives = try #require(
                loader.positiveKeywords(for: category, doctype: nil),
                "loader returned nil for \(label)"
            )
            let swiftLowered = Set(swiftPositives.map { $0.lowercased() })
            #expect(loaderPositives == swiftLowered,
                    "\(label) runtime positive set drift: loader=\(loaderPositives.sorted()) swift=\(swiftLowered.sorted())")
        }
    }
}
