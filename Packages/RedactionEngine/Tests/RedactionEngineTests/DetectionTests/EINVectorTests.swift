import Testing
import Foundation
@testable import RedactionEngine

// D-19 fixture-driven test for EIN detection. The DataPipeline-generated
// vectors at Fixtures/vectors/ein_vectors.json carry a `valid` flag whose
// rejection_reasons are length/shape mismatches — exactly what the inline
// einPattern gate filters. The audit at cc-derive D-19 confirmed the
// fixture is schema-clean and determinism-clean.

@Suite("EIN fixture-driven detector vectors (D-19)")
struct EINVectorTests {

    struct Vectors: Decodable {
        let vectors: [Vector]
    }

    struct Vector: Decodable {
        let ein: String
        let valid: Bool
        let notes: String
    }

    private func loadVectors() throws -> [Vector]? {
        guard let url = Bundle.module.url(
            forResource: "ein_vectors",
            withExtension: "json",
            subdirectory: "vectors"
        ) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Vectors.self, from: data).vectors
    }

    @Test("D-19 fixture loads with rows")
    func fixtureLoads() throws {
        guard let vectors = try loadVectors() else {
            Issue.record("ein_vectors.json not bundled")
            return
        }
        #expect(!vectors.isEmpty)
    }

    @Test("Inline regex shape gate agrees with fixture validity")
    func patternMatchesValidFlag() throws {
        guard let vectors = try loadVectors() else { return }
        for vec in vectors {
            let ns = vec.ein as NSString
            let count = PIIDetector.einPattern.numberOfMatches(
                in: vec.ein, range: NSRange(location: 0, length: ns.length)
            )
            #expect((count >= 1) == vec.valid, "Mismatch for \(vec.ein) (\(vec.notes))")
        }
    }

    @Test("Detector surfaces every valid EIN and rejects every invalid one")
    func detectorRespectsValidFlag() throws {
        guard let vectors = try loadVectors() else { return }
        let detector = PIIDetector()
        for vec in vectors {
            let ns = vec.ein as NSString
            let matches = detector.detectEINs(
                in: ns, range: NSRange(location: 0, length: ns.length)
            )
            let surfaced = matches.contains(where: { $0.text == vec.ein })
            #expect(surfaced == vec.valid, "Mismatch for \(vec.ein) (\(vec.notes))")
        }
    }
}
