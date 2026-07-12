import Testing
import Foundation
@testable import RedactionEngine

// A6: SSN state machine, structural validator, and context scoring tests.

@Suite("SSN Detection (A6)", .tags(.security))
struct SSNDetectionTests {

    // MARK: - State Machine: Valid Formats

    @Test("State machine finds standard dashed SSN")
    func stateMachineDashed() {
        let sm = SSNStateMachine()
        let candidates = sm.scan("123-45-6789")
        #expect(candidates.count == 1)
        #expect(candidates.first?.area == "123")
        #expect(candidates.first?.group == "45")
        #expect(candidates.first?.serial == "6789")
        #expect(candidates.first?.separator == "-")
    }

    @Test("State machine finds space-separated SSN")
    func stateMachineSpaced() {
        let sm = SSNStateMachine()
        let candidates = sm.scan("123 45 6789")
        #expect(candidates.count == 1)
        #expect(candidates.first?.separator == " ")
    }

    @Test("State machine finds unseparated SSN")
    func stateMachineUnseparated() {
        let sm = SSNStateMachine()
        let candidates = sm.scan("123456789")
        #expect(candidates.count == 1)
        #expect(candidates.first?.separator == nil)
        #expect(candidates.first?.matchedText == "123456789")
    }

    @Test("State machine finds SSN with typographic dashes", arguments: [
        ("\u{2011}", "non-breaking hyphen"),
        ("\u{2012}", "figure dash"),
        ("\u{2013}", "en-dash"),
        ("\u{2014}", "em-dash"),
    ] as [(String, String)])
    func stateMachineTypographicDashes(_ dash: String, _ name: String) {
        let sm = SSNStateMachine()
        let input = "123\(dash)45\(dash)6789"
        let candidates = sm.scan(input)
        #expect(candidates.count == 1, "Expected match with \(name)")
    }

    @Test("State machine finds SSN in surrounding text")
    func stateMachineInContext() {
        let sm = SSNStateMachine()
        let candidates = sm.scan("SSN: 123-45-6789 is the number")
        #expect(candidates.count == 1)
        #expect(candidates.first?.matchedText == "123-45-6789")
    }

    @Test("State machine finds multiple SSNs")
    func stateMachineMultiple() {
        let sm = SSNStateMachine()
        let candidates = sm.scan("First: 123-45-6789, Second: 234-56-7890")
        #expect(candidates.count == 2)
    }

    // MARK: - State Machine: Boundary Enforcement

    @Test("State machine rejects SSN preceded by digit")
    func stateMachineLeadingDigit() {
        let sm = SSNStateMachine()
        let candidates = sm.scan("0123-45-6789")
        #expect(candidates.isEmpty, "Should not match when preceded by digit")
    }

    @Test("State machine rejects SSN followed by digit")
    func stateMachineTrailingDigit() {
        let sm = SSNStateMachine()
        let candidates = sm.scan("123-45-67890")
        #expect(candidates.isEmpty, "Should not match when followed by digit")
    }

    @Test("State machine rejects mixed separators")
    func stateMachineMixedSeparators() {
        let sm = SSNStateMachine()
        // Hyphen then space
        let candidates1 = sm.scan("123-45 6789")
        #expect(candidates1.isEmpty, "Mixed separators should be rejected")
        // En-dash then hyphen
        let candidates2 = sm.scan("123\u{2013}45-6789")
        #expect(candidates2.isEmpty, "Mixed dash types should be rejected")
    }

    // MARK: - State Machine: Performance

