import Testing
import Foundation
@testable import RedactionEngine

// D-19 fixture-driven test for MRN detection. The DataPipeline-generated
// vectors at Fixtures/vectors/mrn_test_vectors.json carry three labeled
// shapes (MRN-prefix, Patient-ID-prefix, institution-prefix). This test
// asserts that every valid row's text matches at least one of the three
// inline MRN patterns. MRNDetectorTests.swift covers other surfaces;
// this file is fixture-driven specifically.

@Suite("MRN fixture-driven vector tests (D-19)")
struct MRNVectorTests {

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
            forResource: "mrn_test_vectors",
            withExtension: "json",
            subdirectory: "vectors"
        ) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Vectors.self, from: data).vectors
    }

    @Test("D-19 fixture loads with rows")
    func fixtureLoads() throws {
        guard let vectors = try loadVectors() else {
            Issue.record("mrn_test_vectors.json not bundled")
            return
        }
        #expect(!vectors.isEmpty)
    }

    @Test("At least one inline MRN pattern matches every valid row's text")
    func inlineRegexMatchesValidRows() throws {
        guard let vectors = try loadVectors() else { return }
        let patterns = [
            PIIDetector.mrnPatternLabeled,
            PIIDetector.mrnPatternPatientID,
            PIIDetector.mrnPatternInstitution,
        ]
        for vec in vectors where vec.valid {
            let ns = vec.text as NSString
            let range = NSRange(location: 0, length: ns.length)
            let matched = patterns.contains { $0.numberOfMatches(in: vec.text, range: range) >= 1 }
            #expect(matched, "no MRN pattern matched: \(vec.text) (\(vec.notes))")
        }
    }
}
