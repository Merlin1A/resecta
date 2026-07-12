import Testing
import Foundation
@testable import RedactionEngine

// W-G fixture-driven test for SSN structural detection. The DataPipeline-
// generated vectors at Fixtures/vectors/ssn_structural_vectors.json carry
// every SSN-shape variant + every SSA structural rejection rule. This file
// exercises SSNStateMachine.scan + SSNStructuralValidator.isValid against
// the fixture so a silent regression in either surface fails CI. Closes the
// 14-of-14 vector parity gap (13 already shipped via D-19 PR #38; SSN was
// the lone family without a fixture-driven Swift consumer).
//
// SSNDetectionTests.swift keeps its inline cases — this suite is additive,
// not a replacement.

@Suite("SSN fixture-driven vector tests (W-G)")
struct SSNVectorTests {

    struct Vectors: Decodable {
        let vectors: [Vector]
    }

    struct Vector: Decodable {
        let ssn: String
        let valid: Bool
        let notes: String
        let rejection_reason: String?
    }

    private func loadVectors() throws -> [Vector]? {
        guard let url = Bundle.module.url(
            forResource: "ssn_structural_vectors",
            withExtension: "json",
            subdirectory: "vectors"
        ) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Vectors.self, from: data).vectors
    }

    @Test("W-G fixture loads with rows")
    func fixtureLoads() throws {
        guard let vectors = try loadVectors() else {
            Issue.record("ssn_structural_vectors.json not bundled")
            return
        }
        #expect(!vectors.isEmpty)
    }

    @Test("State machine extracts exactly 1 candidate from every valid row")
    func stateMachineExtractsValidRows() throws {
        guard let vectors = try loadVectors() else { return }
        let sm = SSNStateMachine()
        for vec in vectors where vec.valid {
            let candidates = sm.scan(vec.ssn)
            #expect(
                candidates.count == 1,
                "expected exactly 1 candidate for \(vec.ssn) (\(vec.notes)), got \(candidates.count)"
            )
        }
    }

    @Test("Validator accepts every valid row's candidate")
    func validatorAcceptsValidRows() throws {
        guard let vectors = try loadVectors() else { return }
        let sm = SSNStateMachine()
        let validator = SSNStructuralValidator()
        for vec in vectors where vec.valid {
            guard let candidate = sm.scan(vec.ssn).first else {
                Issue.record("no candidate for \(vec.ssn) (\(vec.notes))")
                continue
            }
            #expect(
                validator.isValid(candidate),
                "validator rejected valid SSN \(vec.ssn) (\(vec.notes))"
            )
        }
    }

    @Test("Invalid rows rejected at state-machine OR validator level")
    func validatorRejectsInvalidRows() throws {
        guard let vectors = try loadVectors() else { return }
        let sm = SSNStateMachine()
        let validator = SSNStructuralValidator()
        for vec in vectors where !vec.valid {
            let candidates = sm.scan(vec.ssn)
            // A row is "rejected" if either:
            //   (a) state machine yields no candidate (shape failed), or
            //   (b) state machine yields a candidate but validator returns false.
            let stateMachineRejected = candidates.isEmpty
            let validatorRejected = candidates.contains(where: { !validator.isValid($0) })
            let anyAccepted = candidates.contains(where: { validator.isValid($0) })
            #expect(
                (stateMachineRejected || validatorRejected) && !anyAccepted,
                "invalid SSN \(vec.ssn) (rejection_reason=\(vec.rejection_reason ?? "nil")) leaked through to a valid candidate"
            )
        }
    }

    @Test(
        "Typographic dash separators accepted",
        arguments: [
            "123-45-6789",      // U+002D hyphen-minus
            "123\u{2011}45\u{2011}6789", // non-breaking hyphen
            "123\u{2012}45\u{2012}6789", // figure dash
            "123\u{2013}45\u{2013}6789", // en-dash
            "123\u{2014}45\u{2014}6789", // em-dash
            "123 45 6789",      // U+0020 space
        ]
    )
    func typographicDashSeparators(input: String) {
        let sm = SSNStateMachine()
        let candidates = sm.scan(input)
        #expect(
            candidates.count == 1,
            "separator variant \"\(input)\" produced \(candidates.count) candidates"
        )
        #expect(candidates.first?.area == "123")
        #expect(candidates.first?.group == "45")
        #expect(candidates.first?.serial == "6789")
    }

    @Test("Boundary rejection — digit prefix or suffix yields empty")
    func boundaryRejection() {
        let sm = SSNStateMachine()
        // Leading digit boundary
        #expect(sm.scan("0123-45-6789").isEmpty, "digit-prefixed SSN must be rejected")
        // Trailing digit boundary
        #expect(sm.scan("123-45-67890").isEmpty, "digit-suffixed SSN must be rejected")
        // Both boundaries clean — control: still extracts
        #expect(sm.scan(" 123-45-6789 ").count == 1, "boundary-clean SSN must extract")
    }
}
