import Testing
import Foundation
@testable import RedactionEngine

// Fixture-driven test for phone detection. The DataPipeline-generated
// vectors at Fixtures/vectors/phone_test_vectors.json carry the bare phone
// value (no labeled-prefix context) — valid rows cover paren-balanced and
// dotted/spaced separators. This test asserts the inline phonePattern
// matches every valid row. Phone has no dedicated detector test file
// today; this fixture-driven file is the first.

@Suite("Phone fixture-driven vector tests")
struct PhoneVectorTests {

    struct Vectors: Decodable {
        let vectors: [Vector]
    }

    struct Vector: Decodable {
        let phone: String
        let valid: Bool
        let notes: String
    }

    private func loadVectors() throws -> [Vector]? {
        guard let url = Bundle.module.url(
            forResource: "phone_test_vectors",
            withExtension: "json",
            subdirectory: "vectors"
        ) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Vectors.self, from: data).vectors
    }

    @Test("Fixture loads with rows")
    func fixtureLoads() throws {
        guard let vectors = try loadVectors() else {
            Issue.record("phone_test_vectors.json not bundled")
            return
        }
        #expect(!vectors.isEmpty)
    }

    @Test("Inline phonePattern matches every valid row")
    func inlineRegexMatchesValidRows() throws {
        guard let vectors = try loadVectors() else { return }
        for vec in vectors where vec.valid {
            let ns = vec.phone as NSString
            let count = PIIDetector.phonePattern.numberOfMatches(
                in: vec.phone, range: NSRange(location: 0, length: ns.length)
            )
            #expect(count >= 1, "phonePattern did not match: \(vec.phone) (\(vec.notes))")
        }
    }

    // MARK: - Token-bound context keywords (C12-134)

    private func phoneConfidence(_ text: String) -> Double? {
        let ns = text as NSString
        return PIIDetector().detectPhones(in: ns, range: NSRange(location: 0, length: ns.length)).first?.confidence
    }

    @Test("a context keyword inside another word does not boost: Patel ∌ tel, next ∌ ext")
    func keywordInsideAnotherWordDoesNotBoost() {
        #expect(phoneConfidence("Priya Patel (312) 621-4862") == 0.60)
        #expect(phoneConfidence("Next: 312-621-4862") == 0.60)
    }

    @Test("whole-token keywords still boost; telephone and calling are cues of their own")
    func wholeTokenKeywordsStillBoost() {
        #expect(phoneConfidence("Tel: (312) 621-4862") == 0.80)
        #expect(phoneConfidence("Ext. 312-621-4862") == 0.80)
        #expect(phoneConfidence("Telephone: (312) 621-4862") == 0.80)
        #expect(phoneConfidence("Reach us by calling (312) 621-4862") == 0.80)
    }

    // MARK: - Phrase cues and labelled non-phones (C12-33)

    @Test("a labelled account, reference, member or record number is not a phone when no phone cue is in the window")
    func labelledNonPhoneNumbersAreNotEmitted() {
        #expect(phoneConfidence("Account Number: 2252921109") == nil)
        #expect(phoneConfidence("Your reference number 2928559816 is on file") == nil)
        #expect(phoneConfidence("Member Number: 5551234567") == nil)
        #expect(phoneConfidence("MRN 5551234567") == nil)
    }

    @Test("the bare word number is not a phone cue; a labelled number 43 chars away no longer boosts a neighbour")
    func bareNumberIsNotACue() {
        #expect(phoneConfidence("Callback line: (520) 520-2006.\n\nIdentity verified at intake -- Passport Number: O57885498") == 0.60)
    }

    @Test("the phone cues still boost: a label, a phrase, a call-us line")
    func phoneCuesStillBoost() {
        #expect(phoneConfidence("Phone: (555) 010-0100") == 0.80)
        #expect(phoneConfidence("Contact number 555-010-0100") == 0.80)
        #expect(phoneConfidence("Fax number: 555-010-0100") == 0.80)
        #expect(phoneConfidence("Call us at 555-010-0100") == 0.80)
        #expect(phoneConfidence("Tel no. 555-010-0100") == 0.80)
    }

    @Test("a phone cue beside a labelled number keeps the phone: the positive overrides the negative")
    func positiveOverridesNegative() {
        #expect(phoneConfidence("Account Number: 2252921109 -- phone (555) 010-0100") == 0.80)
    }

    @Test("a bare ten-digit run with no cue keeps the 0.60 base")
    func bareRunKeepsTheBase() {
        #expect(phoneConfidence("5551234567") == 0.60)
        #expect(phoneConfidence("(555) 010-0100") == 0.60)
    }
}
