import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

// The purple "Custom" capsule on result rows whose rationale signals
// contain `.userAlwaysFlag(...)`. Branch ordering protects against future
// engine emissions that combine `.userAlwaysFlag` with a piiCategory:
// the Custom branch fires first. The view-side check lives
// in `SearchResultRow.isCustomTermHit(_:)` — pure-function contract,
// directly testable without a SwiftUI host.
//
// This suite also covers confidence-bar grading
// cases (PII against threshold; OCR against floor; text/regex/Custom
// rows pin the literal-match high tier) and the OCR percentage capsule
// format. Bar grading lives on `SearchResultRow.confidenceTier(...)`;
// the tooltip on text/regex rows pins its resolved string verbatim.

@Suite("SearchResultRow rendering — Custom badge + confidence bar", .tags(.search))
@MainActor
struct SearchResultRowTests {

    // MARK: - Custom badge precedence

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

    @Test("PII row whose signals include userAlwaysFlag still renders Custom")
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

    // MARK: - Regex source capsule

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
        // rows — this keeps the visual-distinguish floor intact.
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
        // Custom → Regex → category/source; Custom
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

    // MARK: - Confidence-bar tier grading

    @Test("confidenceTier — text-layer literal match is high (no piiCategory, not Custom)")
    func textLayerLiteralIsHigh() {
        let result = makeResult(term: "alpha", piiCategory: nil, signals: nil)
        #expect(SearchResultRow.confidenceTier(
            for: result, ocrFloor: 0.0
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
            for: result, ocrFloor: 0.0
        ) == .high)
    }

    // PII rows grade on the shared ABSOLUTE bands (>= 0.9 high,
    // >= 0.7 medium, else low) — the same tiers the detection review
    // rows use, one confidence grammar for both origins. The former
    // `piiThreshold` input read the dormant `minimumPIIConfidence`
    // (no live control since the per-run Confidence slider retired).

    @Test("confidenceTier — PII row at or above 0.9 is high")
    func piiAboveThresholdIsHigh() {
        let result = makeResult(
            term: "123-45-6789",
            piiCategory: .ssn,
            signals: [.regexPattern(name: "ssn")],
            piiConfidence: 0.90
        )
        #expect(SearchResultRow.confidenceTier(
            for: result, ocrFloor: 0.0
        ) == .high)
    }

    @Test("confidenceTier — PII row in the 0.7..<0.9 band is medium")
    func piiMidBandIsMedium() {
        let result = makeResult(
            term: "123-45-6789",
            piiCategory: .ssn,
            signals: [.regexPattern(name: "ssn")],
            piiConfidence: 0.75
        )
        #expect(SearchResultRow.confidenceTier(
            for: result, ocrFloor: 0.0
        ) == .medium)
    }

    @Test("confidenceTier — PII row below 0.7 is low")
    func piiBelowThresholdIsLow() {
        let result = makeResult(
            term: "ambiguous",
            piiCategory: .ssn,
            signals: [.regexPattern(name: "ssn")],
            piiConfidence: 0.55
        )
        #expect(SearchResultRow.confidenceTier(
            for: result, ocrFloor: 0.0
        ) == .low)
    }

    @Test("absoluteConfidenceTier — shared band boundaries for both origins")
    func absoluteBandBoundaries() {
        #expect(SearchResultRow.absoluteConfidenceTier(0.90) == .high)
        #expect(SearchResultRow.absoluteConfidenceTier(0.89) == .medium)
        #expect(SearchResultRow.absoluteConfidenceTier(0.70) == .medium)
        #expect(SearchResultRow.absoluteConfidenceTier(0.69) == .low)
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
            for: result, ocrFloor: 0.50
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
            for: result, ocrFloor: 0.50
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
            for: result, ocrFloor: 0.50
        ) == .low)
    }

    @Test("confidenceTier — PII over OCR source still grades on the PII bands (precedence)")
    func piiOverOCRGradesAgainstPIIBands() {
        // PII detection on an OCR'd page surfaces with both `piiCategory`
        // and `source == .ocr`. Per the branch order in confidenceTier,
        // PII grading wins; OCR floor is irrelevant here. 0.85 sits in
        // the absolute medium band even though it clears the OCR floor's
        // high band — proving the PII branch took precedence.
        let result = makeResult(
            term: "123-45-6789",
            piiCategory: .ssn,
            signals: [.regexPattern(name: "ssn")],
            source: .ocr(confidence: 0.30),
            piiConfidence: 0.85
        )
        #expect(SearchResultRow.confidenceTier(
            for: result, ocrFloor: 0.50
        ) == .medium)
    }

    // MARK: - Confidence-bar tooltip

    @Test("confidenceBarTooltip — text row surfaces the literal-match string verbatim")
    func tooltipTextRowMatchesD37() {
        let result = makeResult(term: "alpha", piiCategory: nil, signals: nil)
        #expect(SearchResultRow.confidenceBarTooltip(for: result)
                == "Literal match — strength matches the input text.")
    }

    @Test("confidenceBarTooltip — Custom hit surfaces the literal-match string verbatim")
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

    // MARK: - Qualitative descriptors replace "N% confidence"

    @Test("ConfidenceTier.descriptor is the exact lowercase mid-sentence form")
    func confidenceTierDescriptorExactText() {
        #expect(SearchResultRow.ConfidenceTier.high.descriptor == "high confidence")
        #expect(SearchResultRow.ConfidenceTier.medium.descriptor == "medium confidence")
        #expect(SearchResultRow.ConfidenceTier.low.descriptor == "low confidence")
    }

    @Test("ConfidenceTier.descriptorLabel is the exact capitalized sentence-position form")
    func confidenceTierDescriptorLabelExactText() {
        #expect(SearchResultRow.ConfidenceTier.high.descriptorLabel == "High confidence")
        #expect(SearchResultRow.ConfidenceTier.medium.descriptorLabel == "Medium confidence")
        #expect(SearchResultRow.ConfidenceTier.low.descriptorLabel == "Low confidence")
    }

    @Test("piiBadgeAccessibilityLabel routes through the descriptor, text source and OCR source")
    func piiBadgeAccessibilityLabelUsesDescriptor() {
        let textResult = makeResult(
            term: "123-45-6789", piiCategory: .ssn,
            signals: [.regexPattern(name: "ssn")], piiConfidence: 0.97
        )
        // PIICategory.ssn.rawValue is the short badge string "SSN" —
        // "Social Security Number" is RegionMetadata's full-description
        // label (a different enum), not this one.
        #expect(SearchResultRow.piiBadgeAccessibilityLabel(for: textResult, category: .ssn)
                == "SSN, high confidence")
        let ocrResult = makeResult(
            term: "123-45-6789", piiCategory: .ssn,
            signals: [.regexPattern(name: "ssn")],
            source: .ocr(confidence: 0.5), piiConfidence: 0.75
        )
        #expect(SearchResultRow.piiBadgeAccessibilityLabel(for: ocrResult, category: .ssn)
                == "SSN, medium confidence, OCR source")
    }

    @Test("ocrCapsuleAccessibilityLabel routes through the row's floor-relative tier",
          arguments: [
            (SearchResultRow.ConfidenceTier.high, "OCR, high confidence"),
            (SearchResultRow.ConfidenceTier.medium, "OCR, medium confidence"),
            (SearchResultRow.ConfidenceTier.low, "OCR, low confidence"),
          ])
    func ocrCapsuleAccessibilityLabelUsesDescriptor(
        tier: SearchResultRow.ConfidenceTier, expected: String
    ) {
        #expect(SearchResultRow.ocrCapsuleAccessibilityLabel(tier: tier) == expected)
    }

    @Test("No new confidence string carries a percent sign")
    func uxc22NoPercentAnywhere() {
        let piiSample = SearchResultRow.piiBadgeAccessibilityLabel(
            for: makeResult(term: "x", piiCategory: .ssn, signals: nil, piiConfidence: 0.9),
            category: .ssn
        )
        let regionMetadataSample = RegionMetadata.mock(confidence: 0.5).accessibilityDescription
        let samples = [
            SearchResultRow.ConfidenceTier.high.descriptor,
            SearchResultRow.ConfidenceTier.medium.descriptor,
            SearchResultRow.ConfidenceTier.low.descriptor,
            SearchResultRow.ConfidenceTier.high.descriptorLabel,
            SearchResultRow.ConfidenceTier.medium.descriptorLabel,
            SearchResultRow.ConfidenceTier.low.descriptorLabel,
            piiSample,
            SearchResultRow.ocrCapsuleAccessibilityLabel(tier: .high),
            SearchResultRow.ocrCapsuleAccessibilityLabel(tier: .medium),
            SearchResultRow.ocrCapsuleAccessibilityLabel(tier: .low),
            regionMetadataSample,
        ]
        for sample in samples {
            #expect(!sample.contains("%"), "percent sign found in: \(sample)")
        }
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
