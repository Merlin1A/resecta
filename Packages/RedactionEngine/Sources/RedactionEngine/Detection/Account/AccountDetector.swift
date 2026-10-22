import Foundation

// Financial/medical account-number detector. Context-only: the
// regex alone would fire on every long digit run, so base confidence is 0
// and only rises when an "account" token sits within ±5 tokens of the
// match. This is deliberately cautious — CC, SSN, EIN, MRN, DEA all have
// structured checksums or labels; Account is the "catch-all" for numbers
// users call accounts but that carry no intrinsic structure.

struct AccountDetector: FamilyDetector {

    let category: PIICategory = .account
    let telemetryLabel = "account"

    static let pattern = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])([A-Z]{0,3}\d{6,15})(?![A-Za-z0-9])"#
    )

    // Visibility widened private→internal: the learned context-feature
    // builder (ContextFeatures.swift) reads this shipped keyword set verbatim
    // so the scorer's kw_positive_window feature reuses the live vocabulary
    // rather than a re-typed copy. Read-only; no behavior change.
    static let positiveKeywords: Set<String> = [
        "account", "account number", "account #", "acct", "acct #", "acct.", "a/c"
    ]

    private static let profile = KeywordProfile(
        positiveKeywords: positiveKeywords,
        negativeKeywords: [],
        windowRadius: 5,
        baseConfidence: 0.0,      // strict: no signal without context
        // The boosted RAW confidence sits exactly on the posterior floor's
        // keyword-confirmed bar (ContextPosteriorFloor.keywordConfirmedRaw), so
        // a keyword-confirmed account the learned context term collapses is
        // re-floored to the conservative cutoff and clears the balanced preset.
        // Below the bar (0.58 before) the floor never fired and no real
        // account survived at balanced. Account stays the lowest-priority
        // generic kind in overlap resolution (priorityRank 1): at an equal raw
        // the rank decides against it, and the G8 trial at this raw moved no
        // other family.
        boostedConfidence: 0.70,
        floor: 0.0
    )

    /// The raw a keyword-confirmed account carries — the tests that compose
    /// the posterior floor read it here instead of hand-feeding a number.
    static var keywordConfirmedConfidence: Double { profile.boostedConfidence }

    private let scorer = ContextWindowScorer()

    func detect(in text: NSString, range: NSRange) -> [PIIDetector.PIIMatch] {
        let fullText = text as String
        let ruleID = "account.regex"
        return Self.pattern.matches(in: fullText, range: range).compactMap { match in
            let matchedText = text.substring(with: match.range)
            let confidence = scorer.score(
                text: fullText,
                matchRange: match.range,
                profile: Self.profile,
                category: .account
            )
            // The 0.05 floor was vestigial — the scorer only emits ~0.0
            // (no keyword) or ~0.75 (boost), so the threshold only filtered
            // rare intermediate dampened values. The real per-preset gate is
            // applied downstream by PresetThresholdVector ("account"); this
            // guard's remaining role is to reject genuinely zero-signal hits.
            guard confidence > 0.0 else { return nil }
            return PIIDetector.PIIMatch(
                text: matchedText,
                range: match.range,
                kind: .account,
                confidence: confidence,
                rationale: .contextScored(
                    ruleID: ruleID, preThresholdScore: Self.profile.baseConfidence,
                    contextSignal: scorer.signal(
                        text: fullText, matchRange: match.range,
                        profile: Self.profile, category: .account
                    ),
                    // Per-keyword breakdown alongside the scalar.
                    keywordDetail: scorer.signalDetail(
                        text: fullText, matchRange: match.range, profile: Self.profile
                    ),
                    finalScore: confidence
                )
            )
        }
    }

    // MARK: - Family

    /// Account: financial + medical + court + generic. nil doctype → run.
    /// Court and generic doctypes were added to close the
    /// account-recall doctype gap — bank/loan account numbers recur in court
    /// filings (garnishment, financial affidavits) and untyped uploads. The
    /// account context window (AccountDetector requires a label near the digit
    /// run) carries the false-positive load on these broader doctypes; the gate
    /// only governs whether the detector runs at all. `.foia` stays held.
    func runs(doctype: DoctypeClass?) -> Bool {
        guard let doctype else { return true }
        return doctype == .financial || doctype == .medical
            || doctype == .court || doctype == .generic
    }

    func detect(in context: DetectionContext) -> [PIIDetector.PIIMatch] {
        detect(in: context.nsText, range: context.range)
    }
}
