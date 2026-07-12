import Testing
import Foundation
@testable import RedactionEngine

// L-15 — dedicated passport-detector coverage: labeled-format recall,
// unlabeled rejection, doctype-agnostic behavior, and confidence
// calibration. Mirrors DetectionTests/BatesDetectorTests.swift structure.

@Suite("Passport detector")
struct PassportDetectorTests {

    private let detector = PIIDetector(nameGazetteer: nil)

    // MARK: - Labeled-format regex coverage

    @Test("Passport regex accepts labeled formats", arguments: [
        "Passport: A1234567",
        "PP #B12345678",
        "Passport No C123456789",
        "Passport Number: D1234567",
        "Passport AB123456",
    ])
    func validPassport(_ input: String) {
        let range = NSRange(location: 0, length: (input as NSString).length)
        let matches = PIIDetector.passportPattern.matches(in: input, range: range)
        #expect(!matches.isEmpty, "Expected passport match for '\(input)'")
    }

    @Test("Passport regex rejects unlabeled alphanumerics")
    func passportRejectsUnlabeled() {
        let input = "A1234567 appears in the ledger"
        let range = NSRange(location: 0, length: (input as NSString).length)
        let matches = PIIDetector.passportPattern.matches(in: input, range: range)
        #expect(matches.isEmpty, "Should not match without passport label prefix")
    }

