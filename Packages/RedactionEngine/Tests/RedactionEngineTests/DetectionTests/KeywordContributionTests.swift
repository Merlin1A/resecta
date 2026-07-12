import Testing
import Foundation
@testable import RedactionEngine

// WU-76 / [P4] — load-bearing closed-vocabulary invariant + W5 audit-log
// back-compat. The closed-vocabulary test (`keywordsClosedVocab`) is the
// privacy-floor guard: without it, a future engine change could emit
// page-extracted strings via the new detail signals. RR-31 / RR-40
// pin the test in DEFINITION_OF_DONE and the test must run in CI.

@Suite("Context keyword contribution (WU-76)")
struct KeywordContributionTests {

    // Synthetic profile with known keyword vocabularies — independent
    // of the production gazetteer load. Keywords are lowercased to
    // match `ContextWindowScorer`'s lowercased contextWindow.
    private let profile = KeywordProfile(
        positiveKeywords: ["patient", "diagnosis"],
        negativeKeywords: ["sample", "draft"],
        windowRadius: 5,
        baseConfidence: 0.5,
        boostedConfidence: 0.85,
        floor: 0.1
    )

    // MARK: - Closed-vocab invariant (load-bearing)

    @Test("Closed-vocabulary invariant — every keywordKey from gazetteer")
    func keywordsClosedVocab() throws {
        // Load-bearing per RR-31 / RR-40 / DEFINITION_OF_DONE engine-WU.
        // RR-40 mitigation: assert non-empty gazetteer load BEFORE
        // validating containment — otherwise a future path drift could
        // silently make the invariant vacuous.

        // Step 1: load the production gazetteer. The loader maps the
        // `Resources/Gazetteers/context-keywords.json` resource into
        // per-category keyword sets.
        let loader = try ContextKeywordsLoader()

        // Step 2: pick a category that ships with global positive
        // keywords (MRN) and assert the set is non-empty.
        guard let mrn = loader.positiveKeywords(for: .medicalRecord, doctype: nil) else {
            Issue.record("mrn keywords missing — gazetteer path drift suspected (RR-40)")
            return
        }
        #expect(!mrn.isEmpty, "gazetteer must load non-empty keywords (RR-40 mitigation)")

        // Step 3: run the scorer against a text that contains at least
        // one gazetteer keyword adjacent to a match, then verify EVERY
        // emitted contribution key is in the closed vocabulary.
        let realProfile = KeywordProfile(
            positiveKeywords: mrn,
            negativeKeywords: [],
            windowRadius: 8,
            baseConfidence: 0.5,
            boostedConfidence: 0.85,
            floor: 0.1
        )
        // Build a text that includes ALL the keyword tokens explicitly
        // so the scorer's `contains` check fires.
        let keywordsAdjacent = mrn.sorted().joined(separator: " ")
        let text = "\(keywordsAdjacent) ACME000123 follows."
        let nsText = text as NSString
        let matchRange = nsText.range(of: "ACME000123")

        let scorer = ContextWindowScorer()
        let detail = scorer.signalDetail(
            text: text,
            matchRange: matchRange,
            profile: realProfile
        )

        guard case .contextPositiveDetail(let contributions)? = detail else {
            Issue.record("Expected .contextPositiveDetail, got \(String(describing: detail))")
            return
        }
        // Load-bearing assertion — every emitted keywordKey is in the
        // closed gazetteer vocabulary.
        for c in contributions {
            #expect(
                mrn.contains(c.keywordKey),
                "keywordKey '\(c.keywordKey)' not in closed gazetteer vocab — RR-31 violation"
            )
        }
    }

    // MARK: - Detail emission shape

    @Test("Positive detail emitted when positive keyword in window")
    func emitsPositiveDetail() {
        let text = "patient ID 12345 record"
        let nsText = text as NSString
        let detail = ContextWindowScorer().signalDetail(
            text: text,
            matchRange: nsText.range(of: "12345"),
            profile: profile
        )
        guard case .contextPositiveDetail(let contributions)? = detail else {
            Issue.record("Expected .contextPositiveDetail, got \(String(describing: detail))")
            return
        }
        #expect(contributions.contains { $0.keywordKey == "patient" })
        #expect(contributions.allSatisfy { $0.contribution > 0 })
    }

    @Test("Negative detail emitted when negative keyword in window")
    func emitsNegativeDetail() {
        let text = "sample 12345 placeholder"
        let nsText = text as NSString
        let detail = ContextWindowScorer().signalDetail(
            text: text,
            matchRange: nsText.range(of: "12345"),
            profile: profile
        )
        guard case .contextNegativeDetail(let contributions)? = detail else {
            Issue.record("Expected .contextNegativeDetail, got \(String(describing: detail))")
            return
        }
        #expect(contributions.contains { $0.keywordKey == "sample" })
    }

    @Test("Neutral window emits no detail variant")
    func neutralEmitsNil() {
        let text = "abc 12345 xyz"
        let nsText = text as NSString
        let detail = ContextWindowScorer().signalDetail(
            text: text,
            matchRange: nsText.range(of: "12345"),
            profile: profile
        )
        #expect(detail == nil)
    }

    // MARK: - W5 audit back-compat

    @Test("W5 audit decoder back-compat decodes blobs without new cases")
    func auditBackCompat() throws {
        // Fixture: an OLD rationale blob (no detail variants) must
        // continue to decode after the additive Signal cases land.
        // Sanity-encodes a rationale that uses only the scalar
        // `.contextPositive` / `.contextNegative` cases, then decodes
        // and verifies field-for-field equality.
        let original = MatchRationale(
            ruleID: "v1.detector",
            signals: [
                .regexPattern(name: "pattern"),
                .contextPositive(score: 0.85),
                .contextNegative(multiplier: 0.5),
            ],
            preThresholdScore: 0.4,
            finalScore: 0.85
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MatchRationale.self, from: data)
        #expect(decoded == original, "old-shape blob must round-trip equal")
    }

    @Test("New detail variants round-trip through Codable")
    func detailVariantsRoundTrip() throws {
        let original = MatchRationale(
            ruleID: "v2.detector",
            signals: [
                .contextPositiveDetail(keywords: [
                    KeywordContribution(keywordKey: "patient", contribution: 0.12),
                    KeywordContribution(keywordKey: "diagnosis", contribution: 0.08),
                ]),
                .contextNegativeDetail(keywords: [
                    KeywordContribution(keywordKey: "sample", contribution: 0.05),
                ]),
            ],
            preThresholdScore: 0.5,
            finalScore: 0.7
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MatchRationale.self, from: data)
        #expect(decoded == original)
    }
}
