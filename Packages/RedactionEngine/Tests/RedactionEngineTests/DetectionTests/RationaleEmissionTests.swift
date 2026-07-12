import Testing
import Foundation
@testable import RedactionEngine

// W1 — verify that every PII detector path populates a MatchRationale.
// SSN and Name emit structured rationale (bespoke signals). The rest of
// the detectors rely on the `ensureRationales` fallback in `detect()`,
// which stamps a generic `regexPattern` signal and copies the confidence
// into both pre- and final-score fields.

@Suite("MatchRationale emission")
struct RationaleEmissionTests {

    @Test("SSN emits structural validator + regex signals")
    func ssnRationaleIsStructured() async {
        let detector = PIIDetector()
        let text = "SSN: 123-45-6789 on file."
        let matches = await detector.detect(in: text)
        let ssn = matches.first { $0.kind == .ssn }
        #expect(ssn != nil)
        let rationale = try! #require(ssn?.rationale)
        #expect(rationale.ruleID == "ssn.state-machine")

        let signalTags = rationale.signals.map(Self.tag)
        #expect(signalTags.contains("regexPattern"))
        #expect(signalTags.contains("structuralValidator"))
        // Positive-context keyword "SSN:" should bump the score into the
        // contextPositive band.
        #expect(signalTags.contains("contextPositive"))
        #expect(rationale.finalScore >= rationale.preThresholdScore)
    }

    @Test("Name (NLTagger) emits regex signal with pre-threshold baseline")
    func nameRationaleIsPopulated() async {
        // Inject nil gazetteer so this test stays focused on the W1 wiring
        // and doesn't observe W2's per-candidate boosts (which can make
        // finalScore > preThresholdScore).
        let detector = PIIDetector(nameGazetteer: nil)
        let text = "Patient: Maria Johnson was admitted."
        let matches = await detector.detect(in: text)
        let name = matches.first { $0.kind == .name }
        #expect(name != nil)
        let rationale = try! #require(name?.rationale)
        #expect(rationale.ruleID == "name.nltagger")
        #expect(rationale.signals.contains(.regexPattern(name: "name.nltagger")))
        #expect(rationale.preThresholdScore == rationale.finalScore)
    }

    @Test("Simple regex detectors get fallback rationale")
    func emailFallsBackToGenericRationale() async {
        let detector = PIIDetector()
        let text = "Contact: jane@example.com for scheduling."
        let matches = await detector.detect(in: text)
        let email = matches.first { $0.kind == .email }
        #expect(email != nil)
        let rationale = try! #require(email?.rationale)
        #expect(rationale.ruleID == "email.regex")
        #expect(rationale.signals.contains(.regexPattern(name: "email.regex")))
        #expect(rationale.finalScore == email?.confidence)
    }

    @Test("Doctype gate signal appears when doctype is supplied")
    func doctypeGateSignalPresent() async {
        let detector = PIIDetector()
        let text = "DEA Number: AB1234563"
        let matches = await detector.detect(in: text, doctype: .medical)
        let dea = matches.first { $0.kind == .dea }
        #expect(dea != nil)
        let rationale = try! #require(dea?.rationale)
        #expect(rationale.signals.contains(.doctypeGate(doctype: .medical)))
    }

    @Test("Every detector pass leaves a non-nil rationale")
    func allHitsCarryRationale() async {
        let detector = PIIDetector()
        let text = """
        SSN: 123-45-6789
        Email: jane@example.com
        Phone: (555) 123-4567
        MRN: 0012345
        Card: 4111 1111 1111 1111
        Patient: Maria Johnson
        """
        let matches = await detector.detect(in: text, doctype: .medical)
        #expect(!matches.isEmpty)
        for match in matches {
            #expect(match.rationale != nil,
                    "every PIIMatch must carry a rationale after ensureRationales; \(match.kind) did not")
        }
    }

    // MARK: - Helpers

    private static func tag(_ signal: MatchRationale.Signal) -> String {
        switch signal {
        case .regexPattern:           "regexPattern"
        case .structuralValidator:    "structuralValidator"
        case .contextPositive:        "contextPositive"
        case .contextNegative:        "contextNegative"
        case .bloomSurnameHit:        "bloomSurnameHit"
        case .bloomGivenHit:          "bloomGivenHit"
        case .bloomFuzzySurnameHit:   "bloomFuzzySurnameHit"
        case .doctypeGate:            "doctypeGate"
        case .presetThresholdPass:    "presetThresholdPass"
        case .ocrConfidence:          "ocrConfidence"
        case .userAlwaysFlag:         "userAlwaysFlag"
        case .userNeverFlag:          "userNeverFlag"
        case .suppressedByOverlap:    "suppressedByOverlap"
        case .contextPositiveDetail:  "contextPositiveDetail"
        case .contextNegativeDetail:  "contextNegativeDetail"
        case .negativeContextSuppressed: "negativeContextSuppressed"
        }
    }
}
