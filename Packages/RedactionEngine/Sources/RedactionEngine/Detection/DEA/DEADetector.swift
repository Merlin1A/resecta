import Foundation

// Plan §4 / §3.1b — DEA registration number. Format: two uppercase letters
// + seven digits. First letter = registrant type (A/B/F/G/M/P/R); second
// letter = first letter of registrant surname (or 9 for NPs/midlevels).
// Checksum: (d1 + d3 + d5) + 2·(d2 + d4 + d6) with last digit of result
// matching d7.

struct DEADetector: Sendable {

    static let pattern = try! NSRegularExpression(
        pattern: #"(?<![A-Z])[A-Z]{2}\d{7}(?!\d)"#
    )

    private static let positiveKeywords: Set<String> = [
        "dea", "dea #", "dea number", "dea registration", "registration",
        "prescriber", "prescription"
    ]

    private static let profile = KeywordProfile(
        positiveKeywords: positiveKeywords,
        negativeKeywords: [],
        windowRadius: 5,
        baseConfidence: 0.55,
        boostedConfidence: 0.90,
        floor: 0.25
    )

    private let scorer = ContextWindowScorer()

    /// Valid DEA registrant-type first letters.
    /// Source: DEA Office of Diversion Control, Practitioner's Manual §I.A;
    /// 21 CFR §1301.11; confirmed via Wikipedia "DEA number" article cross-referenced
    /// against DEA Diversion Control public documentation (accessed 2026-06-11).
    /// Full set: A (deprecated hospital/clinic pre-1985), B (hospital/clinic),
    /// C (practitioner), D (teaching institution), E (manufacturer), F (distributor),
    /// G (researcher), H (analytical lab), J (importer), K (exporter),
    /// L (reverse distributor), M (mid-level practitioner, added 1993),
    /// P/R/S/T/U (narcotic treatment programs), X (DATA 2000 waiver / Suboxone,
    /// no longer newly issued post-2022 but still valid for historic records).
    /// Letters I, N, O, Q, V, W, Y, Z have no documented registrant assignment.
    /// ENGINE §4.11 / WS1 item 1.11 (2026-06-10).
    private static let validRegistrantLetters: Set<Character> = [
        "A", "B", "C", "D", "E", "F", "G", "H",
        "J", "K", "L", "M", "P", "R", "S", "T", "U", "X"
    ]

    static func isValidChecksum(_ code: String) -> Bool {
        // Two letters, then 7 digits. Checksum = sum of 1st/3rd/5th digits +
        // 2× sum of 2nd/4th/6th; last digit of that total must equal the 7th.
        guard code.count == 9 else { return false }
        let chars = Array(code)
        guard chars[0].isLetter, chars[1].isLetter else { return false }
        let digits: [Int] = chars[2...].compactMap { $0.wholeNumberValue }
        guard digits.count == 7 else { return false }
        let oddSum = digits[0] + digits[2] + digits[4]
        let evenSum = digits[1] + digits[3] + digits[5]
        let total = oddSum + 2 * evenSum
        return total % 10 == digits[6]
    }

    /// Validates that the first letter is a documented DEA registrant-type code.
    /// This is a separate semantic gate from the checksum arithmetic — a number
    /// can pass the checksum while having an undocumented registrant type.
    /// Cite: DEA Practitioner's Manual §I.A; 21 CFR §1301.11 (WS1 item 1.11, 2026-06-10).
    /// The regex [A-Z]{2} matches uppercase only, so chars[0] is uppercase on entry; no uppercasing needed.
    static func isValidRegistrantLetter(_ code: String) -> Bool {
        guard let first = code.first else { return false }
        return validRegistrantLetters.contains(first)
    }

    func detect(in text: NSString, range: NSRange) -> [PIIDetector.PIIMatch] {
        let fullText = text as String
        let ruleID = "dea.letter-check"
        return Self.pattern.matches(in: fullText, range: range).compactMap { match in
            let matchedText = text.substring(with: match.range)
            guard Self.isValidChecksum(matchedText) else { return nil }
            // ENGINE §4.11: registrant-type first-letter gate (WS1 item 1.11, 2026-06-10).
            // Applied after checksum to allow isValidChecksum to remain a pure arithmetic
            // predicate (preserving vector test contract). Unrecognized first letter →
            // fail-safe miss (no false positive); user can manually redact. New DEA
            // registrant types are added rarely (last: J ≈2010, M ≈1993).
            guard Self.isValidRegistrantLetter(matchedText) else { return nil }
            let confidence = scorer.score(
                text: fullText,
                matchRange: match.range,
                profile: Self.profile,
                category: .dea
            )
            var signals: [MatchRationale.Signal] = [
                .regexPattern(name: ruleID),
                .structuralValidator(name: "dea.checksum"),
            ]
            if let ctxSignal = scorer.signal(
                text: fullText,
                matchRange: match.range,
                profile: Self.profile,
                category: .dea
            ) {
                signals.append(ctxSignal)
            }
            // WU-76 / [P4] — per-keyword breakdown alongside the scalar.
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
                kind: .dea,
                confidence: confidence,
                rationale: rationale
            )
        }
    }
}
