import Foundation

/// Employer Identification Numbers: three format arms (hyphenated, space and
/// no separator — the last two need context), the never-issued prefixes and
/// the context scorer.
struct EINDetector: FamilyDetector {
    typealias PIIMatch = PIIDetector.PIIMatch
    let category: PIICategory = .ein
    let telemetryLabel = "ein"

    // EIN detection uses a ContextWindowScorer to weigh nearby keywords.
    private let einScorer = ContextWindowScorer()
    // Visibility widened private→internal: ContextFeatures.swift reads
    // this shipped profile's keyword sets verbatim for the EIN family. Read-only.
    static let einProfile = KeywordProfile(
        positiveKeywords: [
            "ein", "employer identification", "employer id", "federal tax id",
            "fein", "federal ein", "payer's tin", "payer tin", "recipient tin",
            "box b", "employer's ein", "taxpayer id", "tax id number",
            "irs form", "w-2", "1099", "schedule c",
            // Bare "employer" carries over from the earlier inline keyword
            // list (legacy recall pinned by a SecurityTests assertion on
            // EIN context boost with a distant label); the longer
            // employer-* phrases above are subsumed by substring matching
            // but kept for parity with the pipeline vocabulary.
            "employer"
        ],
        negativeKeywords: [],   // WS2 will add; leave empty to avoid over-suppression pre-wiring
        windowRadius: 6,
        baseConfidence: 0.50,
        boostedConfidence: 0.85,
        floor: 0.25
    )

    func detect(in context: DetectionContext) -> [PIIMatch] {
        detect(in: context.nsText, range: context.range)
    }

    // MARK: - EIN Detection

    // Three format variants.
    // Primary: hyphenated (always runs, no extra FP risk).
    static let einPatternHyphen = try! NSRegularExpression(
        pattern: #"(?<!\d)\d{2}-\d{7}(?!\d)"#
    )
    // Space-separated (context required): OCR output from hyphenated EINs.
    static let einPatternSpace = try! NSRegularExpression(
        pattern: #"(?<!\d)\d{2} \d{7}(?!\d)"#
    )
    // No-separator (context required): MICR-derived; high FP risk without label.
    // Note: overlaps with ABA routing numbers — context differentiates them.
    static let einPatternNoSep = try! NSRegularExpression(
        pattern: #"(?<!\d)\d{9}(?!\d)"#
    )

    /// IRS never-issued EIN prefixes as of 2026.
    /// Source: IRS IRM 21.7.13 "Assigning Employer Identification Numbers (EINs)"
    /// (https://www.irs.gov/irm/part21/irm_21-007-013r), accessed 2026-06-11.
    /// "EIN Prefixes 00, 07, 08, 09, 17, 18, 19, 28, 29, 49, 69, 70, 78, 79, 89, 96
    /// and 97 are considered invalid for input and are no longer being assigned."
    /// Verified set matches design doc exactly — no delta.
    private static let invalidEINPrefixes: Set<String> = [
        "00", "07", "08", "09", "17", "18", "19",
        "28", "29", "49", "69", "70", "78", "79", "89", "96", "97"
    ]

    // Three format arms with prefix validation and scorer.
    func detect(in text: NSString, range: NSRange) -> [PIIMatch] {
        var results: [PIIMatch] = []
        let fullText = text as String
        for (pattern, requiresContext) in [
            (Self.einPatternHyphen, false),
            (Self.einPatternSpace, true),
            (Self.einPatternNoSep, true)
        ] {
            for match in pattern.matches(in: fullText, range: range) {
                let matchedText = text.substring(with: match.range)
                // Prefix validation: strip separator, take first 2 digits.
                let digits = matchedText.filter { $0.isNumber }
                guard digits.count == 9 else { continue }
                let prefix = String(digits.prefix(2))
                guard !Self.invalidEINPrefixes.contains(prefix) else { continue }
                let confidence = einScorer.score(
                    text: fullText, matchRange: match.range,
                    profile: Self.einProfile, category: .ein
                )
                if requiresContext, confidence <= Self.einProfile.baseConfidence { continue }
                results.append(PIIMatch(text: matchedText, range: match.range,
                                       kind: .ein, confidence: confidence))
            }
        }
        return results
    }
}
