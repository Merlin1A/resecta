import Testing
import Foundation
@testable import RedactionEngine

// D-19 fixture-driven test for license-plate detection. The DataPipeline-
// generated vectors at Fixtures/vectors/license_plate_test_vectors.json
// carry labeled-prefix plate values whose `text` field reproduces the
// original document context (e.g. "Tag Number# U79YMJ"). This test
// asserts the inline licensePlateLabeled regex matches every valid row's
// text. LicensePlateDetectorTests.swift covers other surfaces; this file
// is fixture-driven specifically.

@Suite("License-plate fixture-driven vector tests (D-19)")
struct LicensePlateVectorTests {

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
            forResource: "license_plate_test_vectors",
            withExtension: "json",
            subdirectory: "vectors"
        ) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Vectors.self, from: data).vectors
    }

    @Test("D-19 fixture loads with rows")
    func fixtureLoads() throws {
        guard let vectors = try loadVectors() else {
            Issue.record("license_plate_test_vectors.json not bundled")
            return
        }
        #expect(!vectors.isEmpty)
    }

    @Test("Inline licensePlateLabeled regex matches every valid row's text")
    func inlineRegexMatchesValidRows() throws {
        guard let vectors = try loadVectors() else { return }
        for vec in vectors where vec.valid {
            let ns = vec.text as NSString
            let count = PIIDetector.licensePlateLabeled.numberOfMatches(
                in: vec.text, range: NSRange(location: 0, length: ns.length)
            )
            #expect(count >= 1, "licensePlateLabeled did not match: \(vec.text) (\(vec.notes))")
        }
    }
}
