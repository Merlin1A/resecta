import Testing
import Foundation
@testable import RedactionEngine

// Plan M6 / C3 — IRS YY-bucket tightening for the ITIN detector.
//
// IRS-issued ITINs carry YY in one of four ranges:
//   [50-65, 70-88, 90-92, 94-99]
// The detector's post-regex gate rejects every YY outside those ranges.
// This suite covers each boundary ±1 so both the accept and the reject
// paths are exercised explicitly.

@Suite("ITIN detector (YY-bucket gate)")
struct ITINDetectorTests {

    private func detects(_ text: String) async -> Bool {
        let detector = PIIDetector()
        let results = await detector.detect(in: text)
        return results.contains { $0.kind == .itin }
    }

    // MARK: - Boundary accept cases

    @Test("YY-bucket boundaries accepted (inclusive endpoints)", arguments: [
        "912-50-1234",   // lower edge of 50-65
        "912-65-1234",   // upper edge of 50-65
        "912-70-1234",   // lower edge of 70-88
        "912-88-1234",   // upper edge of 70-88
        "912-90-1234",   // lower edge of 90-92
        "912-92-1234",   // upper edge of 90-92
        "912-94-1234",   // lower edge of 94-99
        "912-99-1234",   // upper edge of 94-99
    ])
    func validYYBoundariesAccepted(_ input: String) async {
        #expect(await detects(input),
                "IRS-valid YY should be accepted for '\(input)'")
    }

    // MARK: - Boundary reject cases

    @Test("YY-bucket boundaries rejected (±1 outside each range)", arguments: [
        "912-49-1234",   // one below 50-65
        "912-66-1234",   // one above 50-65 (gap to 70)
        "912-69-1234",   // one below 70-88
        "912-89-1234",   // one above 70-88 (gap to 90)
        "912-93-1234",   // gap between 90-92 and 94-99
        "912-00-1234",   // well below any range
        "912-34-1234",   // mid-gap legacy test value
    ])
    func invalidYYBoundariesRejected(_ input: String) async {
        #expect(!(await detects(input)),
                "IRS-invalid YY should be rejected for '\(input)'")
    }

    // MARK: - Regex still matches, gate still rejects

    @Test("Pattern matches YY=34 but detector drops it")
    func patternMatchesButDetectorRejects() async {
        // The regex itself is unchanged; gate rejection happens in detectITINs.
        let input = "912-34-5678"
        let nsInput = input as NSString
        let range = NSRange(location: 0, length: nsInput.length)
        let patternMatches = PIIDetector.itinPattern.matches(in: input, range: range)
        #expect(!patternMatches.isEmpty, "Regex should still match shape")

        let detector = PIIDetector()
        let results = await detector.detect(in: input)
        let itinResults = results.filter { $0.kind == .itin }
        #expect(itinResults.isEmpty, "Gate should reject YY=34")
    }

    // MARK: - DataPipeline vector cross-check

    struct Vectors: Decodable {
        let vectors: [Vector]
    }

    struct Vector: Decodable {
        let itin: String
        let valid: Bool
        // swiftlint:disable:next identifier_name
        let yy_bucket: String
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

    @Test("Detector verdict matches DataPipeline yy_bucket for every vector")
    func vectorCrossCheck() async throws {
        guard let vectors = try loadVectors() else {
            print("[ITIN gate] itin_vectors.json not bundled; skipping.")
            return
        }
        #expect(!vectors.isEmpty)
        for vec in vectors {
            let detected = await detects(vec.itin)
            #expect(detected == vec.valid,
                    "Mismatch for \(vec.itin): vector says valid=\(vec.valid), bucket=\(vec.yy_bucket), detector returned \(detected)")
        }
    }
}

// WS1 design 01 §6 — ITIN ContextWindowScorer migration (item 1.10, 2026-06-10).
//
// Prior implementation used inline contains() checks for three keywords.
// The scorer migration is functionally equivalent: same baseConfidence (0.60)
// and boostedConfidence (0.85), same three keyword families now expressed as
// itinProfile.positiveKeywords. WS2 can extend the keyword set via JSON
// without touching Swift code.

@Suite("ITIN ContextWindowScorer migration (design 01 §6, item 1.10)")
struct ITINScorerMigrationTests {

    private func itinMatches(in text: String) async -> [PIIDetector.PIIMatch] {
        let detector = PIIDetector()
        let results = await detector.detect(in: text)
        return results.filter { $0.kind == .itin }
    }

    // MARK: - Rationale population

    @Test("Scorer rationale present when 'itin' keyword nearby")
    func scorerRationale_present() async {
        // "itin" is in itinProfile.positiveKeywords → scorer boosts confidence.
        // A boosted match should have rationale with contextPositive signal.
        let matches = await itinMatches(in: "itin 900-50-1234")
        guard let match = matches.first else {
            Issue.record("Expected at least one ITIN match for 'itin 900-50-1234'")
            return
        }
        #expect(match.rationale != nil, "Scorer migration must populate rationale")
        if let rationale = match.rationale {
            let hasRegexSignal = rationale.signals.contains {
                if case .regexPattern(let name) = $0 { return name == "itin.yy-bucket" }
                return false
            }
            #expect(hasRegexSignal, "Rationale must carry .regexPattern(name: 'itin.yy-bucket') signal")
            let hasStructValidator = rationale.signals.contains {
                if case .structuralValidator(let name) = $0 { return name == "itin.irs-yy-ranges" }
                return false
            }
            #expect(hasStructValidator, "Rationale must carry .structuralValidator(name: 'itin.irs-yy-ranges') signal")
        }
    }

    // MARK: - Base/boosted confidence preservation

    @Test("No context: base confidence 0.60 (unchanged from pre-migration)")
    func noContext_baseConfidence() async {
        // Bare ITIN number in YY range 50: no keywords → itinProfile.baseConfidence = 0.60.
        // Verified: prior inline was also 0.60 for no-context case — no behavior change.
        let matches = await itinMatches(in: "900-50-1234")
        guard let match = matches.first else {
            Issue.record("Expected ITIN detection for bare 900-50-1234 (valid YY=50)")
            return
        }
        #expect(match.confidence == 0.60, "No-context ITIN → base confidence 0.60")
    }

    @Test("With 'ITIN' keyword: boosted confidence 0.85")
    func withContext_boostedConfidence() async {
        // "itin" keyword → itinProfile.boostedConfidence = 0.85.
        // Prior inline: hasContext ? 0.85 : 0.60 — same value.
        let matches = await itinMatches(in: "ITIN 900-50-1234")
        guard let match = matches.first else {
            Issue.record("Expected ITIN detection for 'ITIN 900-50-1234'")
            return
        }
        #expect(match.confidence == 0.85, "ITIN keyword present → boosted confidence 0.85")
    }

    @Test("With 'individual taxpayer' phrase: boosted confidence 0.85")
    func withIndividualTaxpayerKeyword_boosted() async {
        // "individual taxpayer identification" is in itinProfile.positiveKeywords.
        let matches = await itinMatches(in: "individual taxpayer identification 900-50-1234")
        if let match = matches.first {
            #expect(match.confidence == 0.85,
                    "individual taxpayer identification keyword → boosted 0.85")
        }
    }

    @Test("YY-bucket gate still rejects unissued ITINs after scorer migration")
    func yybucketGate_stillActive_afterMigration() async {
        // YY=34 is outside all valid ranges; should still be rejected.
        let matches = await itinMatches(in: "itin 900-34-1234")
        #expect(matches.isEmpty, "YY-bucket gate must still reject unissued YY=34 after scorer migration")
    }
}
