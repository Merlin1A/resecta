import Testing
import Foundation
@testable import RedactionEngine

// W10 — License-plate detector.
// Labeled-only pattern (License plate / Plate No / Tag # / LP # / Reg #
// / Vehicle plate) followed by a 2–3+2–5 alphanumeric plate value.
// Doctype-gated: court / FOIA / generic / nil.

@Suite("License plate detector (W10)")
struct LicensePlateDetectorTests {

    private let detector = PIIDetector(nameGazetteer: nil)

    // MARK: - Labeled-pattern coverage

    @Test("Fires on explicit License plate label")
    func licensePlateFiresOnLabeledContext() async {
        let text = "Vehicle owner registration — License plate: 3ABC123 issued by DMV."
        let matches = await detector.detect(in: text, doctype: .court)
        let plate = matches.first { $0.kind == .licensePlate }
        #expect(plate != nil)
        #expect(plate?.rationale?.ruleID == "licensePlate.labeled")
    }

    // MARK: - Doctype gating

    @Test("Suppressed on medical doctype")
    func licensePlateSuppressedOnMedicalDoctype() async {
        let text = "License plate: 3ABC123 noted during admission."
        let matches = await detector.detect(in: text, doctype: .medical)
        #expect(!matches.contains { $0.kind == .licensePlate })
    }

    @Test("Suppressed on financial doctype")
    func licensePlateSuppressedOnFinancialDoctype() async {
        let text = "License plate: 3ABC123 referenced on the receipt."
        let matches = await detector.detect(in: text, doctype: .financial)
        #expect(!matches.contains { $0.kind == .licensePlate })
    }

    @Test("Runs on generic doctype")
    func licensePlateRunsOnGenericDoctype() async {
        let text = "Vehicle License plate: 3ABC123 noted in file."
        let matches = await detector.detect(in: text, doctype: .generic)
        #expect(matches.contains { $0.kind == .licensePlate })
    }

    @Test("Runs on nil doctype")
    func licensePlateRunsOnNilDoctype() async {
        let text = "License plate: 3ABC123 observed."
        let matches = await detector.detect(in: text, doctype: nil)
        #expect(matches.contains { $0.kind == .licensePlate })
    }

    // MARK: - Rationale

    @Test("Emits regexPattern signal")
    func licensePlateEmitsRationale() async {
        let text = "Vehicle owner License plate: 7XYZ989 on file."
        let matches = await detector.detect(in: text, doctype: .court)
        let plate = matches.first { $0.kind == .licensePlate }
        let rationale = try! #require(plate?.rationale)
        #expect(rationale.signals.contains(.regexPattern(name: "licensePlate.labeled")))
    }

    // MARK: - Synthetic recall / precision

    @Test("Synthetic corpus recall clears 40 % precision clears 80 %")
    func licensePlateRecallOnSyntheticCorpus() async {
        struct Sample { let text: String; let expected: Int }
        let positives: [Sample] = [
            Sample(text: "Vehicle owner License plate: 3ABC123 in file.", expected: 1),
            Sample(text: "DMV registration Plate No: 7XYZ 989 renewed.", expected: 1),
            Sample(text: "Driver tag number: 8-BCD-456 issued.", expected: 1),
            Sample(text: "Motorcycle plate # AB1234 listed.", expected: 1),
            Sample(text: "Registration LP # 5FGH 678 active.", expected: 1),
            Sample(text: "Vehicle Reg # 2MN-456 issued last year.", expected: 1),
            Sample(text: "Truck plate number: 4PQR-789 on registration.", expected: 1),
            Sample(text: "Car owner Vehicle plate: 6STU-321 registered.", expected: 1),
            Sample(text: "Vehicle plate number 9WX-876 on DMV record.", expected: 1),
            Sample(text: "Registration tag no: 1AB-234 in the database.", expected: 1),
        ]
        let negatives: [String] = [
            "Order SKU 3ABC-123 shipped yesterday.",
            "Part number 7XYZ-989 on the invoice.",
            "Product code LP 5FGH out of stock.",
            "Barcode serial 1AB-234 on the packaging.",
            "License fee order 3ABC123 paid online.",
        ]
        var truePos = 0
        var falseNeg = 0
        var falsePos = 0
        for sample in positives {
            let matches = await detector.detect(in: sample.text, doctype: .court)
                .filter { $0.kind == .licensePlate }
            let hit = min(matches.count, sample.expected)
            truePos += hit
            falseNeg += sample.expected - hit
        }
        for neg in negatives {
            let matches = await detector.detect(in: neg, doctype: .court)
                .filter { $0.kind == .licensePlate
                    && $0.confidence >= LicensePlateContextKeywords.profile.baseConfidence }
            falsePos += matches.count
        }
        let recall = Double(truePos) / Double(truePos + falseNeg)
        let precision = truePos + falsePos > 0
            ? Double(truePos) / Double(truePos + falsePos)
            : 1.0
        #expect(recall >= 0.40, "recall \(recall) below 0.40")
        #expect(precision >= 0.80, "precision \(precision) below 0.80")
    }

    @Test("Unlabeled plate value is ignored")
    func licensePlateUnlabeledIgnored() async {
        let text = "3ABC123 appeared in the report without a label."
        let matches = await detector.detect(in: text, doctype: .court)
        #expect(!matches.contains { $0.kind == .licensePlate })
    }

    @Test("Empty text yields no matches")
    func licensePlateEmpty() async {
        let matches = await detector.detect(in: "", doctype: .court)
        #expect(matches.isEmpty)
    }
}
