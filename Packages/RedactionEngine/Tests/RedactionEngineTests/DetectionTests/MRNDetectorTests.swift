import Testing
import Foundation
@testable import RedactionEngine

// W10 — MRN detector: three labeled patterns + context scoring + doctype gate.
//
// Documented exceptions to the "every old-alternation hit preserved" rule:
// none. The pre-W10 alternation only captured `\d{4,12}` after an MRN/Patient
// label. Every such digit-only hit is covered by `mrnPatternLabeled` (widened
// to `[A-Z0-9]{5,12}` — covers the G8 corpus alphanumeric shape too) or by
// `mrnPatternPatientID`.

@Suite("MRN detector (W10)")
struct MRNDetectorTests {

    private let detector = PIIDetector(nameGazetteer: nil)

    // MARK: - Pattern coverage

    @Test("Labeled MRN pattern fires on chart note")
    func mrnLabeledPatternFiresOnChartNote() async {
        let text = "Chart number MRN: 12345678 reviewed by physician."
        let matches = await detector.detect(in: text, doctype: .medical)
        let mrn = matches.first { $0.kind == .medicalRecord }
        #expect(mrn != nil)
        #expect(mrn?.rationale?.ruleID == "mrn.labeled")
        let confidence = try! #require(mrn?.confidence)
        #expect(confidence >= 0.85,
                "positive medical context should push into the boosted band (got \(confidence))")
    }

    @Test("Patient ID pattern fires with medical context")
    func mrnPatientIDPatternFiresWithContext() async {
        let text = "Patient ID: QD793210 admitted for diagnosis review."
        let matches = await detector.detect(in: text, doctype: .medical)
        let mrn = matches.first { $0.kind == .medicalRecord }
        #expect(mrn != nil)
        #expect(mrn?.rationale?.ruleID == "mrn.patientID")
    }

    @Test("Institution-prefixed MRN fires with medical context")
    func mrnInstitutionPatternFiresWithContext() async {
        let text = "Community Hospital chart ABC-1234567 discharge summary follows."
        let matches = await detector.detect(in: text, doctype: .medical)
        let mrn = matches.first { $0.kind == .medicalRecord }
        #expect(mrn != nil)
        #expect(mrn?.rationale?.ruleID == "mrn.institution")
    }

    // MARK: - Doctype gating

    @Test("MRN is suppressed on financial doctype")
    func mrnSuppressedOnFinancialDoctype() async {
        let text = "MRN: 12345678 on the receipt line."
        let matches = await detector.detect(in: text, doctype: .financial)
        #expect(!matches.contains { $0.kind == .medicalRecord })
    }

    @Test("MRN runs permissively when doctype is nil")
    func mrnRunsOnNilDoctype() async {
        let text = "MRN: 12345678 in a free-floating note."
        let matches = await detector.detect(in: text, doctype: nil)
        #expect(matches.contains { $0.kind == .medicalRecord })
    }

    // MARK: - Context scoring

    @Test("Negative context (receipt/order) suppresses confidence")
    func mrnNegativeContextSuppresses() async {
        let text = "Order receipt MRN: 12345678 shipping tracking number."
        let matches = await detector.detect(in: text, doctype: nil)
        let mrn = matches.first { $0.kind == .medicalRecord }
        #expect(mrn != nil)
        let conf = try! #require(mrn?.confidence)
        // Negative context dampens below the base 0.55 but not below the
        // floor 0.15.
        #expect(conf < 0.55)
        #expect(conf >= 0.15)
    }

    @Test("MRN rationale carries regexPattern signal")
    func mrnEmitsRegexPatternSignal() async {
        let text = "Patient MRN: 00012345 admitted."
        let matches = await detector.detect(in: text, doctype: .medical)
        let mrn = matches.first { $0.kind == .medicalRecord }
        let rationale = try! #require(mrn?.rationale)
        #expect(rationale.signals.contains(.regexPattern(name: "mrn.labeled")))
    }

    @Test("Boosted context yields a contextPositive signal")
    func mrnEmitsContextPositiveWhenBoosted() async {
        let text = "Hospital discharge summary. Patient chart MRN: 98765432 reviewed by physician."
        let matches = await detector.detect(in: text, doctype: .medical)
        let mrn = matches.first { $0.kind == .medicalRecord }
        let rationale = try! #require(mrn?.rationale)
        let hasPositive = rationale.signals.contains { signal in
            if case .contextPositive = signal { return true }
            return false
        }
        #expect(hasPositive,
                "positive medical keywords in the window should emit .contextPositive")
    }

    // MARK: - G8 corpus regression

    @Test("Every old-alternation hit is covered by the new detector (G8 medical slice)")
    func mrnAlternationRegressionOnG8Medical() async throws {
        guard let corpus = try loadCorpus() else { return }
        let medical = corpus.documents.filter { $0.doctype == "medical" }
        // Pre-W10 pattern — kept inline for regression parity.
        let oldPattern = try NSRegularExpression(
            pattern: #"(?:MRN|Medical\s+Record|Patient\s+ID|Medical\s+ID)\s*[#:]?\s*(\d{4,12})"#,
            options: [.caseInsensitive]
        )

        var oldHits = 0
        var coveredByNew = 0
        for doc in medical {
            let ns = doc.text as NSString
            let fullRange = NSRange(location: 0, length: ns.length)
            let matches = oldPattern.matches(in: doc.text, range: fullRange)
            guard !matches.isEmpty else { continue }
            oldHits += matches.count

            let newMatches = await detector.detect(in: doc.text, doctype: .medical)
                .filter { $0.kind == .medicalRecord }
            for oldMatch in matches {
                let digitRange = oldMatch.range(at: 1)
                let digits = ns.substring(with: digitRange)
                if newMatches.contains(where: { $0.text.contains(digits) }) {
                    coveredByNew += 1
                }
            }
        }
        #expect(coveredByNew == oldHits,
                "regression: \(oldHits - coveredByNew) old-alternation hits not covered by new patterns")
    }

    @Test("Medical-slice recall clears 40 %")
    func mrnMedicalSliceRecall() async throws {
        guard let corpus = try loadCorpus() else { return }
        let medical = corpus.documents.filter { $0.doctype == "medical" }
        var spansSeen = 0
        var spansHit = 0
        for doc in medical {
            let spans = doc.pii_spans.filter { $0.category == "mrn" }
            guard !spans.isEmpty else { continue }
            let results = await detector.detect(in: doc.text, doctype: .medical)
                .filter { $0.kind == .medicalRecord }
            for span in spans {
                spansSeen += 1
                if results.contains(where: { $0.text.contains(span.value) }) {
                    spansHit += 1
                }
            }
        }
        guard spansSeen > 0 else { return }
        let recall = Double(spansHit) / Double(spansSeen)
        #expect(recall >= 0.40,
                "medical-slice recall \(recall) below 0.40 floor")
    }

    // MARK: - Corpus loader

    private func loadCorpus() throws -> G8CorpusIngestionTests.G8Corpus? {
        guard let url = Bundle.module.url(
            forResource: "g8_corpus",
            withExtension: "json",
            subdirectory: "corpus"
        ) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(G8CorpusIngestionTests.G8Corpus.self, from: data)
    }
}
