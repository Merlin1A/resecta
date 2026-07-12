import Testing
import Foundation
@testable import RedactionEngine

// D-19 fixture-driven test for credit-card detection. The DataPipeline-
// generated vectors at Fixtures/vectors/credit_card_vectors.json carry a
// `valid` flag whose truth follows from luhnCheck + hasValidCardPrefix.
// This test asserts the detector surfaces every valid sample and rejects
// every invalid one. The audit at cc-derive D-19 confirmed the fixture is
// schema-clean and determinism-clean.

@Suite("Credit-card fixture-driven detector vectors (D-19)")
struct CreditCardVectorTests {

    struct Vectors: Decodable {
        let vectors: [Vector]
    }

    struct Vector: Decodable {
        let pan: String
        let valid: Bool
        let notes: String
    }

    private func loadVectors() throws -> [Vector]? {
        guard let url = Bundle.module.url(
            forResource: "credit_card_vectors",
            withExtension: "json",
            subdirectory: "vectors"
        ) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Vectors.self, from: data).vectors
    }

    @Test("D-19 fixture loads with rows")
    func fixtureLoads() throws {
        guard let vectors = try loadVectors() else {
            Issue.record("credit_card_vectors.json not bundled")
            return
        }
        #expect(!vectors.isEmpty)
    }

    @Test("Luhn + prefix gates agree with fixture validity")
    func checksumMatchesValidFlag() throws {
        guard let vectors = try loadVectors() else { return }
        for vec in vectors {
            let digits = vec.pan.filter(\.isWholeNumber)
            let passes = PIIDetector.luhnCheck(digits) && PIIDetector.hasValidCardPrefix(digits)
            #expect(passes == vec.valid, "Mismatch for \(vec.pan) (\(vec.notes))")
        }
    }

    @Test("Detector surfaces every valid PAN and rejects every invalid one")
    func detectorRespectsValidFlag() throws {
        guard let vectors = try loadVectors() else { return }
        let detector = PIIDetector()
        for vec in vectors {
            let ns = vec.pan as NSString
            let matches = detector.detectCreditCards(
                in: ns, range: NSRange(location: 0, length: ns.length)
            )
            let surfaced = matches.contains(where: { $0.text == vec.pan })
            #expect(surfaced == vec.valid, "Mismatch for \(vec.pan) (\(vec.notes))")
        }
    }
}
