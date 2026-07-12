import Testing
import Foundation
@testable import RedactionEngine

// D-19 fixture-driven test for passport detection. The DataPipeline-
// generated vectors at Fixtures/vectors/passport_test_vectors.json carry
// labeled-prefix passport numbers whose `text` field reproduces the
// original document context (e.g. "Passport No TK8863248"). This test
// asserts the inline passportPattern matches every valid row's text.
// PassportDetectorTests.swift covers other surfaces; this file is
// fixture-driven specifically.

@Suite("Passport fixture-driven vector tests (D-19)")
struct PassportVectorTests {

    struct Vectors: Decodable {
        let vectors: [Vector]
    }

    struct Vector: Decodable {
        let text: String
        let valid: Bool
        let notes: String
    }

    private func loadVectors() throws -> [Vector]? {
        guard let url = Bundle.module.url(
            forResource: "passport_test_vectors",
            withExtension: "json",
            subdirectory: "vectors"
        ) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Vectors.self, from: data).vectors
    }

    @Test("D-19 fixture loads with rows")
    func fixtureLoads() throws {
        guard let vectors = try loadVectors() else {
            Issue.record("passport_test_vectors.json not bundled")
            return
        }
        #expect(!vectors.isEmpty)
    }

    @Test("Inline passportPattern matches every valid row's text")
    func inlineRegexMatchesValidRows() throws {
        guard let vectors = try loadVectors() else { return }
        for vec in vectors where vec.valid {
            let ns = vec.text as NSString
            let count = PIIDetector.passportPattern.numberOfMatches(
                in: vec.text, range: NSRange(location: 0, length: ns.length)
            )
            #expect(count >= 1, "passportPattern did not match: \(vec.text) (\(vec.notes))")
        }
    }
}
