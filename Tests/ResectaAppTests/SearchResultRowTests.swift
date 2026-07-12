import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

// WU-06 — purple "Custom" capsule on result rows whose rationale signals
// contain `.userAlwaysFlag(...)`. Branch ordering protects against future
// engine emissions that combine `.userAlwaysFlag` with a piiCategory:
// the Custom branch fires first per [RR-10]. The view-side check lives
// in `SearchResultRow.isCustomTermHit(_:)` — pure-function contract,
// directly testable without a SwiftUI host.
//
// WU-14 extends this suite with confidence-bar grading
// cases (PII against threshold; OCR against floor; text/regex/Custom
// rows pin the literal-match high tier) and the OCR percentage capsule
// format. Bar grading lives on `SearchResultRow.confidenceTier(...)`;
// tooltip on text/regex rows pins the [D-37]-resolved string verbatim.

@Suite("SearchResultRow rendering — Custom badge + confidence bar (WU-06, WU-14)", .tags(.search))
@MainActor
struct SearchResultRowTests {

    // MARK: - WU-06: Custom badge precedence

    @Test("userAlwaysFlag signal triggers the Custom badge branch")
    func customTermBadgeRenders() {
        let result = makeResult(
            term: "patient_id",
            piiCategory: nil,
            signals: [.userAlwaysFlag(pattern: "patient_id")]
        )
        #expect(SearchResultRow.isCustomTermHit(result) == true)
    }

    @Test("PII row without userAlwaysFlag signal does NOT render Custom")
    func piiNotConfusedWithCustom() {
        let result = makeResult(
            term: "123-45-6789",
            piiCategory: .ssn,
            signals: [.regexPattern(name: "ssn.sep"), .structuralValidator(name: "ssn.area")]
        )
        #expect(SearchResultRow.isCustomTermHit(result) == false)
    }

    @Test("Plain text/regex result with nil rationale does NOT render Custom")
    func nilRationaleIsNotCustom() {
        let result = makeResult(term: "hello", piiCategory: nil, signals: nil)
        #expect(SearchResultRow.isCustomTermHit(result) == false)
    }

    @Test("PII row whose signals include userAlwaysFlag still renders Custom (RR-10 ordering)")
    func userAlwaysFlagBeatsPIICategoryBranch() {
        // Hypothetical future emission: a row with both a piiCategory AND
        // a `.userAlwaysFlag` signal must render as Custom because the
        // user explicitly flagged this term — the category badge would
        // hide the user's intent. Pins the branch-ordering contract.
        let result = makeResult(
            term: "MRN12345",
            piiCategory: .medicalRecord,
            signals: [.userAlwaysFlag(pattern: "MRN[0-9]+"), .regexPattern(name: "mrn.prefix")]
        )
        #expect(SearchResultRow.isCustomTermHit(result) == true)
    }

    @Test("userNeverFlag signal alone does NOT render Custom (different signal case)")
    func userNeverFlagIsNotCustom() {
        let result = makeResult(
            term: "demo_account",
            piiCategory: nil,
            signals: [.userNeverFlag(pattern: "demo_.*")]
        )
        #expect(SearchResultRow.isCustomTermHit(result) == false)
    }

    // MARK: - WU-63: Regex source capsule

    @Test("regex-mode hit with .regexPattern signal renders Regex capsule")
    func regexBadgeRenders() {
        let result = makeResult(
            term: "\\d{3}",
            piiCategory: nil,
            signals: [.regexPattern(name: "\\d{3}")]
        )
        #expect(SearchResultRow.isRegexHit(result, searchMode: .regex) == true)
    }

    @Test("non-regex mode does NOT render Regex capsule even with .regexPattern signal")
    func regexBadgeMOdeGatedAgainstPII() {
        // PII Scan results often carry .regexPattern in their rationale
        // signals (the PII detector uses regex sub-passes internally).
        // The mode gate keeps the Regex capsule from rendering on PII
        // rows — pinned per [RR-19] visual-distinguish floor.
        let result = makeResult(
            term: "123-45-6789",
            piiCategory: .ssn,
            signals: [.regexPattern(name: "ssn.sep"), .structuralValidator(name: "ssn.area")]
        )
        #expect(SearchResultRow.isRegexHit(result, searchMode: .piiScan) == false)
        #expect(SearchResultRow.isRegexHit(result, searchMode: .text) == false)
        #expect(SearchResultRow.isRegexHit(result, searchMode: .multiTerm) == false)
    }

    @Test("regex-mode result with nil rationale does NOT render Regex capsule")
    func regexBadgeNilRationale() {
        let result = makeResult(term: "alpha", piiCategory: nil, signals: nil)
        #expect(SearchResultRow.isRegexHit(result, searchMode: .regex) == false)
    }

