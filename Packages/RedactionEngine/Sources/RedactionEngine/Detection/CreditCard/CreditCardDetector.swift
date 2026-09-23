import Foundation

/// Payment card numbers: the digit-run regex, the Luhn checksum and the
/// issuer-prefix gate.
struct CreditCardDetector: FamilyDetector {
    typealias PIIMatch = PIIDetector.PIIMatch
    let category: PIICategory = .creditCard
    let telemetryLabel = "creditCard"

    func detect(in context: DetectionContext) -> [PIIMatch] {
        detect(in: context.nsText, range: context.range)
    }

    // MARK: - Credit Card Detection

    // Hardcoded constant pattern — try! safe (validated in PIIDetectionTests)
    // A digit run that starts or ends inside a letter-or-digit token is not a
    // card (a DL-shaped `U48670409492471` is refused before Luhn); a `#`, `.`,
    // space or line edge still admits one. Both lookarounds are one scalar
    // wide, so the pattern stays linear (ReDoSFuzzTests).
    static let ccPattern = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}])\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{1,7}(?![\p{L}\p{N}])"#
    )

    func detect(in text: NSString, range: NSRange) -> [PIIMatch] {
        Self.ccPattern.matches(in: text as String, range: range).compactMap { match in
            let matchedText = text.substring(with: match.range)
            let digits = matchedText.filter(\.isWholeNumber)
            // Triple gate: regex → Luhn → prefix
            guard Self.luhnCheck(digits), Self.hasValidCardPrefix(digits) else { return nil }
            return PIIMatch(text: matchedText, range: match.range, kind: .creditCard,
                           confidence: 0.95)
        }
    }

    /// Luhn checksum validation.
    static func luhnCheck(_ number: String) -> Bool {
        let digits = number.filter(\.isWholeNumber)
        guard digits.count >= 13, digits.count <= 19 else { return false }
        var sum = 0
        for (i, ch) in digits.reversed().enumerated() {
            guard let d = ch.wholeNumberValue else { return false }
            if i % 2 == 1 {
                let doubled = d * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else { sum += d }
        }
        return sum % 10 == 0
    }

    /// Card prefix validation: Visa 4xxx, MC 51-55/2221-2720, Amex 34/37, Discover 6011/65.
    static func hasValidCardPrefix(_ digits: String) -> Bool {
        guard digits.count >= 4 else { return false }
        let prefix2 = String(digits.prefix(2))
        let prefix4 = String(digits.prefix(4))

        if digits.hasPrefix("4") { return true }                     // Visa
        if let p = Int(prefix2), (51...55).contains(p) { return true } // MC
        if let p = Int(prefix4), (2221...2720).contains(p) { return true } // MC range 2
        if prefix2 == "34" || prefix2 == "37" { return true }        // Amex
        if prefix4 == "6011" || prefix2 == "65" { return true }      // Discover
        if let p = Int(prefix4), (3528...3589).contains(p) { return true } // JCB
        if prefix2 == "62" { return true }                           // UnionPay
        return false
    }
}
