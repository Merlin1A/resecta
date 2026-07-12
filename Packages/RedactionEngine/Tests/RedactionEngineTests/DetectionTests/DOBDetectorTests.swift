import Testing
import Foundation
@testable import RedactionEngine

// Plan Phase 3 / §4 — DOBDetector with age-proximity + label boosts.

@Suite("DOB detector (structured)")
struct DOBDetectorTests {

    private func confidence(of text: String, matching expected: String) -> Double? {
        let detector = DOBDetector()
        let ns = text as NSString
        let matches = detector.detect(in: ns, range: NSRange(location: 0, length: ns.length))
        return matches.first(where: { $0.text == expected })?.confidence
    }

    @Test("Label boost raises confidence above base")
    func labelBoost() {
        let bare = confidence(of: "Record number 3/15/1985 processed", matching: "3/15/1985")
        let withLabel = confidence(of: "DOB: 3/15/1985", matching: "3/15/1985")
        if let bare, let withLabel {
            #expect(withLabel > bare)
        }
    }

    @Test("Age proximity on same line adds confidence")
    func ageProximity() {
        let withAge = confidence(of: "Patient, age 52, 3/15/1985 initial visit", matching: "3/15/1985")
        let baseline = confidence(of: "Processed 3/15/1985 confirmed", matching: "3/15/1985")
        if let withAge, let baseline {
            #expect(withAge >= baseline)
        }
    }

    @Test("Structurally invalid date is rejected")
    func invalidDateRejected() {
        // Month 13 invalid.
        let text = "DOB: 13/15/1985 invalid entry"
        let detector = DOBDetector()
        let ns = text as NSString
        let matches = detector.detect(in: ns, range: NSRange(location: 0, length: ns.length))
        #expect(!matches.contains(where: { $0.text == "13/15/1985" }))
    }

    @Test("Far-future year rejected")
    func farFutureYearRejected() {
        let text = "Received 3/15/2099 — pending confirmation"
        let detector = DOBDetector()
        let ns = text as NSString
        let matches = detector.detect(in: ns, range: NSRange(location: 0, length: ns.length))
        #expect(!matches.contains(where: { $0.text == "3/15/2099" }))
    }

    @Test("Two-digit year interpreted into plausible range")
    func twoDigitYear() {
        #expect(DOBDetector.isStructurallyValid("3/15/85"))   // 1985
        #expect(DOBDetector.isStructurallyValid("3/15/25"))   // 2025
    }

    // L-03 / L-16 — per-month day caps + Gregorian leap-year rule

    @Test("Feb 29 accepted in Gregorian leap years", arguments: [
        "2/29/2020",
        "2/29/2000",
        "2/29/2024",
    ])
    func leapYearFeb29ValidYears(_ input: String) {
        #expect(DOBDetector.isStructurallyValid(input),
                "Feb 29 should be valid for '\(input)'")
    }

    @Test("Feb 29 rejected in non-leap years", arguments: [
        "2/29/2021",  // Not divisible by 4
        "2/29/1900",  // Divisible by 100 but not 400 — not a leap year
        "2/29/2023",  // Not divisible by 4
    ])
    func nonLeapYearFeb29Rejected(_ input: String) {
        #expect(!DOBDetector.isStructurallyValid(input),
                "Feb 29 should be rejected for '\(input)'")
    }

    @Test("Two-digit leap years use expanded century", arguments: [
        "2/29/20",  // 2020
        "2/29/00",  // 2000
        "2/29/24",  // 2024
    ])
    func twoDigitLeapYearExpandsBeforeLeapCheck(_ input: String) {
        #expect(DOBDetector.isStructurallyValid(input),
                "Expanded two-digit leap year should be valid for '\(input)'")
    }

    @Test("30-day months reject day 31", arguments: [
        "4/31/2020",   // April
        "6/31/2020",   // June
        "9/31/2020",   // September
        "11/31/2020",  // November
    ])
    func thirtyDayMonthsRejectDay31(_ input: String) {
        #expect(!DOBDetector.isStructurallyValid(input),
                "30-day months should reject day 31 for '\(input)'")
    }

    @Test("31-day month maxima accepted", arguments: [
        "1/31/2020",   // January
        "3/31/2020",   // March
        "5/31/2020",   // May
        "7/31/2020",   // July
        "8/31/2020",   // August
        "10/31/2020",  // October
        "12/31/2020",  // December
    ])
    func thirtyOneDayMonthsMaximaAccepted(_ input: String) {
        #expect(DOBDetector.isStructurallyValid(input),
                "31-day month maxima should be valid for '\(input)'")
    }

    @Test("30-day month maxima accepted", arguments: [
        "4/30/2020",   // April
        "6/30/2020",   // June
        "9/30/2020",   // September
        "11/30/2020",  // November
    ])
    func thirtyDayMonthsMaximaAccepted(_ input: String) {
        #expect(DOBDetector.isStructurallyValid(input),
                "30-day month maxima should be valid for '\(input)'")
    }

    @Test("Feb 28 always accepted (leap or not)", arguments: [
        "2/28/2020",
        "2/28/2021",
        "2/28/1900",
    ])
    func feb28AlwaysValid(_ input: String) {
        #expect(DOBDetector.isStructurallyValid(input))
    }

    @Test("Feb 30 never accepted", arguments: [
        "2/30/2020",
        "2/30/2024",
    ])
    func feb30NeverValid(_ input: String) {
        #expect(!DOBDetector.isStructurallyValid(input))
    }

    // MARK: - D04-F2 A1 — numeric-DOB base-confidence margin

    @Test("Numeric labeled DOB clears the 0.30 Balanced/Conservative cutoff with margin")
    func numericLabeledClearsWithMargin() {
        let c = confidence(of: "DOB: 01/15/1985", matching: "01/15/1985")
        #expect(c != nil)
        // Must clear 0.30 and NOT by a sub-0.02 razor - guards base/boost retunes (D04-F2 A1).
        // After A1: base 0.05 + 0.30 label = 0.35 (was 0.31, a 0.01 razor).
        #expect((c ?? 0) >= 0.30 + 0.02)
    }

    @Test("Unlabeled textual DOB scores below the 0.30 Balanced cutoff (scope pin)")
    func unlabeledTextualBelowCutoff() {
        // 'on January 15, 1985 she filed' - no dob/born/age keyword in window.
        let c = confidence(of: "on January 15, 1985 she filed the claim",
                           matching: "January 15, 1985")
        // FLIP this assertion only if Variant A2 (J-DOB-SCOPE) ever ships.
        #expect((c ?? 0) < 0.30)
    }

    @Test("Labeled numeric and textual DOB land at the same boosted confidence")
    func labeledPathParity() {
        let num = confidence(of: "DOB: 01/15/1985", matching: "01/15/1985")
        let txt = confidence(of: "DOB: January 15, 1985", matching: "January 15, 1985")
        // Both base 0.05 + 0.30 label = 0.35 after A1 reconciles the numeric base.
        #expect(num == txt)
    }
}
