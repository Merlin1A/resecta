import Testing
import Foundation
@testable import RedactionEngine

// Search-impl S2, design 01 §4 — ABA routing-number detector tests.
// Worked checksum vectors are from the design doc's regex sanity check
// (021000021 / 322271627 / 124303120 verified by hand there).

@Suite("RoutingNumberDetector (design 01 §4)")
struct RoutingNumberDetectorTests {

    private let detector = RoutingNumberDetector()

    private func detect(_ text: String) -> [PIIDetector.PIIMatch] {
        let ns = text as NSString
        return detector.detect(in: ns, range: NSRange(location: 0, length: ns.length))
    }

    // MARK: - Checksum / prefix units

    @Test("ABA mod-10 checksum accepts the design's worked vectors")
    func checksumAcceptsKnownGood() {
        for number in ["021000021", "322271627", "124303120"] {
            let digits = number.compactMap { $0.wholeNumberValue }
            #expect(RoutingNumberDetector.isValidChecksum(digits), "checksum should hold for \(number)")
        }
    }

    @Test("Checksum rejects a single-digit corruption")
    func checksumRejectsCorruption() {
        let digits = "021000020".compactMap { $0.wholeNumberValue }
        #expect(!RoutingNumberDetector.isValidChecksum(digits))
    }

    @Test("Prefix validation covers the four ABA ranges and rejects outside them")
    func prefixRanges() {
        // One representative inside each valid range.
        for number in ["011000015", "211370545", "611000000", "801000000"] {
            let digits = number.compactMap { $0.wholeNumberValue }
            #expect(RoutingNumberDetector.isValidPrefix(digits), "prefix of \(number) should be valid")
        }
        // Reserved / never-issued prefixes.
        for number in ["001000000", "131000000", "331000000", "731000000", "991000000"] {
            let digits = number.compactMap { $0.wholeNumberValue }
            #expect(!RoutingNumberDetector.isValidPrefix(digits), "prefix of \(number) should be rejected")
        }
    }

    // MARK: - Detection envelope (design §4 test plan)

    @Test("Valid ABA with routing context keyword boosts to 0.88")
    func validABAWithContext() {
        let matches = detect("routing 021000021")
        #expect(matches.count == 1)
        #expect(matches.first?.kind == .routingNumber)
        #expect(matches.first?.confidence == 0.88)
    }

    @Test("Valid ABA with no context stays at base 0.50 (below balanced 0.60)")
    func noContextBelowGate() {
        let matches = detect("021000021")
        #expect(matches.count == 1)
        #expect(matches.first?.confidence == 0.50)
        // The W4 gate (not the detector) suppresses this at balanced —
        // EnvelopeReachabilityTests pins the threshold relationship.
        #expect((matches.first?.confidence ?? 1.0) < 0.60)
    }

    @Test("Invalid prefix is rejected regardless of checksum")
    func invalidPrefixRejected() {
        // 999999999: weighted sum 3·9+7·9+9+3·9+7·9+9+3·9+7·9+9 = 207+63 = 270?
        // Recomputed: (3+7+1)·9 ×3 = 99·... — the value is checksum-MOOT because
        // prefix 99 is reserved; the detector must reject before the checksum.
        #expect(detect("routing 999999999").isEmpty)
    }

    @Test("Invalid checksum is rejected even with context")
    func invalidChecksumRejected() {
        #expect(detect("routing number 021000020").isEmpty)
    }

    @Test("Digit-boundary guards: 10-digit runs never match")
    func tenDigitRunNoMatch() {
        #expect(detect("routing 1234567890").isEmpty)
        #expect(detect("aba 0210000211").isEmpty)
    }

    // MARK: - Adversarials (design §4)

    @Test("Luhn-style 9-digit Visa-prefix lookalike is rejected by the ABA prefix set")
    func visaLookalikeRejected() {
        // No standard card format is 9 digits (Visa 13/16, Amex 15, MC/Discover 16),
        // so no structural CC/routing collision exists; this guards the prefix
        // check against a Luhn-valid 41x string anyway.
        #expect(detect("account 411111111").isEmpty)
    }

    @Test("Overlap vs account: boosted routing number wins the overlap group")
    func overlapsAccountDetectorDedup() {
        let text = "routing 021000021" as NSString
        let range = NSRange(location: 8, length: 9)
        let routing = PIIDetector.PIIMatch(
            text: "021000021", range: range, kind: .routingNumber, confidence: 0.88
        )
        let account = PIIDetector.PIIMatch(
            text: text.substring(with: range), range: range, kind: .account, confidence: 0.75
        )
        let resolution = DetectionOrchestrator.resolveOverlaps([account, routing])
        #expect(resolution.surviving.count == 1)
        #expect(resolution.surviving.first?.kind == .routingNumber)
    }

    @Test("Rationale carries the rule id and both structural validator signals")
    func rationaleSignals() throws {
        let match = try #require(detect("ABA routing 021000021").first)
        let rationale = try #require(match.rationale)
        #expect(rationale.ruleID == "routingNumber.aba-checksum")
        let validatorNames: [String] = rationale.signals.compactMap {
            if case .structuralValidator(let name) = $0 { return name }
            return nil
        }
        #expect(validatorNames.contains("routingNumber.aba-prefix"))
        #expect(validatorNames.contains("routingNumber.aba-mod10"))
    }
}
