import Foundation

/// Social Security numbers: the linear-time state machine, the structural
/// validator and the context scorer, with the negative-context gazetteer and
/// the institution-anchor header handed in per page.
struct SSNDetector: FamilyDetector {
    typealias PIIMatch = PIIDetector.PIIMatch
    let category: PIICategory = .ssn
    let telemetryLabel = "ssn"

    // SSN pipeline components — stored to avoid re-allocation per call.
    private let ssnStateMachine = SSNStateMachine()
    private let ssnValidator = SSNStructuralValidator()
    private let contextScorer: ContextWindowScorer
    private let contextLoader: ContextKeywordsLoader?

    init(contextScorer: ContextWindowScorer, contextLoader: ContextKeywordsLoader?) {
        self.contextScorer = contextScorer
        self.contextLoader = contextLoader
    }

    func detect(in context: DetectionContext) -> [PIIMatch] {
        detect(in: context.nsText, range: context.range,
               doctype: context.doctype, gazetteer: context.gazetteer,
               documentHeader: context.documentHeader)
    }

    // MARK: - SSN Detection

    /// SSN detection via linear-time state machine + structural validation + context scoring.
    /// Replaces the regex-based approach for lower FP rate.
    ///
    /// `doctype` and `gazetteer` enable per-(category, doctype) negative-context
    /// suppression. Both default to nil for backward-compatibility with existing call sites
    /// and test-bundle-only builds. When nil, the scorer runs without the gazetteer layer.
    ///
    /// `documentHeader` enables institution-anchor suppression.
    /// Nil = header-anchor path inactive (no behavior change for existing call sites).
    func detect(
        in text: NSString,
        range: NSRange,
        doctype: DoctypeClass? = nil,
        gazetteer: NegativeContextGazetteer? = nil,
        documentHeader: String? = nil
    ) -> [PIIMatch] {
        let fullText = text as String
        let candidates = ssnStateMachine.scan(fullText)
        // Positive-keyword set sourced from the bundled corpus
        // (`context-keywords.json`) when the loader is wired; engine-side const
        // fallback otherwise. Negative keywords and the confidence/window
        // constants stay engine-side for now.
        let baseline = SSNContextKeywords.profile
        let positives = contextLoader?.positiveKeywords(for: .ssn, doctype: nil)
            ?? baseline.positiveKeywords
        let profile = KeywordProfile(
            positiveKeywords: positives,
            negativeKeywords: baseline.negativeKeywords,
            windowRadius: baseline.windowRadius,
            baseConfidence: baseline.baseConfidence,
            boostedConfidence: baseline.boostedConfidence,
            floor: baseline.floor
        )

        return candidates.compactMap { candidate in
            // Structural validation: reject invalid area/group/serial combos.
            guard ssnValidator.isValid(candidate) else { return nil }

            // Context scoring: adjust confidence based on surrounding keywords.
            // Pass doctype + gazetteer + documentHeader.
            let confidence = contextScorer.score(
                text: fullText,
                matchRange: candidate.range,
                profile: profile,
                category: .ssn,
                doctype: doctype,
                gazetteer: gazetteer,
                documentHeader: documentHeader
            )

            var signals: [MatchRationale.Signal] = [
                .regexPattern(name: "ssn.state-machine"),
                .structuralValidator(name: "ssn.area-group-serial"),
            ]
            if let contextSignal = contextScorer.signal(
                text: fullText,
                matchRange: candidate.range,
                profile: profile,
                category: .ssn,
                doctype: doctype,
                gazetteer: gazetteer,
                documentHeader: documentHeader
            ) {
                signals.append(contextSignal)
            }
            // Attach negativeContextSuppressed signal when gazetteer fired.
            // Note: header-anchor suppression has no keyword to attach here;
            // it is reflected only in the final score.
            if let gaz = gazetteer, let dt = doctype,
               let suppSignal = contextScorer.gazetteerSignal(
                   text: fullText, matchRange: candidate.range,
                   category: .ssn, doctype: dt, gazetteer: gaz) {
                signals.append(suppSignal)
            }

            let rationale = MatchRationale(
                ruleID: "ssn.state-machine",
                signals: signals,
                preThresholdScore: profile.baseConfidence,
                finalScore: confidence
            )

            return PIIMatch(
                text: candidate.matchedText,
                range: candidate.range,
                kind: .ssn,
                confidence: confidence,
                rationale: rationale
            )
        }
    }
}
