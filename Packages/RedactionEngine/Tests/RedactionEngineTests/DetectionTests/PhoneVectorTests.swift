import Testing
import Foundation
@testable import RedactionEngine

// D-19 fixture-driven test for phone detection. The DataPipeline-generated
// vectors at Fixtures/vectors/phone_test_vectors.json carry the bare phone
// value (no labeled-prefix context) — valid rows cover paren-balanced and
// dotted/spaced separators. This test asserts the inline phonePattern
// matches every valid row. Phone has no dedicated detector test file
// today; this fixture-driven file is the first.

@Suite("Phone fixture-driven vector tests (D-19)")
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

    @Test("D-19 fixture loads with rows")
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
}