    @Test("Passport regex rejects too-short numeric suffixes")
    func passportRejectsShortNumeric() {
        let input = "Passport A12345"  // 5 digits — below 6-digit floor
        let range = NSRange(location: 0, length: (input as NSString).length)
        let matches = PIIDetector.passportPattern.matches(in: input, range: range)
        #expect(matches.isEmpty,
                "Passport body requires ≥ 6 digits after alpha prefix")
    }

    // MARK: - Doctype-agnostic behavior

    @Test("Passport detection is doctype-agnostic (runs on every doctype)",
          arguments: DoctypeClass.allCases)
    func passportRunsOnEveryDoctype(_ doctype: DoctypeClass) async {
        let text = "Passport: AB123456 on file."
        let matches = await detector.detect(in: text, doctype: doctype)
        #expect(matches.contains { $0.kind == .passport },
                "Expected passport detection for doctype \(doctype)")
    }

    @Test("Passport detection also runs on nil doctype (permissive)")
    func passportRunsOnNilDoctype() async {
        let text = "Passport: AB123456"
        let matches = await detector.detect(in: text, doctype: nil)
        #expect(matches.contains { $0.kind == .passport })
    }

    // MARK: - Confidence calibration

    @Test("Passport confidence is calibrated to 0.80")
    func passportConfidenceIs80() async {
        let text = "Passport: AB123456"
        let matches = await detector.detect(in: text, doctype: nil)
            .filter { $0.kind == .passport }
        let hit = try! #require(matches.first)
        #expect(abs(hit.confidence - 0.80) < 0.001,
                "Passport base confidence should be 0.80, got \(hit.confidence)")
    }

    // MARK: - Synthetic recall / precision

    @Test("Synthetic corpus recall/precision clears 90 %")
    func passportRecallPrecisionOnSyntheticCorpus() async {
        struct Sample { let text: String; let expected: Int }
        // ~15 positives across labeled formats.
        let positives: [Sample] = [
            Sample(text: "Passport: A1234567 issued US.", expected: 1),
            Sample(text: "PP #B23456789 on record.", expected: 1),
            Sample(text: "Passport No C3456789 expires 2029.", expected: 1),
            Sample(text: "Passport Number: D4567890 — Canada.", expected: 1),
            Sample(text: "Passport E5678901 in file.", expected: 1),
            Sample(text: "PP F6789012 valid until 2030.", expected: 1),
            Sample(text: "Passport: AB234567 diplomatic.", expected: 1),
            Sample(text: "PP: CD345678 official visit.", expected: 1),
            Sample(text: "Passport No EF456789 issued London.", expected: 1),
            Sample(text: "Passport Number GH567890 — UK.", expected: 1),
            Sample(text: "Passport IJ678901 renewed.", expected: 1),
            Sample(text: "PP #KL789012 on record.", expected: 1),
            Sample(text: "Passport: MN890123 Schengen visa.", expected: 1),
            Sample(text: "Passport No OP901234 — Germany.", expected: 1),
            Sample(text: "Passport QR012345 expires 2031.", expected: 1),
        ]
        // ~10 negatives without passport label context.
        let negatives: [String] = [
            "Case number A1234567 filed today.",
            "Invoice B23456789 paid via wire.",
            "Order C3456789 shipped overnight.",
            "Reference D4567890 in the letter.",
            "Part number E5678901 in stock.",
            "Docket no. 12345678 hearing set.",
            "Tracking number AB1234567 delivered.",
            "Zip 12345 on the form.",
            "The quick brown fox jumps over the lazy dog.",
            "Temperature reading 98 today.",
        ]

        var truePos = 0
        var falseNeg = 0
        var falsePos = 0
        for sample in positives {
            let matches = await detector.detect(in: sample.text, doctype: nil)
                .filter { $0.kind == .passport }
            let hit = min(matches.count, sample.expected)
            truePos += hit
            falseNeg += sample.expected - hit
        }
        for neg in negatives {
            let matches = await detector.detect(in: neg, doctype: nil)
                .filter { $0.kind == .passport }
            falsePos += matches.count
        }
        let recall = Double(truePos) / Double(truePos + falseNeg)
        let precision = truePos + falsePos > 0
            ? Double(truePos) / Double(truePos + falsePos)
            : 1.0
        #expect(recall >= 0.90, "recall \(recall) below 0.90")
        #expect(precision >= 0.90, "precision \(precision) below 0.90")
    }

    @Test("Empty text yields no matches")
    func passportEmptyText() async {
        let matches = await detector.detect(in: "", doctype: nil)
        #expect(!matches.contains { $0.kind == .passport })
    }

    // MARK: - W1 validation gate (D-14)

    // The default `detector` (line 12) loads PassportPatternGazetteer via
    // `(try? PassportPatternGazetteer())`, so every test above also
    // exercises the W1 path — the existing labeled-prefix recall samples
    // were verified at chain start to all match ≥1 of the 11 shipping
    // issuers' patterns (CA-legacy 2L+6D for AB1234567/CD345678/etc.;
    // IN strict/lenient 1L+7D for A1234567/D4567890/etc.; MX/VN/US-current
    // 1L+8D for B23456789). The tests below explicitly probe the gate's
    // accept/suppress/inert/case-normalisation behaviour and the multi-
    // issuer audit-only surface.

    @Test("W1 keeps candidate matching one issuer (IN strict 1L+7D)")
    func testW1KeepsSingleIssuerMatch() async {
        let detector = PIIDetector(nameGazetteer: nil)
        // A1234567 — 8-char 1L+7D. IN strict ^[A-PR-WY][1-9][0-9]{5}[1-9]$
        // accepts (A valid prefix; 1 nonzero; 23456 5-digit body; 7 nonzero);
        // IN lenient ^[A-Z][0-9]{7}$ also accepts. No other issuer admits
        // 1L+7D — CA expects 2L+6D legacy or 1L+6D+2L current; KR/MX/US/VN/CN
        // expect 9 chars; PH expects 1L+7D+1L; SV/DO/GB expect 9 chars.
        let matches = await detector.detect(in: "Passport: A1234567", doctype: nil)
            .filter { $0.kind == .passport }
        let hit = try! #require(matches.first)
        #expect(hit.text == "A1234567")
        #expect(abs(hit.confidence - 0.80) < 0.001,
                "W1 keeps the 0.80 baseline confidence")
    }

    @Test("W1 suppresses candidate matching no issuer (10-char 1L+9D)")
    func testW1SuppressesNoIssuerMatch() async {
        let detector = PIIDetector(nameGazetteer: nil)
        // A123456789 — 10-char 1L+9D. The inline regex captures the
        // candidate (`[A-Z]{1,2}\d{6,9}` admits 1-2 letters + 6-9 digits =
        // 7-11 chars total). All 11 issuers' patterns top out at 9 chars
        // — no shipping row admits 10 chars at any arm. The gate suppresses.
        let matches = await detector.detect(in: "Passport: A123456789", doctype: nil)
            .filter { $0.kind == .passport }
        #expect(matches.isEmpty,
                "Candidate with no issuer match must be suppressed under W1")
    }

    @Test("W1 inert when passport gazetteer absent (test-bundle-only fallback)")
    func testW1InertWhenGazetteerNil() async {
        // Same 10-char input as the suppression test above. With the
        // passport gazetteer explicitly nil, W1 is bypassed and the
        // candidate flows through (pre-W1 behavior preserved for builds
        // that strip the JSON resource).
        let detector = PIIDetector(
            nameGazetteer: nil,
            dlPatternGazetteer: nil,
            passportPatternGazetteer: nil
        )
        let matches = await detector.detect(in: "Passport: A123456789", doctype: nil)
            .filter { $0.kind == .passport }
        #expect(!matches.isEmpty,
                "Without gazetteer, W1 gate must not fire — pass-through behavior")
    }

    @Test("W1 normalizes case before gazetteer lookup")
    func testW1CaseNormalization() async {
        let detector = PIIDetector(nameGazetteer: nil)
        // The inline regex is case-insensitive, so it captures a lowercase
        // candidate. The gazetteer's per-issuer patterns are case-sensitive
        // (every row has an A-Z alphabet). W1 must uppercase the candidate
        // before lookup so OCR-noise lowercase still passes the gate.
        // ab123456 → AB123456 → matches CA-legacy ^[A-Z]{2}[0-9]{6}$.
        let matches = await detector.detect(in: "passport: ab123456", doctype: nil)
            .filter { $0.kind == .passport }
        #expect(!matches.isEmpty,
                "Lowercase candidate captured by case-insensitive inline regex must pass W1 after uppercase normalization")
    }

    @Test("W1 keeps multi-issuer ambiguous candidate (PH-legacy + SV)")
    func testW1KeepsMultiIssuerCandidate() async {
        let detector = PIIDetector(nameGazetteer: nil)
        // AB1234567 — 9-char 2L+7D. Matches PH-legacy ^[A-Z]{2}[0-9]{7}$
        // and SV's permissive ^[A-Z0-9]{9}$. V1 audit-only multi-issuer
        // surface — the gate keeps the candidate without elevation.
        let matches = await detector.detect(in: "Passport: AB1234567", doctype: nil)
            .filter { $0.kind == .passport }
        let hit = try! #require(matches.first)
        #expect(hit.text == "AB1234567")
        #expect(abs(hit.confidence - 0.80) < 0.001,
                "Multi-issuer ambiguity preserves the 0.80 baseline (no haircut)")
    }
}
