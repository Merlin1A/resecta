import Foundation

/// Driver's licence numbers: a label-prefixed regex gated by the per-state
/// pattern gazetteer when it is bundled.
struct DriversLicenseDetector: FamilyDetector {
    typealias PIIMatch = PIIDetector.PIIMatch
    let category: PIICategory = .driversLicense
    let telemetryLabel = "dl"

    // DL pattern gazetteer (validation gate over the inline
    // label-prefix regex below). Optional for the same reason as
    // nameGazetteer: dl_patterns.json may be absent in test-bundle-only
    // builds. nil preserves pass-through behavior when absent; non-nil enables
    // per-state gating in `detect`.
    private let dlPatternGazetteer: DLPatternGazetteer?

    init(dlPatternGazetteer: DLPatternGazetteer?) {
        self.dlPatternGazetteer = dlPatternGazetteer
    }

    func detect(in context: DetectionContext) -> [PIIMatch] {
        detect(in: context.nsText, range: context.range)
    }

    // MARK: - Driver's License Detection

    /// Detect driver's license numbers. Requires a label prefix (DL, Driver's License)
    /// to avoid false positives on generic alphanumeric sequences.
    // Hardcoded constant pattern — try! safe (validated in PIIDetectionTests)
    // Tightened numeric lower bound from 3 to 6 digits. US DLs
    // are universally ≥ 6 characters; the label prefix gate narrowed
    // the blast radius but did not close it (e.g. "DL 123 Main St").
    static let driversLicensePattern = try! NSRegularExpression(
        pattern: #"(?:Driver(?:'?s)?\s+Lic(?:ense)?|DL|D\.?L\.?)\s*[:#]?\s*([A-Z]\d{4,14}|\d{6,12})"#,
        options: [.caseInsensitive]
    )

    func detect(in text: NSString, range: NSRange) -> [PIIMatch] {
        Self.driversLicensePattern.matches(in: text as String, range: range).compactMap { match in
            // Capture group 1 is the actual DL number
            let dlRange = match.range(at: 1)
            let matchedText = text.substring(with: dlRange)
            // DLPatternGazetteer validation gate. When the
            // per-state gazetteer is bundled, the candidate must match
            // at least one jurisdiction's pattern (or be passed through
            // when the gazetteer is absent in test-bundle-only builds).
            // The inline regex above matches case-insensitively to
            // tolerate OCR-noise; JSON patterns are case-sensitive (most
            // state alphabets are A-Z), so the candidate is uppercased
            // before lookup. SSN/DLN ambiguity (AR/HI/ID/LA/MS) is
            // preserved — multi-state hits keep the candidate. Confidence
            // stays at the 0.80 baseline; state-conditioned scanning
            // with a jurisdiction hint is a possible future refinement.
            if let gazetteer = dlPatternGazetteer {
                let normalized = matchedText.uppercased()
                if gazetteer.matches(normalized, anyState: ()).isEmpty {
                    return nil
                }
            }
            return PIIMatch(text: matchedText, range: match.range, kind: .driversLicense,
                           confidence: 0.80)
        }
    }
}
