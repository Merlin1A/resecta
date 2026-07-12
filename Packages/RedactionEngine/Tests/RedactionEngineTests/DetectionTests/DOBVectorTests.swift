import Testing
import Foundation
@testable import RedactionEngine

// D-19 fixture-driven test for DOB detection. The DataPipeline-generated
// vectors at Fixtures/vectors/dob_vectors.json carry labeled-prefix
// dates whose `text` field reproduces the original document context
// (e.g. "Birthdate: 6/12/1955"). This test asserts the inline dobPattern
// matches every valid row's text. DOBDetectorTests.swift covers other
// surfaces; this file is fixture-driven specifically.

@Suite("DOB fixture-driven vector tests (D-19)")
struct DOBVectorTests {

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
            forResource: "dob_vectors",
            withExtension: "json",
            subdirectory: "vectors"
        ) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Vectors.self, from: data).vectors
    }

    @Test("D-19 fixture loads with rows")
    func fixtureLoads() throws {
        guard let vectors = try loadVectors() else {
            Issue.record("dob_vectors.json not bundled")
            return
        }
        #expect(!vectors.isEmpty)
    }

    @Test("Inline dobPattern matches every valid row's text")
    func inlineRegexMatchesValidRows() throws {
        guard let vectors = try loadVectors() else { return }
        for vec in vectors where vec.valid {
            let ns = vec.text as NSString
            let count = PIIDetector.dobPattern.numberOfMatches(
                in: vec.text, range: NSRange(location: 0, length: ns.length)
            )
            #expect(count >= 1, "dobPattern did not match: \(vec.text) (\(vec.notes))")
        }
    }
}
