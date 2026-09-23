import Foundation

/// Email addresses: the local-part / domain regex with the RFC 5321 length cap.
struct EmailDetector: FamilyDetector {
    typealias PIIMatch = PIIDetector.PIIMatch
    let category: PIICategory = .email
    let telemetryLabel = "email"

    func detect(in context: DetectionContext) -> [PIIMatch] {
        detect(in: context.nsText, range: context.range)
    }

    // MARK: - Email Detection

    // Hardcoded constant pattern — try! safe (validated in PIIDetectionTests)
    // The local part is anchored on a non-dot character; subsequent
    // dots are allowed only before an alphanumeric (forbids leading
    // and consecutive dots: `.a@b.co`, `a..b@c.co`). The domain anchors
    // on alphanumeric at both ends so leading-dot (`a@.b.co`) and
    // trailing-dot (`a@b..co`) domains no longer match.
    static let emailPattern = try! NSRegularExpression(
        pattern: #"[a-zA-Z0-9_%+-](?:[a-zA-Z0-9_%+-]|\.(?=[a-zA-Z0-9_%+-]))*@(?:[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?)\.[a-zA-Z]{2,}"#
    )

    func detect(in text: NSString, range: NSRange) -> [PIIMatch] {
        Self.emailPattern.matches(in: text as String, range: range).compactMap { match in
            let matchedText = text.substring(with: match.range)
            // RFC 5321: maximum email address length is 254 characters
            guard matchedText.count <= 254 else { return nil }
            return PIIMatch(text: matchedText, range: match.range,
                           kind: .email, confidence: 0.90)
        }
    }
}
