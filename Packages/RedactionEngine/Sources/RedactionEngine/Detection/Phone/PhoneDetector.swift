import Foundation

/// Phone numbers: the balanced-paren regex and the ±80-char cue window (the
/// positive cues, the labelled-number negatives, the negative-only drop).
struct PhoneDetector: FamilyDetector {
    typealias PIIMatch = PIIDetector.PIIMatch
    let category: PIICategory = .phone
    let telemetryLabel = "phone"

    func detect(in context: DetectionContext) -> [PIIMatch] {
        detect(in: context.nsText, range: context.range)
    }

    // MARK: - Phone Detection

    // Hardcoded constant pattern — try! safe (validated in PIIDetectionTests)
    // Two alternations force balanced parentheses — either
    // `(###) ###-####` or `### ###-####`. Bare `+` is dropped (only
    // `+1` leads). Unbalanced-paren inputs like `(555 123-4567` no
    // longer have their leading `(` absorbed into the match.
    static let phonePattern = try! NSRegularExpression(
        pattern: #"(?<!\d)(?:\+1[\s.-]?)?(?:\(\d{3}\)[\s.-]?\d{3}[\s.-]?\d{4}|\d{3}[\s.-]?\d{3}[\s.-]?\d{4})(?!\d)"#
    )

    /// Keywords that, when found near a 10-digit number, indicate a phone number
    /// rather than a case number, reference ID, or other numeric sequence.
    // Visibility widened private→internal: ContextFeatures.swift reads
    // these two shipped phone keyword sets verbatim. Read-only; no behavior change.
    // The bare word "number" is not a cue: it labels account, reference,
    // passport and record numbers as readily as phones, so the phone reading
    // of "number" is carried by the phrases at the end of the list (each read
    // as a whole token by KeywordMatch).
    static let phoneContextKeywords = [
        "phone", "tel", "fax", "call", "contact", "mobile", "cell",
        "dial", "sms", "text", "reach", "voicemail", "ext", "extension",
        // Whole-token reading (KeywordMatch): `tel`, `phone` and `call` no
        // longer read inside these two words, so they are listed on their own.
        "telephone", "calling",
        // The phrase cues that carry "number" for a phone.
        "phone number", "telephone number", "contact number", "fax number",
        "mobile number", "cell number", "phone no", "tel no",
        "call us at", "reach us at"
    ]

    /// Keywords that indicate a 10-digit number is NOT a phone number.
    /// Reduces false positives on case/docket/reference numbers common in legal
    /// docs and on labelled account, routing, member, policy, loan, confirmation,
    /// control and record numbers. Multi-word phrases (plus the MRN label) to
    /// avoid over-suppression on single common words. A negative drops the
    /// candidate only when no positive cue is in the window.
    static let phoneNegativeKeywords = [
        "case no", "case #", "case number", "docket no", "docket #",
        "ref #", "ref no", "reference no", "reference #", "reference number",
        "claim no", "claim #", "invoice no", "invoice #",
        "order no", "order #", "account no", "account #", "account number",
        "policy no", "policy #", "policy number", "file no", "file #",
        "routing number", "member number", "loan number",
        "confirmation number", "control number", "record number", "mrn"
    ]

    func detect(in text: NSString, range: NSRange) -> [PIIMatch] {
        Self.phonePattern.matches(in: text as String, range: range).compactMap { match in
            let matchedText = text.substring(with: match.range)
            // ±80 chars context window for phone-specific keywords.
            // Reduces false positives on 10-digit sequences (case numbers,
            // reference IDs) while boosting real phone numbers.
            let contextRange = NSRange(
                location: max(0, match.range.location - 80),
                length: min(text.length, match.range.location + match.range.length + 80) - max(0, match.range.location - 80)
            )
            let context = text.substring(with: contextRange).lowercased() as NSString

            // Negative context: skip matches near case/docket/reference labels.
            // Keywords read as whole tokens (KeywordMatch).
            let hasNegativeContext = Self.phoneNegativeKeywords.contains { KeywordMatch.containsToken($0, in: context) }
            let hasPositiveContext = Self.phoneContextKeywords.contains { KeywordMatch.containsToken($0, in: context) }

            // If negative context found and no positive context to override, skip
            if hasNegativeContext && !hasPositiveContext { return nil }

            // Base 0.60 (up from 0.55), boosted to 0.80 with context keywords
            return PIIMatch(text: matchedText, range: match.range,
                           kind: .phone, confidence: hasPositiveContext ? 0.80 : 0.60)
        }
    }
}
