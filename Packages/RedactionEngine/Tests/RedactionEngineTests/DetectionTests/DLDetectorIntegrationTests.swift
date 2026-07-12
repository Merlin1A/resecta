import Testing
import Foundation
@testable import RedactionEngine

// D-13 — DL detector + DLPatternGazetteer integration. Coexists with the
// existing DriversLicenseDetectorTests (labeled-format recall, doctype-
// agnostic, confidence calibration); this file focuses on the W1
// validation-gate path: a candidate from the inline label-prefix regex
// must match at least one jurisdiction's per-state pattern, otherwise it
// is suppressed. F-35 SSN/DLN ambiguity (AR/HI/ID/LA/MS) is preserved —
// multi-state hits remain kept candidates.

@Suite("DL detector × gazetteer integration (D-13 W1)")
struct DLDetectorIntegrationTests {

    // MARK: - W1 acceptance

    @Test("W1 keeps candidate matching exactly one jurisdiction-shape arm")
    func testW1KeepsSingleArmMatch() async {
        let detector = PIIDetector(nameGazetteer: nil)
        // A + 7 digits — matches CA `^[A-Z][0-9]{7}$` (and the AAMVA
        // envelope rows, since 8 alphanumerics qualify); the gate keeps
        // the candidate as long as ≥1 state matches.
        let matches = await detector.detect(in: "DL: A1234567", doctype: nil)
            .filter { $0.kind == .driversLicense }
        let hit = try! #require(matches.first)
        #expect(hit.text == "A1234567")
        #expect(abs(hit.confidence - 0.80) < 0.001,
                "W1 keeps the 0.80 baseline confidence")
    }

    @Test("W1 keeps F-35 9-digit candidate (multi-state ambiguity preserved)")
    func testW1KeepsF35Ambiguity() async {
        let detector = PIIDetector(nameGazetteer: nil)
        // 9 digits — the F-35 ambiguity surface. AR/HI/ID/LA/MS all
        // accept this shape; so do envelope rows and several other
        // numeric-DL states. The W1 gate keeps the candidate; engine-
        // side mitigation routes through D-12 / D-16 anchors.
        let matches = await detector.detect(in: "Driver's License: 123456789", doctype: nil)
            .filter { $0.kind == .driversLicense }
        let hit = try! #require(matches.first)
        #expect(hit.text == "123456789")
        #expect(abs(hit.confidence - 0.80) < 0.001)
    }

    // MARK: - W1 suppression

    @Test("W1 suppresses candidate matching no jurisdiction (15-char alpha-prefix)")
    func testW1SuppressesNoStateMatch() async {
        let detector = PIIDetector(nameGazetteer: nil)
        // 15-char `A` + 14 digits. The inline regex captures (alpha +
        // 4-14 digits arm), but no per-state pattern admits 15 chars —
        // the longest alpha-prefix state pattern is WI `^[A-Z][0-9]{13}$`
        // (14 chars). The gate suppresses.
        let matches = await detector.detect(in: "DL A12345678901234", doctype: nil)
            .filter { $0.kind == .driversLicense }
        #expect(matches.isEmpty,
                "Candidate with no jurisdictional match must be suppressed under W1")
    }

    @Test("W1 inert when gazetteer absent (test-bundle-only fallback)")
    func testW1InertWhenGazetteerNil() async {
        // Same 15-char input as the suppression test above. With the
        // gazetteer explicitly nil, W1 is bypassed and the candidate
        // flows through (pre-W1 behavior preserved for builds that
        // strip the JSON resource).
        let detector = PIIDetector(nameGazetteer: nil, dlPatternGazetteer: nil)
        let matches = await detector.detect(in: "DL A12345678901234", doctype: nil)
            .filter { $0.kind == .driversLicense }
        #expect(!matches.isEmpty,
                "Without gazetteer, W1 gate must not fire — pass-through behavior")
    }

    // MARK: - Regression guard

    @Test("Existing labeled-prefix recall samples survive W1 gate", arguments: [
        "DL: A1234567 issued CA.",                   // CA
        "Driver's License: B2345678 renewed.",       // CA
        "DL #C3456789 suspended pending review.",    // CA
        "Driver License D4567890 on file.",          // CA
        "D.L. E5678901 valid through 2030.",         // CA
        "DL: F67890123 presented at booking.",       // MA / HI
        "DL: 123456 numeric-only.",                  // AL / LA / UT
        "DL: 12345678 numeric-only.",                // many
        "DL: K12345 alphanumeric, OH format.",       // CO / OH
    ])
    func testW1RegressionLabeledFormats(_ input: String) async {
        let detector = PIIDetector(nameGazetteer: nil)
        let matches = await detector.detect(in: input, doctype: nil)
            .filter { $0.kind == .driversLicense }
        #expect(!matches.isEmpty,
                "Existing recall sample '\(input)' must still be detected under W1")
    }

    // MARK: - Case insensitivity at the gate

    @Test("W1 normalizes case before gazetteer lookup")
    func testW1CaseNormalization() async {
        let detector = PIIDetector(nameGazetteer: nil)
        // The inline regex is case-insensitive, so it captures a
        // lowercase candidate. The gazetteer's per-state patterns are
        // case-sensitive (alphabet A-Z). W1 must uppercase the candidate
        // before lookup so OCR-noise lowercase still passes the gate.
        let matches = await detector.detect(in: "dl: a1234567", doctype: nil)
            .filter { $0.kind == .driversLicense }
        #expect(!matches.isEmpty,
                "Lowercase candidate captured by case-insensitive inline regex must pass W1 after uppercase normalization")
    }
}