    @Test("State machine runs in O(n) time",
          .timeLimit(.minutes(1)))
    func stateMachinePerformance() {
        let sm = SSNStateMachine()
        // 100,000 characters — should complete well under 1 second for O(n)
        let text = String(repeating: "Hello world 123 test data ", count: 4000)
        let start = ContinuousClock.now
        _ = sm.scan(text)
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .milliseconds(100), "O(n) scan of 100K chars should be < 100ms")
    }

    // MARK: - Structural Validator

    @Test("Validator rejects area 000")
    func validatorArea000() {
        let v = SSNStructuralValidator()
        let c = SSNCandidate(area: "000", group: "45", serial: "6789", range: NSRange(), separator: "-", matchedText: "")
        #expect(!v.isValid(c))
    }

    @Test("Validator rejects area 666")
    func validatorArea666() {
        let v = SSNStructuralValidator()
        let c = SSNCandidate(area: "666", group: "45", serial: "6789", range: NSRange(), separator: "-", matchedText: "")
        #expect(!v.isValid(c))
    }

    @Test("Validator rejects area 900-999", arguments: ["900", "950", "999"])
    func validatorArea900(area: String) {
        let v = SSNStructuralValidator()
        let c = SSNCandidate(area: area, group: "45", serial: "6789", range: NSRange(), separator: "-", matchedText: "")
        #expect(!v.isValid(c))
    }

    @Test("Validator rejects group 00")
    func validatorGroup00() {
        let v = SSNStructuralValidator()
        let c = SSNCandidate(area: "123", group: "00", serial: "6789", range: NSRange(), separator: "-", matchedText: "")
        #expect(!v.isValid(c))
    }

    @Test("Validator rejects serial 0000")
    func validatorSerial0000() {
        let v = SSNStructuralValidator()
        let c = SSNCandidate(area: "123", group: "45", serial: "0000", range: NSRange(), separator: "-", matchedText: "")
        #expect(!v.isValid(c))
    }

    @Test("Validator rejects Woolworth SSN (078-05-1120)")
    func validatorWoolworth() {
        let v = SSNStructuralValidator()
        let c = SSNCandidate(area: "078", group: "05", serial: "1120", range: NSRange(), separator: "-", matchedText: "")
        #expect(!v.isValid(c))
    }

    @Test("Validator rejects all-same-digit sequences", arguments: [
        ("111", "11", "1111"),
        ("222", "22", "2222"),
        ("333", "33", "3333"),
        ("444", "44", "4444"),
        ("555", "55", "5555"),
        ("666", "66", "6666"),  // Also rejected by area rule
        ("777", "77", "7777"),
        ("888", "88", "8888"),
    ] as [(String, String, String)])
    func validatorAllSameDigit(_ area: String, _ group: String, _ serial: String) {
        let v = SSNStructuralValidator()
        let c = SSNCandidate(area: area, group: group, serial: serial, range: NSRange(), separator: "-", matchedText: "")
        #expect(!v.isValid(c))
    }

    @Test("Validator accepts structurally valid SSN")
    func validatorAcceptsValid() {
        let v = SSNStructuralValidator()
        let c = SSNCandidate(area: "123", group: "45", serial: "6789", range: NSRange(), separator: "-", matchedText: "")
        #expect(v.isValid(c))
    }

    // MARK: - Context Window Scorer

    @Test("Positive keyword boosts confidence to 0.95")
    func contextPositiveBoost() {
        let scorer = ContextWindowScorer()
        let text = "SSN: 123-45-6789 is listed"
        let range = NSRange(location: 5, length: 11)
        let confidence = scorer.score(text: text, matchRange: range, profile: SSNContextKeywords.profile)
        #expect(confidence >= 0.95)
    }

    @Test("No keywords produces base confidence 0.75")
    func contextBaseConfidence() {
        let scorer = ContextWindowScorer()
        let text = "The number 123-45-6789 appears here"
        let range = NSRange(location: 11, length: 11)
        let confidence = scorer.score(text: text, matchRange: range, profile: SSNContextKeywords.profile)
        #expect(confidence == 0.75)
    }

    @Test("Negative keyword dampens but stays above floor 0.25")
    func contextNegativeDampening() {
        let scorer = ContextWindowScorer()
        let text = "Case number 123-45-6789 in the filing"
        let range = NSRange(location: 12, length: 11)
        let confidence = scorer.score(text: text, matchRange: range, profile: SSNContextKeywords.profile)
        #expect(confidence >= 0.25, "Floor must not be breached")
        #expect(confidence < 0.75, "Negative context should dampen below base")
    }

    @Test("Floor cannot be breached by multiple negative keywords")
    func contextFloorEnforcement() {
        let scorer = ContextWindowScorer()
        let text = "Case number docket invoice reference tracking 123-45-6789 claim order"
        let range = NSRange(location: 47, length: 11)
        let confidence = scorer.score(text: text, matchRange: range, profile: SSNContextKeywords.profile)
        #expect(confidence >= 0.25, "Floor of 0.25 must never be breached")
    }

    @Test("Date collision dampener produces score <= 0.05")
    func contextDateCollision() {
        let scorer = ContextWindowScorer()
        // SSN-shaped digits embedded in a date: 01/23/4567 89 -> not quite right.
        // More realistic: "12/34/5678" contains the digit sequence 123456789.
        // Use a date pattern that fully contains the match range.
        let text = "Filed on 01/23/4567"
        // The date pattern \d{1,2}/\d{1,2}/\d{2,4} matches "01/23/4567".
        // But this contains the SSN-shaped digits. The SSN state machine would produce
        // a different range. Let's test with the scorer directly.
        let range = NSRange(location: 9, length: 10) // "01/23/4567"
        let confidence = scorer.score(text: text, matchRange: range, profile: SSNContextKeywords.profile)
        #expect(confidence <= 0.05, "Date collision should produce score <= 0.05")
    }

    // MARK: - Integration: Full Pipeline

    @Test("Full pipeline detects SSN with context scoring")
    func fullPipelineSSN() async {
        let detector = PIIDetector()
        let text = "SSN: 123-45-6789 is the social security number"
        let results = await detector.detect(in: text)
        let ssnResults = results.filter { $0.kind == .ssn }
        #expect(!ssnResults.isEmpty, "Should detect SSN")
        #expect(ssnResults.first!.confidence >= 0.90, "Context should boost to >= 0.90")
    }

    @Test("Full pipeline rejects structurally invalid SSNs")
    func fullPipelineRejectsInvalid() async {
        let detector = PIIDetector()
        let text = "Numbers: 000-45-6789 and 666-12-3456 and 078-05-1120"
        let results = await detector.detect(in: text)
        let ssnResults = results.filter { $0.kind == .ssn }
        #expect(ssnResults.isEmpty, "All three should be rejected by structural validation")
    }

    @Test("Full pipeline finds valid SSN with base confidence")
    func fullPipelineBaseConfidence() async {
        let detector = PIIDetector()
        let text = "The number is 234-56-7890 in the record"
        let results = await detector.detect(in: text)
        let ssnResults = results.filter { $0.kind == .ssn }
        #expect(!ssnResults.isEmpty)
        #expect(ssnResults.first!.confidence == 0.75, "No context -> base confidence")
    }

    @Test("Full pipeline: negative context dampens SSN confidence")
    func fullPipelineNegativeContext() async {
        let detector = PIIDetector()
        let text = "Case number 234-56-7890 in the docket filing"
        let results = await detector.detect(in: text)
        let ssnResults = results.filter { $0.kind == .ssn }
        #expect(!ssnResults.isEmpty, "Should still detect with floor")
        #expect(ssnResults.first!.confidence >= 0.25, "Floor enforced")
        #expect(ssnResults.first!.confidence < 0.75, "Dampened below base")
    }
}
