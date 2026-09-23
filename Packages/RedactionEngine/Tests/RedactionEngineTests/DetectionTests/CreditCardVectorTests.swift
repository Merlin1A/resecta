import Testing
import Foundation
@testable import RedactionEngine

// Fixture-driven test for credit-card detection. The DataPipeline-
// generated vectors at Fixtures/vectors/credit_card_vectors.json carry a
// `valid` flag whose truth follows from luhnCheck + hasValidCardPrefix.
// This test asserts the detector surfaces every valid sample and rejects
// every invalid one. The audit confirmed the fixture is schema-clean and
// determinism-clean.

@Suite("Credit-card fixture-driven detector vectors")
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

    @Test("Fixture loads with rows")
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

    // MARK: - Token-bound edges (C12-87 / F12-12)

    private func cards(in text: String) -> [String] {
        let ns = text as NSString
        return PIIDetector().detectCreditCards(in: ns, range: NSRange(location: 0, length: ns.length)).map(\.text)
    }

    @Test("a Luhn-valid run glued to a letter is not a card: the DL-shaped token U48670409492471")
    func letterAdjacentRunIsNotACard() {
        #expect(cards(in: "Secondary ID on file -- Driver Lic: U48670409492471").isEmpty)
        #expect(cards(in: "Card 4111111111111111x on file").isEmpty)
    }

    @Test("the same digits after a space are a card: 14 digits, Luhn-valid, Visa IIN")
    func spaceSeparatedRunIsACard() {
        #expect(cards(in: "Driver Lic: U 48670409492471") == ["48670409492471"])
    }

    @Test("punctuation edges still admit a card")
    func punctuationEdgesAdmitACard() {
        #expect(cards(in: "#4111 1111 1111 1111.") == ["4111 1111 1111 1111"])
        #expect(cards(in: "Card: 4111-1111-1111-1111, exp 12/29") == ["4111-1111-1111-1111"])
    }
}
