import Testing
import Foundation
@testable import RedactionEngine

// D-19 fixture-driven test for email detection. The DataPipeline-generated
// vectors at Fixtures/vectors/email_test_vectors.json carry the bare email
// value (local@domain.tld). This test asserts the inline emailPattern
// matches every valid row. Email has no dedicated detector test file
// today; this fixture-driven file is the first.

@Suite("Email fixture-driven vector tests (D-19)")
struct EmailVectorTests {

    struct Vectors: Decodable {
        let vectors: [Vector]
    }

    struct Vector: Decodable {
        let email: String
        let valid: Bool
        let notes: String
    }

    private func loadVectors() throws -> [Vector]? {
        guard let url = Bundle.module.url(
            forResource: "email_test_vectors",
            withExtension: "json",
            subdirectory: "vectors"
        ) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Vectors.self, from: data).vectors
    }

    @Test("D-19 fixture loads with rows")
    func fixtureLoads() throws {
        guard let vectors = try loadVectors() else {
            Issue.record("email_test_vectors.json not bundled")
            return
        }
        #expect(!vectors.isEmpty)
    }

    @Test("Inline emailPattern matches every valid row")
    func inlineRegexMatchesValidRows() throws {
        guard let vectors = try loadVectors() else { return }
        for vec in vectors where vec.valid {
            let ns = vec.email as NSString
            let count = PIIDetector.emailPattern.numberOfMatches(
                in: vec.email, range: NSRange(location: 0, length: ns.length)
            )
            #expect(count >= 1, "emailPattern did not match: \(vec.email) (\(vec.notes))")
        }
    }
}
