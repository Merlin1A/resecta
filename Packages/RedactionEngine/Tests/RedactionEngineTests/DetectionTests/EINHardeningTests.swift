import Testing
import Foundation
@testable import RedactionEngine

// WS1 design 01 §5 — EIN hardening (item 1.9, 2026-06-10).
//
// Three new arms: hyphenated (unchanged), space-separated (context required),
// no-separator (context required). Invalid-prefix rejection via
// invalidEINPrefixes set verified against IRS IRM 21.7.13 (accessed 2026-06-11).
//
// NOTE: routingNumber overlap test (§5 "test_noSep_withStrongContext") omits
// the routing-overlap half because PIICategory.routingNumber does not exist
// in this task's scope (lands in a separate S2 agent task). The test asserts
// only the .ein match with boosted confidence.

@Suite("EIN hardening (design 01 §5, item 1.9)")
struct EINHardeningTests {

    private func einMatches(in text: String) -> [PIIDetector.PIIMatch] {
        let detector = PIIDetector()
        let ns = text as NSString
        return detector.detectEINs(in: ns, range: NSRange(location: 0, length: ns.length))
    }

    // MARK: - Space-separated format

    @Test("Space-separated EIN with strong context: boosted confidence")
    func spaceFormat_withContext() {
        // "employer id" is a positiveKeyword in einProfile → boosted to 0.85.
        let matches = einMatches(in: "employer id 12 3456789")
        #expect(matches.count >= 1, "Space-separated EIN with EIN keyword should be detected")
        if let match = matches.first(where: { $0.text == "12 3456789" }) {
            #expect(match.confidence == 0.85,
                    "EIN context keyword present → boostedConfidence 0.85")
        }
    }

    @Test("Space-separated EIN without context: suppressed (base <= 0.50, requiresContext)")
    func spaceFormat_noContext_suppressed() {
        // No keyword → base 0.50 → requiresContext gate drops it.
        let matches = einMatches(in: "12 3456789")
        let spaceMatches = matches.filter { $0.text == "12 3456789" }
        #expect(spaceMatches.isEmpty, "Space-separated EIN without context must be suppressed")
    }

    // MARK: - No-separator format

    @Test("No-separator EIN with strong EIN keyword: detected as .ein at boosted confidence")
    func noSep_withStrongContext() {
        // "payer's tin" is in einProfile.positiveKeywords → boosts to 0.85.
        // Prefix 12 is ABA-valid (01-12 range) so both EIN and routing detectors could
        // theoretically fire. Only EIN is in scope here (routingNumber category not yet
        // shipped); we assert .ein match exists with boosted confidence.
        // NOTE: routingNumber overlap half omitted — PIICategory.routingNumber
        // does not exist until item 1.8 (different agent).
        let matches = einMatches(in: "payer's tin 123456789")
        let einMatch = matches.first(where: { $0.kind == .ein })
        #expect(einMatch != nil, "No-sep EIN with EIN keyword should be detected as .ein")
        if let m = einMatch {
            #expect(m.confidence == 0.85,
                    "EIN keyword present → boostedConfidence 0.85 (§5 no-sep with strong context)")
        }
    }

    @Test("No-separator EIN without context: suppressed (requiresContext gate)")
    func noSep_noContext_suppressed() {
        // Bare 9 digits, no keyword → base 0.50 ≤ einProfile.baseConfidence → dropped.
        let matches = einMatches(in: "123456789")
        let noSepMatches = matches.filter { $0.text == "123456789" }
        #expect(noSepMatches.isEmpty, "No-sep EIN without context must be suppressed")
    }

    // MARK: - Invalid-prefix rejection

    @Test("Invalid prefix 00 rejected")
    func invalidPrefix00_rejected() {
        let matches = einMatches(in: "EIN: 00-1234567")
        #expect(matches.count == 0, "Prefix 00 is never-issued per IRS IRM 21.7.13")
    }

    @Test("Invalid prefix 07 rejected")
    func invalidPrefix07_rejected() {
        // Note: "00-7123456" has prefix "00" (the first 2 digits of the digit strip)
        let matches = einMatches(in: "EIN: 07-1234567")
        #expect(matches.count == 0, "Prefix 07 is never-issued per IRS IRM 21.7.13")
    }

    @Test("Invalid prefix 08 adversarial rejected")
    func adversarial_prefix08_rejected() {
        let matches = einMatches(in: "EIN: 08-1234567")
        #expect(matches.count == 0, "Prefix 08 never-issued (IRS IRM 21.7.13)")
    }

    @Test("Invalid prefix 00 all-zeros adversarial rejected")
    func adversarial_prefix00allZeros_rejected() {
        let matches = einMatches(in: "EIN: 00-0000000")
        #expect(matches.count == 0, "Prefix 00 with all-zero serial: never-issued")
    }

    @Test("Valid prefix 12 hyphenated accepted")
    func validPrefix12_hyphenated_accepted() {
        // Prefix 12 is assigned to Andover (IRS IRM 21.7.13).
        // With "ein" keyword → boosted confidence.
        let matches = einMatches(in: "ein 12-3456789")
        #expect(matches.count >= 1, "Valid prefix 12 should be accepted")
    }

    @Test("Valid prefix 94 (Memphis) accepted")
    func validPrefix94_accepted() {
        let matches = einMatches(in: "ein 94-3456789")
        #expect(matches.count >= 1, "Valid prefix 94 (Memphis) should be accepted")
    }

    // MARK: - Never-issued set completeness (adversarial sweep)

    @Test("All never-issued prefixes rejected in hyphenated form",
          arguments: ["00", "07", "08", "09", "17", "18", "19",
                      "28", "29", "49", "69", "70", "78", "79", "89", "96", "97"])
    func neverIssuedPrefix_hyphenated_rejected(_ prefix: String) {
        let text = "EIN: \(prefix)-1234567"
        let matches = einMatches(in: text)
        #expect(matches.count == 0,
                "Prefix \(prefix) is never-issued per IRS IRM 21.7.13 (accessed 2026-06-11)")
    }

    // MARK: - Existing hyphenated behavior preserved

    @Test("Hyphenated EIN with 'employer identification' phrase: boosted confidence")
    func hyphenated_withEmployerIdentificationKeyword_boosted() {
        // "employer identification" is in einProfile.positiveKeywords (§5a).
        // Note: bare "employer" alone is NOT a keyword — use the full phrase.
        let matches = einMatches(in: "employer identification 12-3456789")
        #expect(matches.count >= 1)
        if let m = matches.first {
            #expect(m.confidence == 0.85, "employer identification phrase → boosted 0.85")
        }
    }

    @Test("Hyphenated EIN without context: base confidence 0.50")
    func hyphenated_noContext_baseConfidence() {
        // Valid prefix 12, no keyword → base 0.50 (no requiresContext gate for hyphen arm).
        let matches = einMatches(in: "12-3456789")
        // Hyphen form always runs (requiresContext = false), so base 0.50 is emitted.
        #expect(matches.count >= 1, "Hyphenated EIN always surfaces regardless of context")
        if let m = matches.first {
            #expect(m.confidence == 0.50, "No context → base confidence 0.50")
        }
    }
}
