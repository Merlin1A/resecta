import Foundation

// Plan §4 / §3.1b — 10-digit NPI with the CMS Luhn-80840 checksum.
// Regex rejects any digit run abutting another digit so "1234567890" inside
// a longer number sequence doesn't trigger. Positive context keywords
// ("NPI", "provider ID") boost confidence; base 0.60 with no context since
// the checksum alone is a strong signal.

struct NPIDetector: Sendable {

    static let pattern = try! NSRegularExpression(
        pattern: #"(?<!\d)[12]\d{9}(?!\d)"#
    )

    private static let positiveKeywords: Set<String> = [
        "npi", "provider id", "provider number", "national provider",
        "national provider identifier", "provider #"
    ]

    // D04-F1: base 0.60 -> 0.65 so a bare Luhn-80840-valid NPI clears the
    // swept balanced/aggressive npi cutoff (both 0.602) with a ~0.05 posterior
    // margin at the default prior (posterior is the identity there:
    // sigma(logit(0.65)) = 0.65). Was 0.600 < 0.602 -> dropped at every preset.
    // Stays below conservative (0.85), which intentionally requires a keyword
    // boost (a labeled NPI scores boosted 0.90 and clears 0.85). The preset
    // blob 28921a52 is calibrated/byte-locked and is NOT touched.
    // preThresholdScore at :66 reflects this new base automatically.
    private static let profile = KeywordProfile(
        positiveKeywords: positiveKeywords,
        negativeKeywords: [],
        windowRadius: 5,
        baseConfidence: 0.65,
        boostedConfidence: 0.90,
        floor: 0.30
    )

    private let scorer = ContextWindowScorer()

    func detect(in text: NSString, range: NSRange) -> [PIIDetector.PIIMatch] {
        let fullText = text as String
        let ruleID = "npi.80840"
        return Self.pattern.matches(in: fullText, range: range).compactMap { match in
            let matchedText = text.substring(with: match.range)
            guard NPILuhn80840.isValid(matchedText) else { return nil }
            let confidence = scorer.score(
                text: fullText,
                matchRange: match.range,
                profile: Self.profile,
                category: .npi
            )
            var signals: [MatchRationale.Signal] = [
                .regexPattern(name: ruleID),
                .structuralValidator(name: ruleID),
            ]
            if let ctxSignal = scorer.signal(
                text: fullText,
                matchRange: match.range,
                profile: Self.profile,
                category: .npi
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
                kind: .npi,
                confidence: confidence,
                rationale: rationale
            )
        }
    }
}
