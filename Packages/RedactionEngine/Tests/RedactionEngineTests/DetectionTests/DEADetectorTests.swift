import Testing
import Foundation
@testable import RedactionEngine

// Plan Phase 3 / §4 — DEA registration checksum regression against
// `Fixtures/vectors/dea_test_vectors.json`.

@Suite("DEA detector + position-weighted checksum (G3)")
struct DEADetectorTests {

    struct Vectors: Decodable {
        let vectors: [Vector]
    }

    struct Vector: Decodable {
        let dea: String
        let valid: Bool
        let reason: String
    }

    private func loadVectors() throws -> [Vector]? {
        guard let url = Bundle.module.url(
            forResource: "dea_test_vectors",
            withExtension: "json",
            subdirectory: "vectors"
        ) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Vectors.self, from: data).vectors
    }

    /// Returns the first valid vector whose first letter is a documented DEA
    /// registrant-type code. The vector file contains checksums-valid entries with
    /// non-registrant letters (e.g. I, W, V, Z) — those are rejected by the
    /// WS1 item 1.11 gate in detect(); tests that invoke detect() must use a
    /// vector with a registrant-type first letter.
    private func firstRegistrantValidVector(from vectors: [Vector]) -> Vector? {
        let registrantLetters = Set("ABCDEFGHJKLMPRSTU").union(["X"])
        return vectors.first(where: { $0.valid && registrantLetters.contains($0.dea.first ?? "?") })
    }

    @Test("Checksum matches every vector")
    func checksum() throws {
        guard let vectors = try loadVectors() else {
            print("[DEA gate] dea_test_vectors.json not bundled; skipping.")
            return
        }
        #expect(!vectors.isEmpty)
        for vec in vectors {
            #expect(
                DEADetector.isValidChecksum(vec.dea) == vec.valid,
                "Mismatch for \(vec.dea) (\(vec.reason))"
            )
        }
    }

    @Test("Detector surfaces valid DEA with context")
    func validDEASurfaces() throws {
        guard let vectors = try loadVectors() else { return }
        let detector = DEADetector()
        // WS1 item 1.11: must use a vector with a valid registrant-type first letter;
        // the vector file includes checksum-valid entries with non-registrant letters
        // (e.g. I, W, V, Z) that detect() correctly rejects.
        guard let sample = firstRegistrantValidVector(from: vectors) else { return }
        let text = "Dr. Smith DEA \(sample.dea) writing prescription."
        let ns = text as NSString
        let matches = detector.detect(in: ns, range: NSRange(location: 0, length: ns.length))
        #expect(matches.contains(where: { $0.text == sample.dea }))
    }

    @Test("Invalid DEA does not surface")
    func invalidDoesNotSurface() throws {
        guard let vectors = try loadVectors() else { return }
        let detector = DEADetector()
        guard let invalid = vectors.first(where: { !$0.valid }) else { return }
        let text = "DEA \(invalid.dea) on file"
        let ns = text as NSString
        let matches = detector.detect(in: ns, range: NSRange(location: 0, length: ns.length))
        #expect(!matches.contains(where: { $0.text == invalid.dea }))
    }

    @Test("Positive context emits .contextPositive signal in rationale")
    func signalEmitsContextPositive() throws {
        guard let vectors = try loadVectors() else { return }
        let detector = DEADetector()
        guard let sample = firstRegistrantValidVector(from: vectors) else { return }
        let text = "Dr. Smith DEA \(sample.dea) writing prescription."
        let ns = text as NSString
        let matches = detector.detect(in: ns, range: NSRange(location: 0, length: ns.length))
        let hit = matches.first(where: { $0.text == sample.dea })
        #expect(hit?.rationale != nil)
        let isContextPositive = hit?.rationale?.signals.contains {
            if case .contextPositive = $0 { return true }
            return false
        } ?? false
        #expect(isContextPositive, "DEA hit with prescription keyword must carry .contextPositive")
    }

    @Test("Rationale always includes regexPattern + structuralValidator signals")
    func signalCarriesStructuralFingerprint() throws {
        guard let vectors = try loadVectors() else { return }
        let detector = DEADetector()
        guard let sample = firstRegistrantValidVector(from: vectors) else { return }
        let text = "DEA \(sample.dea)"
        let ns = text as NSString
        let matches = detector.detect(in: ns, range: NSRange(location: 0, length: ns.length))
        let hit = matches.first(where: { $0.text == sample.dea })
        #expect(hit?.rationale != nil)
        let hasRegex = hit?.rationale?.signals.contains {
            if case .regexPattern = $0 { return true }
            return false
        } ?? false
        let hasValidator = hit?.rationale?.signals.contains {
            if case .structuralValidator = $0 { return true }
            return false
        } ?? false
        #expect(hasRegex)
        #expect(hasValidator)
    }

    // MARK: - WS1 item 1.11: registrant-type first-letter validation

    // CB1234563 checksum: (1+3+5) + 2*(2+4+6) = 9+24 = 33; last digit 3 == d7. Valid.
    // Suffix pattern B1234563 is checksum-valid for any two-letter prefix; used
    // throughout this suite to isolate the first-letter gate from the checksum.

    @Test("Valid registrant-type letter C passes (practitioner, most common)")
    func validRegistrantC_passes() {
        // CB1234563: first letter C (practitioner), checksum valid.
        let detector = DEADetector()
        let text = "DEA CB1234563"
        let ns = text as NSString
        let matches = detector.detect(in: ns, range: NSRange(location: 0, length: ns.length))
        #expect(matches.count == 1)
        #expect(matches.first?.text == "CB1234563")
    }

    @Test("Non-registrant letter N rejected (checksum-valid but N has no DEA assignment)")
    func invalidRegistrantN_rejected() {
        // NB1234563: checksum valid (same digit suffix), first letter N is not a valid
        // DEA registrant type. Detector must return 0 matches.
        let detector = DEADetector()
        let text = "DEA NB1234563"
        let ns = text as NSString
        let matches = detector.detect(in: ns, range: NSRange(location: 0, length: ns.length))
        #expect(matches.count == 0,
            "N is not a valid DEA registrant type; checksum-valid NB1234563 must be rejected")
    }

    @Test("Adversarial: ZA1234563 is checksum-valid but Z is not a registrant type → count 0")
    func adversarial_ZA_checksum_valid_but_Z_not_registrant() {
        // ZA1234563: checksum valid (9+24=33, last digit 3 == d7), but Z has no documented
        // DEA registrant-type assignment. Must be rejected by isValidRegistrantLetter gate.
        // Confirm checksum is valid (arithmetic correct), then confirm detector rejects it.
        #expect(DEADetector.isValidChecksum("ZA1234563") == true,
            "Checksum should be arithmetically valid (test setup verification)")
        #expect(DEADetector.isValidRegistrantLetter("ZA1234563") == false,
            "Z is not a valid registrant type letter")
        let detector = DEADetector()
        let text = "DEA ZA1234563"
        let ns = text as NSString
        let matches = detector.detect(in: ns, range: NSRange(location: 0, length: ns.length))
        #expect(matches.count == 0,
            "ZA1234563 is checksum-valid but Z is not a valid registrant letter")
    }

    @Test("All 18 valid registrant-type letters produce exactly 1 match each")
    func allValidLetters_accepted() {
        // For each letter in validRegistrantLetters, construct a checksum-valid DEA using
        // the suffix B1234563 (checksum: 9+24=33, last digit 3 == d7, valid for all prefixes).
        // Source: DEA Practitioner's Manual §I.A; 21 CFR §1301.11 (verified 2026-06-11).
        let validLetters: [Character] = [
            "A", "B", "C", "D", "E", "F", "G", "H",
            "J", "K", "L", "M", "P", "R", "S", "T", "U", "X"
        ]
        let detector = DEADetector()
        for letter in validLetters {
            let dea = "\(letter)B1234563"
            let text = "DEA \(dea)"
            let ns = text as NSString
            let matches = detector.detect(in: ns, range: NSRange(location: 0, length: ns.length))
            #expect(matches.count == 1,
                "Letter \(letter): expected 1 match for checksum-valid \(dea), got \(matches.count)")
        }
    }
}
