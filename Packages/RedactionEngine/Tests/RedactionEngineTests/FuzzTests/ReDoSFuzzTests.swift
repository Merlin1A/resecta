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

@Suite("ReDoS fuzz (SEARCH_AND_REDACT §9.4)", .tags(.security, .critical))
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
        ("ssn",        PIIDetector.ssnPattern),
        ("creditCard", PIIDetector.ccPattern),
        ("email",      PIIDetector.emailPattern),
        ("phone",      PIIDetector.phonePattern),
        ("ein",        PIIDetector.einPattern),
        ("address",    PIIDetector.addressPattern),
        ("dob",        PIIDetector.dobPattern),
        ("itin",       PIIDetector.itinPattern),
        ("dl",         PIIDetector.driversLicensePattern),
        ("passport",   PIIDetector.passportPattern),
        ("mrn.labeled",     PIIDetector.mrnPatternLabeled),
        ("mrn.patientID",   PIIDetector.mrnPatternPatientID),
        ("mrn.institution", PIIDetector.mrnPatternInstitution),
        ("licensePlate.labeled", PIIDetector.licensePlateLabeled),
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

    @Test("validateRegexPattern rejects canonical nested-quantifier shapes")
    func validateRejectsNestedQuantifiers() {
        // F-001 — `validateRegexPattern` now delegates to
        // `RegexSafetyPrecheck.isLikelyPathological` in addition to the
        // original `hasNestedQuantifiers` heuristic. The combined check
        // covers both (group-with-quantifier)quantifier shapes and
        // unbounded group-quantifiers over alternation
        // (e.g. `(a|ab)*b`). Backreference traps and patterns whose
        // backtracking is catastrophic only inside a single match
        // attempt are still left to the per-page 5s timeout exercised
        // by the payload-runtime test above.
        let nestedQuantifiers = [
            "(a+)+b",
            "([a-z]+)*z",
            "(.*)+x",
        ]
        for pattern in nestedQuantifiers {
            #expect(
                DocumentSearcher.validateRegexPattern(pattern) == nil,
                "pattern must be rejected by validateRegexPattern: \(pattern)"
            )
        }
    }

    @Test("validateRegexPattern rejects patterns over 200 chars")
    func validateRejectsOversizePatterns() {
        let longPattern = String(repeating: "a", count: 201)
        #expect(DocumentSearcher.validateRegexPattern(longPattern) == nil)
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
