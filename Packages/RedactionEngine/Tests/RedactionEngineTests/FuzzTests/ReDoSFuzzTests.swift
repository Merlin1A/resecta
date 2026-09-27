import Testing
import Foundation
@testable import RedactionEngine

// ReDoS fuzz against every compiled
// regex in PIIDetector and against validateRegexPattern's pre-screening. The
// fixture at Fixtures/fuzz/redos_payloads.json ships from DataPipeline.
//
// Contract: no (Resecta pattern × attacker payload) pair takes longer than
// PIIDetector.perPageRegexTimeout (5s). The invariant holds because
// validateRegexPattern strips nested-quantifier / overlapping-alternation
// shapes before any pattern reaches enumerateMatches — but we still fuzz the
// already-bundled patterns in case a hand-authored one slips through.

@Suite("ReDoS fuzz", .tags(.security, .critical))
struct ReDoSFuzzTests {

    // MARK: - Fixture

    /// Subset of the redos_payloads.json schema we read.
    struct Payload: Decodable {
        let id: String
        let attacker_input: String
        let pattern_class: String
    }

    struct PayloadFile: Decodable {
        let payloads: [Payload]
    }

    static func loadPayloads() throws -> [Payload] {
        guard let url = Bundle.module.url(
            forResource: "redos_payloads",
            withExtension: "json",
            subdirectory: "fuzz"
        ) else {
            Issue.record("redos_payloads.json missing from test bundle")
            return []
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PayloadFile.self, from: data).payloads
    }

    // MARK: - Pattern inventory

    /// All compiled regex patterns in PIIDetector, keyed by detector name.
    /// Updated when Phase-3 adds NPI/DEA/Address-spatial/DOB/Account detectors.
    static let piiPatterns: [(name: String, pattern: NSRegularExpression)] = [
        ("creditCard", CreditCardDetector.ccPattern),
        ("email",      EmailDetector.emailPattern),
        ("phone",      PhoneDetector.phonePattern),
        ("address",    AddressDetector.addressPattern),
        ("dob",        DOBDetector.dobPattern),
        ("itin",       ITINDetector.itinPattern),
        ("dl",         DriversLicenseDetector.driversLicensePattern),
        ("passport",   PassportDetector.passportPattern),
        ("mrn.labeled",     MRNDetector.mrnPatternLabeled),
        ("mrn.patientID",   MRNDetector.mrnPatternPatientID),
        ("mrn.institution", MRNDetector.mrnPatternInstitution),
        ("licensePlate.labeled", LicensePlateDetector.licensePlateLabeled),
    ]

    // MARK: - Tests

    @Test("Every PIIDetector pattern completes under 5 s on every ReDoS payload")
    func allPatternsLinearOnPayloads() throws {
        let payloads = try Self.loadPayloads()
        #expect(!payloads.isEmpty, "fixture must contain at least one payload")

        let ceiling = PIIDetector.perPageRegexTimeout

        for (name, pattern) in Self.piiPatterns {
            for payload in payloads {
                let start = ContinuousClock.now
                // .matches returns all matches; if the engine backtracks
                // catastrophically it will block this line for seconds.
                let nsText = payload.attacker_input as NSString
                let range = NSRange(location: 0, length: nsText.length)
                _ = pattern.matches(in: payload.attacker_input, range: range)
                let elapsed = ContinuousClock.now - start
                #expect(
                    elapsed < ceiling,
                    "detector=\(name) payload=\(payload.id) class=\(payload.pattern_class) elapsed=\(elapsed)"
                )
            }
        }
    }

    /// The search path's executor (`SearchCore.enumerateRegexMatches`, the
    /// `.reportProgress` discipline) stops each structured shape at the
    /// per-page budget even when a single match attempt backtracks: the
    /// progress block runs inside the attempt. The patterns are compiled
    /// directly — the gate refuses them — so the budget is what is measured.
    @Test("The search executor stops each structured shape at the per-page budget")
    func structuredShapesStopAtBudget() throws {
        func prose(_ n: Int) -> String {
            let words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot"]
            var s = ""
            var i = 0
            while s.count < n { s += words[i % words.count] + " "; i += 1 }
            return String(s.prefix(n))
        }
        func dotted(_ n: Int) -> String {
            var s = ""
            var i = 0
            while s.count < n { s += String(100 + (i % 800)) + "."; i += 1 }
            return String(s.prefix(n))
        }
        let run = String(repeating: "a", count: 10_000)
        let cases: [(String, String)] = [
            (#"(\w+ \w+)+!"#, prose(10_000)), (#"(\d+\.\d+)+x"#, dotted(10_000)),
            ("(a|aa){0,1000}c", run), ("(a|a){1,25}c", run),
            ("(a{1,25}){1,40}c", run), (#"\w*\w*\w*!"#, run),
        ]
        let budget = DocumentSearcher.perPageRegexTimeout
        for (pattern, text) in cases {
            let regex = try NSRegularExpression(pattern: pattern)
            let start = ContinuousClock.now
            var timedOut = false
            _ = SearchCore.enumerateRegexMatches(
                in: text, regex: regex, wholeWord: false, unconvertibleRangePasses: true,
                cap: nil, timeout: budget, startTime: start,
                onTimeout: { timedOut = true }, visit: { _ in true })
            let elapsed = ContinuousClock.now - start
            print("structured shape \(pattern): \(elapsed), stopped by the budget: \(timedOut)")
            #expect(elapsed < budget + .seconds(3),
                    "pattern \(pattern) ran \(elapsed) against a \(budget) budget")
        }
    }

    @Test("SSN state machine stays microsecond-fast on worst-case payloads")
    func ssnStateMachineLinear() throws {
        let payloads = try Self.loadPayloads()
        let sm = SSNStateMachine()
        let ceiling: Duration = .milliseconds(50) // generous; expected <1ms
        for payload in payloads {
            let start = ContinuousClock.now
            _ = sm.scan(payload.attacker_input)
            let elapsed = ContinuousClock.now - start
            #expect(
                elapsed < ceiling,
                "SSN state machine slow on payload=\(payload.id) elapsed=\(elapsed)"
            )
        }
    }
}
