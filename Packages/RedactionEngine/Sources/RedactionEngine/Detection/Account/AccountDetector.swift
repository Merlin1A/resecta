import Foundation

// Plan §4 — financial/medical account-number detector. Context-only: the
// regex alone would fire on every long digit run, so base confidence is 0
// and only rises when an "account" token sits within ±5 tokens of the
// match. This is deliberately cautious — CC, SSN, EIN, MRN, DEA all have
// structured checksums or labels; Account is the "catch-all" for numbers
// users call accounts but that carry no intrinsic structure.

struct AccountDetector: Sendable {

    static let pattern = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])([A-Z]{0,3}\d{6,15})(?![A-Za-z0-9])"#
    )

    // Visibility widened private→internal (B02): the learned context-feature
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
        // D04-F4 — boosted RAW confidence dropped below the unstructured peers
        // it would otherwise suppress in resolveOverlaps. Raw arbitration runs
        // at DetectionOrchestrator.swift:386, BEFORE the posterior seam and the
        // preset gate. account is the lowest-priority generic kind
        // (priorityRank 1, DetectionOrchestrator+OverlapResolution.swift:180); a
        // bare 6–15 digit run next to "account" must not out-confidence address
        // (0.70) or phone (0.60/0.80). 0.58 < 0.60 keeps account losing every
        // contested overlap with an unstructured peer while still surviving as a
        // sole-hit group (a lone account match has no overlap rival to lose to).
        boostedConfidence: 0.58,
        floor: 0.0
    )

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
            // L-05: the 0.05 floor was vestigial — the scorer only emits ~0.0
            // (no keyword) or ~0.75 (boost), so the threshold only filtered
            // rare intermediate dampened values. The real per-preset gate is
            // applied downstream by PresetThresholdVector ("account"); this
            // guard's remaining role is to reject genuinely zero-signal hits.
            guard confidence > 0.0 else { return nil }
            var signals: [MatchRationale.Signal] = [.regexPattern(name: ruleID)]
            if let ctxSignal = scorer.signal(
                text: fullText,
                matchRange: match.range,
                profile: Self.profile,
                category: .account
            ) {
                signals.append(ctxSignal)
            }
            // WU-76 / [P4] — per-keyword breakdown alongside the scalar.
            if let ctxDetail = scorer.signalDetail(
                text: fullText,
                matchRange: match.range,
                profile: Self.profile
            ) {
                signals.append(ctxDetail)
            }
            let rationale = MatchRationale(
                ruleID: ruleID,
                signals: signals,
                preThresholdScore: Self.profile.baseConfidence,
                finalScore: confidence
            )
            return PIIDetector.PIIMatch(
                text: matchedText,
                range: match.range,
                kind: .account,
                confidence: confidence,
                rationale: rationale
            )
        }
    }
}
