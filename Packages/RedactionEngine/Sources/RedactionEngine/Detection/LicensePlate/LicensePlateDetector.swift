import Foundation

/// Licence plates: the labelled-plate regex scored by the context window,
/// with the negative-context gazetteer and the institution-anchor header
/// handed in per page. Court, FOIA and generic doctypes.
struct LicensePlateDetector: FamilyDetector {
    typealias PIIMatch = PIIDetector.PIIMatch
    let category: PIICategory = .licensePlate
    let telemetryLabel = "licensePlate"

    private let contextScorer: ContextWindowScorer
    private let contextLoader: ContextKeywordsLoader?

    init(contextScorer: ContextWindowScorer, contextLoader: ContextKeywordsLoader?) {
        self.contextScorer = contextScorer
        self.contextLoader = contextLoader
    }

    /// License plate: court + FOIA + generic. nil doctype → run.
    func runs(doctype: DoctypeClass?) -> Bool {
        guard let doctype else { return true }
        return doctype == .court || doctype == .foia || doctype == .generic
    }

    func detect(in context: DetectionContext) -> [PIIMatch] {
        detect(in: context.nsText, range: context.range,
               doctype: context.doctype, gazetteer: context.gazetteer,
               documentHeader: context.documentHeader)
    }

    // MARK: - License Plate Detection

    /// License plate labels: accepts "License plate", "Plate No", "Tag #",
    /// "LP #", "Reg #", "Vehicle plate" followed by the plate value (group 1).
    /// The label reads case-insensitively; the value is read again as written
    /// by `isPlateValue`, so a label followed by ordinary words ("Reg # on
    /// file", "Reg # to be") is not a plate.
    static let licensePlateLabeled = try! NSRegularExpression(
        pattern: #"\b(?:license\s+plate|plate\s+(?:no|number|#)\.?|tag\s+(?:no|number|#)\.?|lp\s*#|reg(?:istration)?\s*#|veh(?:icle)?\s+plate)[:#\s]+([A-Z0-9]{2,3}[-\s]?[A-Z0-9]{2,5})\b"#,
        options: [.caseInsensitive]
    )

    /// A plate value as written: upper-case letters and digits, split at most
    /// by a hyphen or whitespace (a non-breaking space or a line break counts),
    /// carrying a digit or an unbroken run of three or more capitals (a vanity
    /// plate). Lower-case words after a label are prose, not a plate.
    static func isPlateValue(_ value: String) -> Bool {
        var sawDigit = false
        var capitalRun = 0
        var longestCapitalRun = 0
        for scalar in value.unicodeScalars {
            switch scalar {
            case "0"..."9":
                sawDigit = true
                capitalRun = 0
            case "A"..."Z":
                capitalRun += 1
                longestCapitalRun = max(longestCapitalRun, capitalRun)
            case "-":
                capitalRun = 0
            default:
                guard scalar.properties.isWhitespace else { return false }
                capitalRun = 0
            }
        }
        return sawDigit || longestCapitalRun >= 3
    }

    /// Detect license plates (labeled only). Gated by `runsLicensePlate`.
    ///
    /// `doctype` and `gazetteer` enable per-(category, doctype) negative-context
    /// suppression. Both default to nil for backward-compatibility.
    ///
    /// `documentHeader` enables institution-anchor suppression. Nil = inactive.
    func detect(
        in text: NSString,
        range: NSRange,
        doctype: DoctypeClass? = nil,
        gazetteer: NegativeContextGazetteer? = nil,
        documentHeader: String? = nil
    ) -> [PIIMatch] {
        let fullText = text as String
        let ruleID = "licensePlate.labeled"
        // Positive set from the bundled corpus; engine-side const fallback. See
        // SSNDetector for scope rationale (positive-only V1).
        let baseline = LicensePlateContextKeywords.profile
        let positives = contextLoader?.positiveKeywords(for: .licensePlate, doctype: nil)
            ?? baseline.positiveKeywords
        let profile = KeywordProfile(
            positiveKeywords: positives,
            negativeKeywords: baseline.negativeKeywords,
            windowRadius: baseline.windowRadius,
            baseConfidence: baseline.baseConfidence,
            boostedConfidence: baseline.boostedConfidence,
            floor: baseline.floor
        )
        return Self.licensePlateLabeled.matches(in: fullText, range: range).compactMap { match in
            guard Self.isPlateValue(text.substring(with: match.range(at: 1))) else { return nil }
            // Pass doctype + gazetteer + documentHeader.
            let confidence = contextScorer.score(
                text: fullText, matchRange: match.range, profile: profile,
                category: .licensePlate, doctype: doctype, gazetteer: gazetteer,
                documentHeader: documentHeader
            )
            let contextSignal = contextScorer.signal(
                text: fullText, matchRange: match.range, profile: profile,
                category: .licensePlate, doctype: doctype, gazetteer: gazetteer,
                documentHeader: documentHeader
            )
            // Attach negativeContextSuppressed signal when gazetteer fired.
            var gazetteerSignal: MatchRationale.Signal?
            if let gaz = gazetteer, let dt = doctype {
                gazetteerSignal = contextScorer.gazetteerSignal(
                    text: fullText, matchRange: match.range,
                    category: .licensePlate, doctype: dt, gazetteer: gaz)
            }
            return PIIMatch(
                text: text.substring(with: match.range),
                range: match.range,
                kind: .licensePlate,
                confidence: confidence,
                rationale: .contextScored(
                    ruleID: ruleID, preThresholdScore: profile.baseConfidence,
                    contextSignal: contextSignal, gazetteerSignal: gazetteerSignal,
                    finalScore: confidence
                )
            )
        }
    }
}