    @Test("Saved-regex hit shows the label as 'Regex: <name>'")
    func savedRegexLabelRenders() {
        let result = makeResult(
            term: "vendor-code",
            piiCategory: nil,
            signals: [.regexPattern(name: "vendor-code")]
        )
        #expect(SearchResultRow.regexCapsuleText(for: result) == "Regex: vendor-code")
    }

    @Test("Ad-hoc regex hit (long pattern name) falls back to unlabeled Regex")
    func adHocRegexUnlabeled() {
        // Raw pattern source longer than 20 chars — capsule falls back
        // to the unlabeled form so the label doesn't truncate at the
        // capsule edge or overflow the row.
        let longPattern = "(?:abc|def|ghi|jkl|mno|pqr|stu){2,}"
        let result = makeResult(
            term: longPattern,
            piiCategory: nil,
            signals: [.regexPattern(name: longPattern)]
        )
        #expect(SearchResultRow.regexCapsuleText(for: result) == "Regex")
    }

    @Test("Regex precedence — Custom signal wins on rows carrying both")
    func customBeatsRegexOnBothSignals() {
        // A user-flagged regex term — rationale carries BOTH
        // `.userAlwaysFlag` AND `.regexPattern`. Branch order
        // Custom → Regex → category/source per [RR-10]; Custom
        // wins so the user always sees their own term as
        // responsible for the hit.
        let result = makeResult(
            term: "patient_id",
            piiCategory: nil,
            signals: [
                .userAlwaysFlag(pattern: "patient_id"),
                .regexPattern(name: "patient_id")
            ]
        )
        #expect(SearchResultRow.isCustomTermHit(result) == true)
        // isRegexHit returns true on the predicate level — the branch
        // ordering in sourceBadge's @ViewBuilder selects Custom first,
        // so the predicate's truth here doesn't affect rendering.
        #expect(SearchResultRow.isRegexHit(result, searchMode: .regex) == true)
    }

    // MARK: - WU-14: Confidence-bar tier grading [R-05]

