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
    // wide, so the pattern stays linear (ReDoSFuzzTests). The second shape is
    // the separated 4-6-5 (American Express) and 4-6-4 (Diners Club) grouping;
    // unseparated runs of those lengths already fit the first shape.
    static let ccPattern = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}])(?:\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{1,7}|\d{4}[\s-]\d{6}[\s-]\d{4,5})(?![\p{L}\p{N}])"#
    )

    /// The digit-run shape of `ccPattern` on its own. It runs as a second
    /// pass: matches of one pattern do not overlap, so a grouped match that
    /// fails Luhn (`1234 567890 4111` in `1234 567890 4111 1111 1111 1111`)
    /// would otherwise take the first group of the card that follows it.
    static let digitRunPattern = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}])\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{1,7}(?![\p{L}\p{N}])"#
    )

    func detect(in text: NSString, range: NSRange) -> [PIIMatch] {
        let source = text as String
        // Each pass is gated on its own: regex → Luhn → prefix. Where cards
        // from the two passes overlap, the earlier-starting one is kept, and
        // on a tie the first pass's, so every card the first pass proposes
        // alone is still proposed.
        let cards = [Self.ccPattern, Self.digitRunPattern].flatMap { pattern in
            pattern.matches(in: source, range: range).compactMap { match -> PIIMatch? in
                let matchedText = text.substring(with: match.range)
                let digits = matchedText.filter(\.isWholeNumber)
                guard Self.luhnCheck(digits), Self.hasValidCardPrefix(digits) else { return nil }
                return PIIMatch(text: matchedText, range: match.range, kind: .creditCard,
                               confidence: 0.95)
            }
        }
        var kept: [PIIMatch] = []
        for card in cards.enumerated().sorted(by: {
            ($0.element.range.location, $0.offset) < ($1.element.range.location, $1.offset)
        }).map(\.element) {
            if let last = kept.last, NSIntersectionRange(last.range, card.range).length > 0 { continue }
            kept.append(card)
        }
        return kept
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
