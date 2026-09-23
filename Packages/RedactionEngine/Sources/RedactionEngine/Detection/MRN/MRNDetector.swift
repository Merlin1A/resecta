import Foundation

/// Medical record numbers: three labelled patterns scored by the context
/// window, with the negative-context gazetteer and the institution-anchor
/// header handed in per page. Medical doctype only.
struct MRNDetector: FamilyDetector {
    typealias PIIMatch = PIIDetector.PIIMatch
    let category: PIICategory = .medicalRecord
    let telemetryLabel = "mrn"

    private let contextScorer: ContextWindowScorer
    private let contextLoader: ContextKeywordsLoader?

    init(contextScorer: ContextWindowScorer, contextLoader: ContextKeywordsLoader?) {
        self.contextScorer = contextScorer
        self.contextLoader = contextLoader
    }

    /// MRN: medical only. nil doctype → run.
    func runs(doctype: DoctypeClass?) -> Bool {
        guard let doctype else { return true }
        return doctype == .medical
    }

    func detect(in context: DetectionContext) -> [PIIMatch] {
        detect(in: context.nsText, range: context.range,
               doctype: context.doctype, gazetteer: context.gazetteer,
               documentHeader: context.documentHeader)
    }

    // MARK: - Medical Record Number Detection

    /// MRN labeled by an explicit `MRN` / `MR#` prefix, followed by 5–12
    /// alphanumerics. Widened from `\d{6,10}` — real-world
    /// medical records (and 100 % of the G8 medical corpus) use prefixed
    /// alphanumeric IDs like `QD793210`. Context-window scoring dampens
    /// false positives on non-medical docs.
    // Hardcoded constant pattern — try! safe.
    static let mrnPatternLabeled = try! NSRegularExpression(
        pattern: #"\bMR[N]?[:#\s]+[A-Z0-9]{5,12}\b"#,
        options: [.caseInsensitive]
    )

    /// MRN labeled as `Patient ID`, followed by an alphanumeric identifier.
    static let mrnPatternPatientID = try! NSRegularExpression(
        pattern: #"\bPatient\s+ID[:#\s]+[A-Z0-9]{5,12}\b"#,
        options: [.caseInsensitive]
    )

    /// Institution-prefixed MRN shape: `ABC-1234567`. Context-scored so the
    /// same shape in non-medical docs gets dampened.
    static let mrnPatternInstitution = try! NSRegularExpression(
        pattern: #"\b[A-Z]{2,5}-\d{6,10}\b"#,
        options: []
    )

    /// Detect medical record numbers using three labeled patterns + context
    /// scoring. Signature mirrors `SSNDetector.detect(in:range:)` (no scorer/fullText
    /// param — derive inline, use `self.contextScorer`).
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
        let patterns: [(NSRegularExpression, String)] = [
            (Self.mrnPatternLabeled, "mrn.labeled"),
            (Self.mrnPatternPatientID, "mrn.patientID"),
            (Self.mrnPatternInstitution, "mrn.institution"),
        ]
        // Positive set from the bundled corpus; engine-side const fallback. See
        // SSNDetector for scope rationale (positive-only V1).
        // Sentinel-prefix tweak: drop MRN positives flagged
        // `detector_requires_secondary` from the firing set so a sentinel
        // term does not score on its own; co-occurrence with a non-
        // sentinel positive remains required. No-op until the corpus ships
        // sentinel-flagged MRN entries (none currently).
        let baseline = MRNContextKeywords.profile
        var positives = contextLoader?.positiveKeywords(for: .medicalRecord, doctype: nil)
            ?? baseline.positiveKeywords
        if let loader = contextLoader {
            let sentinels = Set(loader.entries(for: .medicalRecord)
                .filter { $0.detectorRequiresSecondary == true && $0.doctypes.isEmpty }
                .map { $0.term.lowercased() })
            positives.subtract(sentinels)
        }
        let profile = KeywordProfile(
            positiveKeywords: positives,
            negativeKeywords: baseline.negativeKeywords,
            windowRadius: baseline.windowRadius,
            baseConfidence: baseline.baseConfidence,
            boostedConfidence: baseline.boostedConfidence,
            floor: baseline.floor
        )
        var out: [PIIMatch] = []
        for (regex, ruleID) in patterns {
            for match in regex.matches(in: fullText, range: range) {
                // Pass doctype + gazetteer + documentHeader.
                let confidence = contextScorer.score(
                    text: fullText, matchRange: match.range, profile: profile,
                    category: .medicalRecord, doctype: doctype, gazetteer: gazetteer,
                    documentHeader: documentHeader
                )
                var signals: [MatchRationale.Signal] = [.regexPattern(name: ruleID)]
                if let ctxSignal = contextScorer.signal(
                    text: fullText, matchRange: match.range, profile: profile,
                    category: .medicalRecord, doctype: doctype, gazetteer: gazetteer,
                    documentHeader: documentHeader
                ) {
                    signals.append(ctxSignal)
                }
                // Attach negativeContextSuppressed signal when gazetteer fired.
                if let gaz = gazetteer, let dt = doctype,
                   let suppSignal = contextScorer.gazetteerSignal(
                       text: fullText, matchRange: match.range,
                       category: .medicalRecord, doctype: dt, gazetteer: gaz) {
                    signals.append(suppSignal)
                }
                let rationale = MatchRationale(
                    ruleID: ruleID,
                    signals: signals,
                    preThresholdScore: profile.baseConfidence,
                    finalScore: confidence
                )
                out.append(PIIMatch(
                    text: text.substring(with: match.range),
                    range: match.range,
                    kind: .medicalRecord,
                    confidence: confidence,
                    rationale: rationale
                ))
            }
        }
        return out
    }
}
