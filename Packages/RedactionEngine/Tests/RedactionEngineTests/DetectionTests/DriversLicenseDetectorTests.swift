import Testing
import Foundation
@testable import RedactionEngine

// L-15 — dedicated DL-detector coverage: labeled-format recall, unlabeled
// rejection, L-02 numeric-minimum regression, doctype-agnostic behavior, and
// confidence calibration. Mirrors DetectionTests/BatesDetectorTests.swift
// structure.

@Suite("Driver's License detector")
struct DriversLicenseDetectorTests {

    private let detector = PIIDetector(nameGazetteer: nil)

    // MARK: - Labeled-format regex coverage

    @Test("DL regex accepts labeled US formats", arguments: [
        "DL: A1234567",
        "Driver's License #B123456789",
        "DL A12345678901234",
        "Driver License: 123456789",
        "D.L. C9876543",
    ])
    func validDriversLicense(_ input: String) {
        let range = NSRange(location: 0, length: (input as NSString).length)
        let matches = PIIDetector.driversLicensePattern.matches(in: input, range: range)
        #expect(!matches.isEmpty, "Expected DL match for '\(input)'")
    }

    @Test("DL regex rejects unlabeled alphanumerics")
    func dlRejectsUnlabeled() {
        let input = "A1234567 is a code"
        let range = NSRange(location: 0, length: (input as NSString).length)
        let matches = PIIDetector.driversLicensePattern.matches(in: input, range: range)
        #expect(matches.isEmpty, "Should not match without DL label prefix")
    }

    // MARK: - L-02 regression: numeric minimum tightening (3 → 6)

    @Test("DL regex rejects short numeric IDs (< 6 digits)", arguments: [
        "DL: 123",
        "DL 12345",
        "Driver License: 12345",
    ])
    func dlRejects3Digit(_ input: String) {
        let range = NSRange(location: 0, length: (input as NSString).length)
        let matches = PIIDetector.driversLicensePattern.matches(in: input, range: range)
        #expect(matches.isEmpty,
                "Expected no DL match for '\(input)' — numeric portion too short")
    }

    @Test("DL regex accepts 6-digit numeric IDs (boundary)")
    func dlAccepts6Digit() {
        let input = "DL: 123456"
        let range = NSRange(location: 0, length: (input as NSString).length)
        let matches = PIIDetector.driversLicensePattern.matches(in: input, range: range)
        #expect(!matches.isEmpty, "Expected DL match at 6-digit boundary")
    }

    @Test("DL regex accepts 7-digit numeric IDs (existing shape)")
    func dlAccepts7Digit() {
        let input = "DL: 1234567"
        let range = NSRange(location: 0, length: (input as NSString).length)
        let matches = PIIDetector.driversLicensePattern.matches(in: input, range: range)
        #expect(!matches.isEmpty, "Expected DL match for 7-digit numeric ID")
    }

    // MARK: - Doctype-agnostic behavior

    @Test("DL detection is doctype-agnostic (runs on every doctype)",
          arguments: DoctypeClass.allCases)
    func dlRunsOnEveryDoctype(_ doctype: DoctypeClass) async {
        let text = "DL: A1234567 on file."
        let matches = await detector.detect(in: text, doctype: doctype)
        #expect(matches.contains { $0.kind == .driversLicense },
                "Expected DL detection for doctype \(doctype)")
    }

    @Test("DL detection also runs on nil doctype (permissive)")
    func dlRunsOnNilDoctype() async {
        let text = "DL: A1234567"
        let matches = await detector.detect(in: text, doctype: nil)
        #expect(matches.contains { $0.kind == .driversLicense })
    }

    // MARK: - Confidence calibration

    @Test("DL confidence is calibrated to 0.80")
    func dlConfidenceIs80() async {
        let text = "DL: A1234567"
        let matches = await detector.detect(in: text, doctype: nil)
            .filter { $0.kind == .driversLicense }
        let hit = try! #require(matches.first)
        #expect(abs(hit.confidence - 0.80) < 0.001,
                "DL base confidence should be 0.80, got \(hit.confidence)")
    }

    // MARK: - Synthetic recall / precision

    @Test("Synthetic corpus recall/precision clears 90 %")
    func dlRecallPrecisionOnSyntheticCorpus() async {
        struct Sample { let text: String; let expected: Int }
        // ~15 positives across labeled formats.
        let positives: [Sample] = [
            Sample(text: "DL: A1234567 issued CA.", expected: 1),
            Sample(text: "Driver's License: B2345678 renewed.", expected: 1),
            Sample(text: "DL #C3456789 suspended pending review.", expected: 1),
            Sample(text: "Driver License D4567890 on file.", expected: 1),
            Sample(text: "D.L. E5678901 valid through 2030.", expected: 1),
            Sample(text: "DL: F67890123 presented at booking.", expected: 1),
            Sample(text: "Driver's License #G78901234 class C.", expected: 1),
            Sample(text: "DL H89012345 endorsements N.", expected: 1),
            Sample(text: "Driver License: I90123456 no restrictions.", expected: 1),
            Sample(text: "D.L. J01234567 CDL class A.", expected: 1),
            Sample(text: "DL: 123456 numeric-only, state KS.", expected: 1),
            Sample(text: "DL: 12345678 numeric-only, state NY.", expected: 1),
            Sample(text: "Driver's License: 123456789 NJ format.", expected: 1),
            Sample(text: "DL: K12345 alphanumeric, OH format.", expected: 1),
            Sample(text: "D.L. L5678901 renewed by mail.", expected: 1),
        ]
        // ~10 negatives without DL label context.
        let negatives: [String] = [
            "Case number A1234567 filed Jan.",
            "Invoice B2345678 paid in full.",
            "Order C3456789 shipped.",
            "Reference D4567890 in the letter.",
            "Part number E5678901 in stock.",
            "Docket no. 12345678 hearing set.",
            "Tracking number 1234567 delivered.",
            "Zip 12345 on the form.",
            "The quick brown fox jumps over the lazy dog.",
            "Temperature reading 98 today.",
        ]

        var truePos = 0
        var falseNeg = 0
        var falsePos = 0
        for sample in positives {
            let matches = await detector.detect(in: sample.text, doctype: nil)
                .filter { $0.kind == .driversLicense }
            let hit = min(matches.count, sample.expected)
            truePos += hit
            falseNeg += sample.expected - hit
        }
        for neg in negatives {
            let matches = await detector.detect(in: neg, doctype: nil)
                .filter { $0.kind == .driversLicense }
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
    func dlEmptyText() async {
        let matches = await detector.detect(in: "", doctype: nil)
        #expect(!matches.contains { $0.kind == .driversLicense })
    }
}
