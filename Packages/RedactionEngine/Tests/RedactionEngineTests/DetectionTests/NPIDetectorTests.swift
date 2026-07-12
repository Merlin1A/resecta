import Testing
import Foundation
@testable import RedactionEngine

// Plan Phase 3 / §4 — NPILuhn80840 + NPIDetector regression. Loads the
// DataPipeline-generated vectors at `Fixtures/vectors/npi_test_vectors.json`
// and asserts every `valid` NPI passes the CMS checksum and every `!valid`
// entry fails. NPIDetector is exercised by embedding each vector in a short
// sentence and confirming it surfaces (for valid entries) or doesn't (for
// invalid entries).

@Suite("NPI detector + Luhn-80840 checksum (G3)")
struct NPIDetectorTests {

    struct Vectors: Decodable {
        let vectors: [Vector]
    }

    struct Vector: Decodable {
        let npi: String
        let valid: Bool
        let reason: String
    }

    private func loadVectors() throws -> [Vector]? {
        guard let url = Bundle.module.url(
            forResource: "npi_test_vectors",
            withExtension: "json",
            subdirectory: "vectors"
        ) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Vectors.self, from: data).vectors
    }

    @Test("Luhn-80840 checksum validates against check-digit vectors")
    func luhnChecksum() throws {
        guard let vectors = try loadVectors() else {
            print("[NPI gate] npi_test_vectors.json not bundled; skipping.")
            return
        }
        #expect(!vectors.isEmpty)
        // NPILuhn80840 only validates the checksum — length + prefix rules live
        // in NPIDetector's regex gate. Restrict this assertion to vectors whose
        // reason mentions a checksum judgment.
        let checksumVectors = vectors.filter { v in
            let reason = v.reason.lowercased()
            return reason.contains("check digit")
        }
        #expect(!checksumVectors.isEmpty)
        for vec in checksumVectors {
            #expect(
                NPILuhn80840.isValid(vec.npi) == vec.valid,
                "Mismatch for \(vec.npi) (\(vec.reason))"
            )
        }
    }

    @Test("Detector surfaces every valid vector and rejects every invalid one")
    func fullDetectorSweep() throws {
        guard let vectors = try loadVectors() else { return }
        let detector = NPIDetector()
        for vec in vectors {
            let text = "NPI: \(vec.npi)"
            let ns = text as NSString
            let matches = detector.detect(in: ns, range: NSRange(location: 0, length: ns.length))
            let surfaced = matches.contains(where: { $0.text == vec.npi })
            #expect(surfaced == vec.valid, "Mismatch for \(vec.npi) (\(vec.reason))")
        }
    }

    @Test("Detector surfaces valid NPI embedded in a sentence")
    func validNPISurfaces() throws {
        guard let vectors = try loadVectors() else { return }
        let detector = NPIDetector()
        let sample = vectors.first(where: { $0.valid })!
        let text = "Provider NPI: \(sample.npi), ready for billing."
        let ns = text as NSString
        let matches = detector.detect(in: ns, range: NSRange(location: 0, length: ns.length))
        #expect(matches.contains(where: { $0.text == sample.npi }))
    }

    @Test("Detector rejects invalid NPI (checksum fail)")
    func invalidNPIDoesNotSurface() throws {
        guard let vectors = try loadVectors() else { return }
        let detector = NPIDetector()
        let invalid = vectors.first(where: { !$0.valid })
        // If fixture has no invalid samples, construct one by flipping a digit.
        let badNPI: String
        if let invalid {
            badNPI = invalid.npi
        } else {
            let valid = vectors.first(where: { $0.valid })!.npi
            let flipped = String(valid.prefix(9)) + (valid.last == "0" ? "1" : "0")
            badNPI = flipped
        }
        let text = "Provider NPI: \(badNPI)"
        let ns = text as NSString
        let matches = detector.detect(in: ns, range: NSRange(location: 0, length: ns.length))
        #expect(!matches.contains(where: { $0.text == badNPI }))
    }

    @Test("Positive context emits .contextPositive signal in rationale")
    func signalEmitsContextPositive() {
        let validNPI = "1455395883"
        let detector = NPIDetector()
        let text = "Provider NPI \(validNPI) billed today"
        let ns = text as NSString
        let matches = detector.detect(in: ns, range: NSRange(location: 0, length: ns.length))
        let hit = matches.first(where: { $0.text == validNPI })
        #expect(hit?.rationale != nil)
        let isContextPositive = hit?.rationale?.signals.contains {
            if case .contextPositive = $0 { return true }
            return false
        } ?? false
        #expect(isContextPositive, "NPI hit with provider keyword must carry .contextPositive")
    }

    @Test("Rationale always includes regexPattern + structuralValidator signals")
    func signalCarriesStructuralFingerprint() {
        let validNPI = "1455395883"
        let detector = NPIDetector()
        let text = "NPI \(validNPI)"
        let ns = text as NSString
        let matches = detector.detect(in: ns, range: NSRange(location: 0, length: ns.length))
        let hit = matches.first(where: { $0.text == validNPI })
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

    @Test("Context boost raises confidence when 'NPI' label is present")
    func contextBoost() {
        // A valid NPI (Luhn-80840 verified above).
        let validNPI = "1455395883"
        let detector = NPIDetector()

        let unlabelled = "Some number 1455395883 appears here"
        let unlabelledNS = unlabelled as NSString
        let unlabelledMatches = detector.detect(
            in: unlabelledNS, range: NSRange(location: 0, length: unlabelledNS.length))

        let labelled = "Provider NPI 1455395883 billed today"
        let labelledNS = labelled as NSString
        let labelledMatches = detector.detect(
            in: labelledNS, range: NSRange(location: 0, length: labelledNS.length))

        guard let unlabelledHit = unlabelledMatches.first(where: { $0.text == validNPI }),
              let labelledHit = labelledMatches.first(where: { $0.text == validNPI }) else {
            Issue.record("expected both NPI matches")
            return
        }
        #expect(labelledHit.confidence >= unlabelledHit.confidence)
    }

    // MARK: - D04-F1 — base-confidence margin (bare valid NPI clears the gate)

    /// Mirrors DOBDetectorTests' helper: surface a single NPI match's confidence.
    private func confidence(of text: String, matching expected: String) -> Double? {
        let detector = NPIDetector()
        let ns = text as NSString
        let matches = detector.detect(in: ns, range: NSRange(location: 0, length: ns.length))
        return matches.first(where: { $0.text == expected })?.confidence
    }

    @Test("Bare Luhn-valid NPI posteriors above the 0.602 balanced/aggressive cutoff with margin")
    func bareValidNPIClearsBalancedCutoffViaPosterior() {
        // 1455395883 is Luhn-80840-valid (see contextBoost). The sentence has no
        // positive keyword in the +/-5 window, so the detector returns the base.
        let raw = confidence(of: "see record 1455395883 for the patient",
                             matching: "1455395883")
        #expect(raw != nil)
        // NPI is an identity family (contextLogit = 0); at the default prior the
        // posterior is sigma(logit(raw)). D04-F1 raises raw to 0.65 so this clears
        // the 0.602 balanced/aggressive cutoff with margin (was 0.600 < 0.602).
        let posterior = CalibratedScorer().posterior(raw: raw ?? 0, priorMean: 0.5)
        #expect(posterior >= 0.602 + 0.02)
    }

    @Test("Bare NPI under the absorbing-state floor (0.35) stays below cutoff - intended")
    func absorbingFlooredNPIStaysSuppressed() {
        let raw = confidence(of: "see record 1455395883 for the patient",
                             matching: "1455395883")
        // After 5 user rejections the prior floors at 0.35; sigma(logit(0.65)+logit(0.35))
        // = sigma(0) = 0.50 < 0.602. Deliberate absorbing-state behavior - pinned so
        // a later change that removes the floor trips this test.
        let posterior = CalibratedScorer().posterior(raw: raw ?? 0, priorMean: 0.35)
        #expect(posterior < 0.602)
    }

    @Test("Bare-NPI raw confidence exceeds the gating npi cutoff (0.602)")
    func npiBaseAbove0602() {
        // Pure detector-level pin (no posterior): a future base retune that
        // re-introduces the 0.600 < 0.602 razor trips here.
        let raw = confidence(of: "see record 1455395883 for the patient",
                             matching: "1455395883")
        #expect((raw ?? 0) >= 0.602)
    }
}