    @Test("confidenceTier — text-layer literal match is high (no piiCategory, not Custom)")
    func textLayerLiteralIsHigh() {
        let result = makeResult(term: "alpha", piiCategory: nil, signals: nil)
        #expect(SearchResultRow.confidenceTier(
            for: result, piiThreshold: 0.50, ocrFloor: 0.0
        ) == .high)
    }

    @Test("confidenceTier — Custom hit is high (literal-match strength)")
    func customHitIsHigh() {
        let result = makeResult(
            term: "patient_id",
            piiCategory: nil,
            signals: [.userAlwaysFlag(pattern: "patient_id")]
        )
        #expect(SearchResultRow.confidenceTier(
            for: result, piiThreshold: 0.50, ocrFloor: 0.0
        ) == .high)
    }

    @Test("confidenceTier — PII row above threshold + 0.15 band is high")
    func piiAboveThresholdIsHigh() {
        let result = makeResult(
            term: "123-45-6789",
            piiCategory: .ssn,
            signals: [.regexPattern(name: "ssn")],
            piiConfidence: 0.90
        )
        #expect(SearchResultRow.confidenceTier(
            for: result, piiThreshold: 0.50, ocrFloor: 0.0
        ) == .high)
    }

    @Test("confidenceTier — PII row inside the 0.15 band is medium")
    func piiAtThresholdIsMedium() {
        let result = makeResult(
            term: "123-45-6789",
            piiCategory: .ssn,
            signals: [.regexPattern(name: "ssn")],
            piiConfidence: 0.55  // 0.50 + 0.05 inside the 0.15 band
        )
        #expect(SearchResultRow.confidenceTier(
            for: result, piiThreshold: 0.50, ocrFloor: 0.0
        ) == .medium)
    }

    @Test("confidenceTier — PII row below threshold is low (defensive; pre-filter removes most)")
    func piiBelowThresholdIsLow() {
        let result = makeResult(
            term: "ambiguous",
            piiCategory: .ssn,
            signals: [.regexPattern(name: "ssn")],
            piiConfidence: 0.30
        )
        #expect(SearchResultRow.confidenceTier(
            for: result, piiThreshold: 0.50, ocrFloor: 0.0
        ) == .low)
    }

    @Test("confidenceTier — OCR row above floor + 0.15 band is high")
    func ocrAboveFloorIsHigh() {
        let result = makeResult(
            term: "scanned_word",
            piiCategory: nil,
            signals: nil,
            source: .ocr(confidence: 0.95)
        )
        #expect(SearchResultRow.confidenceTier(
            for: result, piiThreshold: 0.0, ocrFloor: 0.50
        ) == .high)
    }

    @Test("confidenceTier — OCR row inside the 0.15 band is medium")
    func ocrAtFloorIsMedium() {
        let result = makeResult(
            term: "scanned_word",
            piiCategory: nil,
            signals: nil,
            source: .ocr(confidence: 0.55)
        )
        #expect(SearchResultRow.confidenceTier(
            for: result, piiThreshold: 0.0, ocrFloor: 0.50
        ) == .medium)
    }

    @Test("confidenceTier — OCR row below floor is low")
    func ocrBelowFloorIsLow() {
        let result = makeResult(
            term: "ocr_low_conf",
            piiCategory: nil,
            signals: nil,
            source: .ocr(confidence: 0.20)
        )
        #expect(SearchResultRow.confidenceTier(
            for: result, piiThreshold: 0.0, ocrFloor: 0.50
        ) == .low)
    }

    @Test("confidenceTier — PII over OCR source still grades against piiThreshold (precedence)")
    func piiOverOCRGradesAgainstPIIThreshold() {
        // PII detection on an OCR'd page surfaces with both `piiCategory`
        // and `source == .ocr`. Per the branch order in confidenceTier,
        // PII grading wins; OCR floor is irrelevant here.
        let result = makeResult(
            term: "123-45-6789",
            piiCategory: .ssn,
            signals: [.regexPattern(name: "ssn")],
            source: .ocr(confidence: 0.30),
            piiConfidence: 0.85
        )
        #expect(SearchResultRow.confidenceTier(
            for: result, piiThreshold: 0.50, ocrFloor: 0.50
        ) == .high)
    }

    // MARK: - WU-14: Confidence-bar tooltip [D-37]

    @Test("confidenceBarTooltip — text row surfaces D-37 literal-match string verbatim")
    func tooltipTextRowMatchesD37() {
        let result = makeResult(term: "alpha", piiCategory: nil, signals: nil)
        #expect(SearchResultRow.confidenceBarTooltip(for: result)
                == "Literal match — strength matches the input text.")
    }

    @Test("confidenceBarTooltip — Custom hit surfaces D-37 literal-match string verbatim")
    func tooltipCustomHitMatchesD37() {
        let result = makeResult(
            term: "patient_id",
            piiCategory: nil,
            signals: [.userAlwaysFlag(pattern: "patient_id")]
        )
        #expect(SearchResultRow.confidenceBarTooltip(for: result)
                == "Literal match — strength matches the input text.")
    }

    @Test("confidenceBarTooltip — PII row returns empty (confidence rendered on badge)")
    func tooltipPIIRowEmpty() {
        let result = makeResult(
            term: "123-45-6789",
            piiCategory: .ssn,
            signals: [.regexPattern(name: "ssn")],
            piiConfidence: 0.85
        )
        #expect(SearchResultRow.confidenceBarTooltip(for: result) == "")
    }

    @Test("confidenceBarTooltip — OCR (no PII) row returns empty (percentage on capsule)")
    func tooltipOCRRowEmpty() {
        let result = makeResult(
            term: "scanned_word",
            piiCategory: nil,
            signals: nil,
            source: .ocr(confidence: 0.85)
        )
        #expect(SearchResultRow.confidenceBarTooltip(for: result) == "")
    }

    // MARK: - OCR capsule label

    @Test("ocrCapsuleLabel is the flat 'OCR' string regardless of confidence")
    func ocrCapsuleLabelFlat() {
        // Percent is now encoded by the leading-edge confidence bar; the
        // VoiceOver label retains the percent via the badge's
        // .accessibilityLabel.
        #expect(SearchResultRow.ocrCapsuleLabel(confidence: 0.92) == "OCR")
        #expect(SearchResultRow.ocrCapsuleLabel(confidence: 0.0) == "OCR")
        #expect(SearchResultRow.ocrCapsuleLabel(confidence: 0.495) == "OCR")
    }

    // MARK: - Test fixtures

    private func makeResult(
        term: String,
        piiCategory: PIICategory?,
        signals: [MatchRationale.Signal]?,
        source: SearchSource = .textLayer,
        piiConfidence: Double? = nil
    ) -> SearchResult {
        let rationale: MatchRationale? = signals.map { sigs in
            MatchRationale(
                ruleID: "test.rule",
                signals: sigs,
                preThresholdScore: 0.9,
                finalScore: 0.9,
                appliedThreshold: 0.5
            )
        }
        let resolvedPiiConfidence: Double? = piiConfidence
            ?? (piiCategory == nil ? nil : 0.9)
        return SearchResult(
            pageIndex: 0,
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05),
            matchedText: term,
            contextSnippet: "…\(term)…",
            source: source,
            term: term,
            piiCategory: piiCategory,
            piiConfidence: resolvedPiiConfidence,
            rationale: rationale
        )
    }
}
