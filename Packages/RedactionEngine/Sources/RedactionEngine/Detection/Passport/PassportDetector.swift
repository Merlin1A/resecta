import Foundation

/// Passport numbers: a label-prefixed regex gated by the per-issuer pattern
/// gazetteer when it is bundled.
struct PassportDetector: FamilyDetector {
    typealias PIIMatch = PIIDetector.PIIMatch
    let category: PIICategory = .passport
    let telemetryLabel = "passport"

    // Passport pattern gazetteer (validation gate over the
    // inline label-prefix regex in detectPassports). Optional for the
    // same reason as nameGazetteer/dlPatternGazetteer:
    // passport_patterns.json may be absent in test-bundle-only builds.
    // nil preserves pass-through behavior when absent; non-nil enables per-
    // issuer gating against the 11-issuer set (CA/CN/DO/GB/IN/KR/MX/PH/
    // SV/US/VN).
    private let passportPatternGazetteer: PassportPatternGazetteer?

    init(passportPatternGazetteer: PassportPatternGazetteer?) {
        self.passportPatternGazetteer = passportPatternGazetteer
    }

    func detect(in context: DetectionContext) -> [PIIMatch] {
        detect(in: context.nsText, range: context.range)
    }

    // MARK: - Passport Detection

    /// Detect passport numbers. Requires a label prefix ("Passport", "PP")
    /// to avoid false positives on generic alphanumeric sequences.
    // Hardcoded constant pattern — try! safe
    static let passportPattern = try! NSRegularExpression(
        pattern: #"(?:Passport|PP|Passport\s+No|Passport\s+Number)\s*[#:]?\s*([A-Z]{1,2}\d{6,9})"#,
        options: [.caseInsensitive]
    )

    func detect(in text: NSString, range: NSRange) -> [PIIMatch] {
        Self.passportPattern.matches(in: text as String, range: range).compactMap { match in
            // Capture group 1 is the actual passport number
            let ppRange = match.range(at: 1)
            let matchedText = text.substring(with: ppRange)
            // PassportPatternGazetteer validation gate. When
            // the per-issuer gazetteer is bundled, the candidate must
            // match at least one of the 11 V1 issuers' patterns
            // (CA/CN/DO/GB/IN/KR/MX/PH/SV/US/VN); otherwise it is
            // suppressed. The inline regex above matches case-insensitively
            // to tolerate OCR-noise; JSON patterns are case-sensitive
            // (every row has an A-Z alphabet), so the candidate is
            // uppercased before lookup. Multi-issuer ambiguity is
            // preserved silent — no confidence haircut, no audit log
            // (e.g. an 8-char 2L+6D matching CA-legacy or any 9-char
            // alphanumeric matching SV's permissive medium-confidence
            // ceiling). GB matches like any other row — no special-cased
            // attribution.
            // Confidence stays at the 0.80 baseline; issuer-conditioned
            // scanning with a country-name hint from the orchestrator is a
            // possible future refinement.
            if let gazetteer = passportPatternGazetteer {
                let normalized = matchedText.uppercased()
                if gazetteer.matches(normalized, anyIssuer: ()).isEmpty {
                    return nil
                }
            }
            return PIIMatch(text: matchedText, range: match.range, kind: .passport,
                           confidence: 0.80)
        }
    }
}
