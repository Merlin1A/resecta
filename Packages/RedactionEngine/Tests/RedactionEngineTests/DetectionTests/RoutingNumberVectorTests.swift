import Testing
import Foundation
@testable import RedactionEngine

// Search-impl S2, design 01 §4 + interface table — fixture-driven routing
// number vectors. The DataPipeline-generated fixture at
// Fixtures/vectors/routing_number_vectors.json carries validity flags and
// context expectations; this suite pins the Swift detector to it the same
// way EINVectorTests pins the EIN path (D-19 pattern).

@Suite("Routing number fixture-driven detector vectors")
struct RoutingNumberVectorTests {

    struct Vectors: Decodable {
        let vectors: [Vector]
    }

    struct Vector: Decodable {
        let routing_number: String
        let valid: Bool
        let has_context: Bool
        let context_keyword: String?
        let rejection_reason: String?
        let notes: String
    }

    private func loadVectors() throws -> [Vector]? {
        guard let url = Bundle.module.url(
            forResource: "routing_number_vectors",
            withExtension: "json",
            subdirectory: "vectors"
        ) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Vectors.self, from: data).vectors
    }

    @Test("Fixture loads with rows")
    func fixtureLoads() throws {
        guard let vectors = try loadVectors() else {
            Issue.record("routing_number_vectors.json not bundled")
            return
        }
        #expect(!vectors.isEmpty)
    }

    @Test("Detector agrees with every fixture vector")
    func detectorRespectsValidFlag() throws {
        guard let vectors = try loadVectors() else { return }
        let detector = RoutingNumberDetector()
        for vec in vectors {
            // Compose the probe text exactly as the fixture describes:
            // context keyword before the number when has_context is set.
            let text: String
            if vec.has_context, let keyword = vec.context_keyword {
                text = "\(keyword) \(vec.routing_number)"
            } else {
                text = vec.routing_number
            }
            let ns = text as NSString
            let matches = detector.detect(
                in: ns, range: NSRange(location: 0, length: ns.length)
            )
            if vec.valid {
                #expect(
                    matches.count == 1,
                    "expected 1 match for \(vec.routing_number) (\(vec.notes))"
                )
                let expected = vec.has_context ? 0.88 : 0.50
                #expect(
                    matches.first?.confidence == expected,
                    "confidence mismatch for \(vec.routing_number) (\(vec.notes))"
                )
            } else {
                #expect(
                    matches.isEmpty,
                    "expected rejection (\(vec.rejection_reason ?? "?")) for \(vec.routing_number) (\(vec.notes))"
                )
            }
        }
    }
}
