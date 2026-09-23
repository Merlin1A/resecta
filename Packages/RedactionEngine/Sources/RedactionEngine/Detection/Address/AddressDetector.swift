import Foundation

/// US postal addresses by regex: the street arm and the PO Box, rural-route
/// and APO/FPO/DPO arms, each at a fixed confidence.
struct AddressDetector: FamilyDetector {
    typealias PIIMatch = PIIDetector.PIIMatch
    let category: PIICategory = .address
    let telemetryLabel = "address"

    func detect(in context: DetectionContext) -> [PIIMatch] {
        detect(in: context.nsText, range: context.range)
    }

    // MARK: - Address Detection

    /// Detect US physical addresses. Matches patterns like
    /// "123 Main St, Anytown, CA 90210" or "456 Elm Avenue, Suite 7, NY 10001-2345".
    /// Limited to US-format addresses for v1; international deferred.
    // Hardcoded constant pattern — try! safe
    // Fixed: [a-zA-Z\s] instead of [\w\s] to prevent digit-only street name
    // false positives. .{0,100}? bounds backtracking (real addresses never
    // exceed 100 chars between street suffix and state+zip).
    static let addressPattern = try! NSRegularExpression(
        pattern: #"\d{1,5}\s+[a-zA-Z\s]{1,30}\b(?:St(?:reet)?|Ave(?:nue)?|Blvd|Boulevard|Dr(?:ive)?|Ln|Lane|Rd|Road|Ct|Court|Pl(?:ace)?|Way|Cir(?:cle)?|Pkwy|Parkway|Hwy|Highway|Ter(?:race)?|Sq(?:uare)?|Loop|Tr(?:ai)?l)\b.{0,100}?\b[A-Z]{2}\s+\d{5}(?:-\d{4})?"#,
        options: [.dotMatchesLineSeparators]
    )

    // PO Box / rural-route / APO address arms.

    /// PO Box: "P.O. Box 123", "PO Box 4567", "Post Office Box 99"
    static let poBoxPattern = try! NSRegularExpression(
        pattern: #"(?i)\b(?:P\.?O\.?\s*Box|Post\s+Office\s+Box)\s+\d{1,6}\b"#
    )

    /// Rural Route: "RR 2 Box 45", "Rural Route 3 Box 12A", "HC 1 Box 7"
    static let ruralRoutePattern = try! NSRegularExpression(
        pattern: #"(?i)\b(?:R(?:ural\s+)?R(?:oute)?|RR|HC|Star\s+Route)\s+\d{1,4}\s+Box\s+\d{1,6}[A-Z]?\b"#
    )

    /// APO/FPO/DPO: "APO AE 09010", "FPO AP 96606-0001", "DPO AA 34001"
    static let apofpoPattern = try! NSRegularExpression(
        pattern: #"(?i)\b(?:APO|FPO|DPO)\s+(?:AA|AE|AP)\s+\d{5}(?:-\d{4})?\b"#
    )

    func detect(in text: NSString, range: NSRange) -> [PIIMatch] {
        let nsText = text
        let fullText = text as String
        // Existing street-address arm (behavior unchanged from pre-WS1).
        var results: [PIIMatch] = Self.addressPattern.matches(in: fullText, range: range).map { match in
            PIIMatch(text: nsText.substring(with: match.range), range: match.range,
                    kind: .address, confidence: 0.70)
        }
        // PO Box / rural-route / APO arms. Fixed 0.70 confidence matches existing arm.
        for pattern in [Self.poBoxPattern, Self.ruralRoutePattern, Self.apofpoPattern] {
            for match in pattern.matches(in: fullText, range: range) {
                let matchedText = nsText.substring(with: match.range)
                results.append(PIIMatch(text: matchedText, range: match.range,
                                       kind: .address, confidence: 0.70))
            }
        }
        return results
    }
}
