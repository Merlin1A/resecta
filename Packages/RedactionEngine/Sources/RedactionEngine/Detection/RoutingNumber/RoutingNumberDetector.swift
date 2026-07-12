import Foundation

// ABA/ACH routing-number detector.
// Format: exactly 9 digits, no separators (standard ABA usage). Valid when:
//   (a) first two digits are in the ABA valid-prefix set below,
//   (b) the ABA mod-10 checksum holds:
//       3·d1 + 7·d2 + d3 + 3·d4 + 7·d5 + d6 + 3·d7 + 7·d8 + d9 ≡ 0 (mod 10),
//   (c) confidence above base requires a routing/bank/ABA context keyword
//       within ±8 whitespace tokens (a bare 9-digit number is too common —
//       ZIP+4 runs, document control numbers — so no-context candidates stay
//       at base 0.50, below the balanced 0.60 W4 cutoff).
//
// Checksum + prefix cites: ABA Routing Number Policy (Accredited Standards
// Committee X9, administered by the American Bankers Association); Federal
// Reserve E-Payments Routing Directory prefix ranges. Verified against the
// design's worked vectors 2026-06-11 (021000021 / 322271627 / 124303120).
// Valid first-two-digit ranges: 01–12 (Federal Reserve districts, paper),
// 21–32 (thrift/savings mirror of districts 1–12), 61–72 (electronic/ACH),
// 80 (traveler's cheques — rare but valid). Never-issued/reserved prefixes
// (00, 13–20, 33–60, 73–79, 81–99) are rejected regardless of checksum.

struct RoutingNumberDetector: Sendable {

    // 9 digits with digit-boundary guards so substrings of longer numbers
    // never match (e.g. the first 9 digits of a 10-digit account number).
    static let pattern = try! NSRegularExpression(
        pattern: #"(?<!\d)\d{9}(?!\d)"#
    )

    /// ABA valid first-two-digit prefix ranges (see header cite).
    static let validFirstTwoDigitRanges: [ClosedRange<Int>] = [
        1...12,   // Federal Reserve districts 1–12 (paper)
        21...32,  // Federal Reserve districts 1–12 (thrift/savings)
        61...72,  // Electronic / ACH
        80...80,  // Traveler's cheques
    ]

    private static let positiveKeywords: Set<String> = [
        "routing", "routing number", "aba", "aba number", "aba routing",
        "ach", "wire", "wire transfer", "bank routing", "transit number",
        "routing/transit", "routing & transit", "direct deposit",
    ]

    private static let profile = KeywordProfile(
        positiveKeywords: positiveKeywords,
        negativeKeywords: [],  // S3 negative-context wiring fills this slot.
        windowRadius: 8,       // wider than SSN — routing often sits in table cells
        baseConfidence: 0.50,
        boostedConfidence: 0.88,
        floor: 0.25
    )

    private let scorer = ContextWindowScorer()

    /// ABA mod-10 checksum. Weights 3,7,1 repeating over d1..d9; valid iff
    /// the weighted sum ≡ 0 (mod 10).
    static func isValidChecksum(_ digits: [Int]) -> Bool {
        guard digits.count == 9 else { return false }
        let weights = [3, 7, 1, 3, 7, 1, 3, 7, 1]
        let total = zip(digits, weights).reduce(0) { $0 + $1.0 * $1.1 }
        return total % 10 == 0
    }

    /// First-two-digit validation against the ABA prefix ranges.
    static func isValidPrefix(_ digits: [Int]) -> Bool {
        guard digits.count >= 2 else { return false }
        let prefix = digits[0] * 10 + digits[1]
        return validFirstTwoDigitRanges.contains { $0.contains(prefix) }
    }

    func detect(in text: NSString, range: NSRange) -> [PIIDetector.PIIMatch] {
        let fullText = text as String
        let ruleID = "routingNumber.aba-checksum"
        return Self.pattern.matches(in: fullText, range: range).compactMap { match in
            let matchedText = text.substring(with: match.range)
            let digits = matchedText.compactMap { $0.wholeNumberValue }
            guard digits.count == 9 else { return nil }
            guard Self.isValidPrefix(digits) else { return nil }
            guard Self.isValidChecksum(digits) else { return nil }
            let confidence = scorer.score(
                text: fullText,
                matchRange: match.range,
                profile: Self.profile,
                category: .routingNumber
            )
            var signals: [MatchRationale.Signal] = [
                .regexPattern(name: ruleID),
                .structuralValidator(name: "routingNumber.aba-prefix"),
                .structuralValidator(name: "routingNumber.aba-mod10"),
            ]
            if let ctxSignal = scorer.signal(
                text: fullText,
                matchRange: match.range,
                profile: Self.profile,
                category: .routingNumber
            ) {
                signals.append(ctxSignal)
            }
            // WU-76 / [P4] — per-keyword breakdown alongside the scalar
            // (mirrors DEADetector).
            if let ctxDetail = scorer.signalDetail(
                text: fullText,
                matchRange: match.range,
                profile: Self.profile
            ) {
                signals.append(ctxDetail)
            }
            let rationale = MatchRationale(
                ruleID: ruleID,
                signals: signals,
                preThresholdScore: Self.profile.baseConfidence,
                finalScore: confidence
            )
            return PIIDetector.PIIMatch(
                text: matchedText,
                range: match.range,
                kind: .routingNumber,
                confidence: confidence,
                rationale: rationale
            )
        }
    }
}
