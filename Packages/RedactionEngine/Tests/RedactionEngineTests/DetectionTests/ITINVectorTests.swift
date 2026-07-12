import Testing
import Foundation
@testable import RedactionEngine

// D-19 fixture-driven test for ITIN detection. The DataPipeline-generated
// vectors at Fixtures/vectors/itin_vectors.json carry a `valid` flag whose
// rejection_reasons cover the IRS YY-bucket gate ([50–65], [70–88], [90–92],
// [94–99]) on top of the regex shape. This test asserts the detector
// honours both gates. The audit at cc-derive D-19 confirmed the fixture is
// schema-clean and determinism-clean. ITINDetectorTests.swift covers
// other surfaces; this file is fixture-driven specifically.

@Suite("ITIN fixture-driven detector vectors (D-19)")
struct ITINVectorTests {

    struct Vectors: Decodable {
        let vectors: [Vector]
    }

    struct Vector: Decodable {
        let itin: String
        let valid: Bool
        let notes: String
    }

    private func loadVectors() throws -> [Vector]? {
        guard let url = Bundle.module.url(
            forResource: "itin_vectors",
            withExtension: "json",
            subdirectory: "vectors"
        ) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Vectors.self, from: data).vectors
    }

    @Test("D-19 fixture loads with rows")
    func fixtureLoads() throws {
        guard let vectors = try loadVectors() else {
            Issue.record("itin_vectors.json not bundled")
            return
        }
        #expect(!vectors.isEmpty)
    }

    @Test("Detector surfaces every valid ITIN and rejects every invalid one")
    func detectorRespectsValidFlag() throws {
        guard let vectors = try loadVectors() else { return }
        let detector = PIIDetector()
        for vec in vectors {
            let ns = vec.itin as NSString
            let matches = detector.detectITINs(
                in: ns, range: NSRange(location: 0, length: ns.length)
            )
            let surfaced = matches.contains(where: { $0.text == vec.itin })
            #expect(surfaced == vec.valid, "Mismatch for \(vec.itin) (\(vec.notes))")
        }
    }
}
