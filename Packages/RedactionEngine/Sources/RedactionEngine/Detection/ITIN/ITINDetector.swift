import Foundation

/// Individual Taxpayer Identification Numbers: the 9XX regex, the IRS YY-bucket
/// gate and the context scorer.
struct ITINDetector: FamilyDetector {
    typealias PIIMatch = PIIDetector.PIIMatch
    let category: PIICategory = .itin
    let telemetryLabel = "itin"

    // ITIN detection uses a ContextWindowScorer to weigh nearby keywords.
    private let itinScorer = ContextWindowScorer()
    // Visibility widened private→internal: ContextFeatures.swift reads
    // this shipped profile's keyword sets verbatim for the ITIN family. Read-only.
    static let itinProfile = KeywordProfile(
        positiveKeywords: [
            "itin", "individual taxpayer identification", "individual taxpayer id",
            "tax identification number", "w-7", "irs form w-7",
            "taxpayer identification", "tin"
        ],
        negativeKeywords: [],
        windowRadius: 8,   // ±100 chars ≈ 8–10 tokens; matching existing ±100-char window
        baseConfidence: 0.60,
        boostedConfidence: 0.85,
        floor: 0.25
    )

    func detect(in context: DetectionContext) -> [PIIMatch] {
        detect(in: context.nsText, range: context.range)
    }

    // MARK: - ITIN Detection

    /// Detect Individual Taxpayer Identification Numbers (9XX-XX-XXXX).
    /// SSN regex explicitly excludes 9XX area codes, so ITINs need their own pattern.
    /// Backreference \1 enforces consistent separator (same as SSN pattern).
    // Hardcoded constant pattern — try! safe (validated in PIIDetectionTests)
    static let itinPattern = try! NSRegularExpression(
        pattern: #"(?<!\d)9\d{2}([- \x{2011}\x{2012}\x{2013}\x{2014}]?)\d{2}\1\d{4}(?!\d)"#
    )

    /// IRS-issued ITINs carry YY (positions 4-5 of the 9-digit area+group+serial)
    /// in one of four ranges: [50-65, 70-88, 90-92, 94-99]. Returns false when
    /// YY falls outside every range, so the detector emits no match for
    /// structurally-shaped-but-unissued candidates.
    private static func isValidITINYY(_ match: Substring) -> Bool {
        let digits = match.filter { $0.isASCII && $0.isNumber }
        guard digits.count == 9 else { return false }
        let yyStart = digits.index(digits.startIndex, offsetBy: 3)
        let yyEnd = digits.index(yyStart, offsetBy: 2)
        guard let yy = Int(digits[yyStart..<yyEnd]) else { return false }
        return (50...65).contains(yy) || (70...88).contains(yy)
            || (90...92).contains(yy) || (94...99).contains(yy)
    }

    func detect(in text: NSString, range: NSRange) -> [PIIMatch] {
        let fullText = text as String
        return Self.itinPattern.matches(in: fullText, range: range).compactMap { match in
            let matchedText = text.substring(with: match.range)
            // Enforce IRS YY-bucket ranges after the regex gate. The
            // regex only establishes the 9XX area and digit shape; the
            // bucket check distinguishes actually-issued ITINs from
            // structurally-similar-but-unissued numbers.
            guard Self.isValidITINYY(Substring(matchedText)) else { return nil }
            // ContextWindowScorer migration.
            // Functionally equivalent to prior inline hasContext ternary (0.60/0.85);
            // verified: prior inline values were 0.60 base / 0.85 boosted — exact match
            // to itinProfile — no behavior change for existing matches.
            let confidence = itinScorer.score(
                text: fullText, matchRange: match.range,
                profile: Self.itinProfile, category: .itin
            )
            // Build rationale signals matching DEADetector pattern.
            var rationale = MatchRationale.Builder(
                ruleID: "itin.yy-bucket", preThresholdScore: Self.itinProfile.baseConfidence,
                signals: [
                    .regexPattern(name: "itin.yy-bucket"),
                    .structuralValidator(name: "itin.irs-yy-ranges"),
                ]
            )
            rationale.append(itinScorer.signal(text: fullText, matchRange: match.range,
                                               profile: Self.itinProfile, category: .itin))
            return PIIMatch(text: matchedText, range: match.range, kind: .itin,
                           confidence: confidence, rationale: rationale.build(finalScore: confidence))
        }
    }
}
