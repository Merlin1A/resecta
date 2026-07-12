import Foundation

// A6/A1: Generic context-window scorer for PII confidence adjustment.
// Reusable across categories — SSN keywords are one instance (SSNContextKeywords).
// Phase 3 categories will add their own KeywordProfile instances.

/// Configuration for a category-specific context scoring pass.
public struct KeywordProfile: Sendable {
    /// Keywords whose presence near a match INCREASE confidence.
    public let positiveKeywords: Set<String>
    /// Keywords whose presence near a match DECREASE confidence.
    public let negativeKeywords: Set<String>
    /// Number of whitespace-separated tokens on each side of the match to examine.
    public let windowRadius: Int
    /// Confidence when no context keywords are found.
    public let baseConfidence: Double
    /// Confidence when positive context keywords are found.
    public let boostedConfidence: Double
    /// Minimum confidence — negative context cannot suppress below this (A1 risk mitigation).
    public let floor: Double

    public init(
        positiveKeywords: Set<String>,
        negativeKeywords: Set<String>,
        windowRadius: Int = 5,
        baseConfidence: Double,
        boostedConfidence: Double,
        floor: Double
    ) {
        self.positiveKeywords = positiveKeywords
        self.negativeKeywords = negativeKeywords
        self.windowRadius = windowRadius
        self.baseConfidence = baseConfidence
        self.boostedConfidence = boostedConfidence
        self.floor = floor
    }
}

/// Scores PII match confidence based on surrounding text context.
/// Uses a ±N token window around the match, checking for positive and
/// negative keywords. Generic over category via KeywordProfile.
public struct ContextWindowScorer: Sendable {

    public init() {}

    // Pre-compiled date patterns for collision dampening.
    // Candidate inside a date span gets score floor 0.05.
    private static let datePatterns: [NSRegularExpression] = {
        [
            // MM/DD/YYYY or MM-DD-YYYY
            try! NSRegularExpression(pattern: #"\d{1,2}[/-]\d{1,2}[/-]\d{2,4}"#),
            // YYYY-MM-DD
            try! NSRegularExpression(pattern: #"\d{4}-\d{1,2}-\d{1,2}"#),
        ]
    }()

    /// Score a match's confidence based on surrounding context.
    ///
    /// Phase 1: the optional `category`/`doctype`/`gazetteer` trio enables
    /// per-(category, doctype) scoped suppression on top of the hardcoded
    /// KeywordProfile. When supplied, the gazetteer's `suppressionScore` is
    /// composed with the profile result as a multiplier, still honoring the
    /// `profile.floor` (A1 invariant: context cannot fully suppress a
    /// structurally valid match). When not supplied, the scorer behaves
    /// exactly as before for backward compatibility with existing SSN tests.
    ///
    /// S5 §2.7: when `documentHeader` is non-nil and the
    /// `gazetteer`/`category`/`doctype` trio is present, the
    /// `suppressionScore(documentHeader:)` overload is called instead of the
    /// 3-arg overload so the document-level institution anchor fires.
    ///
    /// - Parameters:
    ///   - text: The full page text.
    ///   - matchRange: The NSRange of the PII match within `text`.
    ///   - profile: The keyword profile for this category.
    ///   - category: Optional detector category (for gazetteer lookup).
    ///   - doctype: Optional document-type context (for scoped suppression).
    ///   - gazetteer: Optional per-(category, doctype) negative-context source.
    ///   - documentHeader: Optional first-page header prefix used for
    ///     institution-anchor suppression. When nil, the
    ///     3-arg `suppressionScore` path is used (no header anchor).
    /// - Returns: Adjusted confidence score in `[profile.floor, profile.boostedConfidence]`.
    public func score(
        text: String,
        matchRange: NSRange,
        profile: KeywordProfile,
        category: PIICategory? = nil,
        doctype: DoctypeClass? = nil,
        gazetteer: NegativeContextGazetteer? = nil,
        documentHeader: String? = nil
    ) -> Double {
        let nsText = text as NSString

        // Date-collision dampener: if the match is embedded in a date pattern,
        // return the floor or 0.05, whichever is lower (per A6 spec).
        if isInsideDatePattern(text: nsText, matchRange: matchRange) {
            return min(profile.floor, 0.05)
        }

        // Extract context window: ±windowRadius tokens around the match.
        let contextWindow = extractContextWindow(
            text: nsText, matchRange: matchRange, radius: profile.windowRadius
        ).lowercased()

        // Check for positive and negative keywords.
        let hasPositive = profile.positiveKeywords.contains { contextWindow.contains($0) }
        let hasNegative = profile.negativeKeywords.contains { contextWindow.contains($0) }

        let baseScore: Double
        if hasPositive {
            baseScore = profile.boostedConfidence
        } else if hasNegative {
            // Negative context dampens but cannot go below floor.
            // Penalty: halve the distance between base and floor.
            let penalty = (profile.baseConfidence - profile.floor) * 0.5
            baseScore = max(profile.floor, profile.baseConfidence - penalty)
        } else {
            baseScore = profile.baseConfidence
        }

        // Phase 1 / S5: layer scoped gazetteer suppression on top. The
        // gazetteer returns a factor in [0.25, 1.0] (1.0 = no suppression).
        // We floor the final score at profile.floor so the A1 invariant
        // survives.
        guard let gazetteer,
              let category,
              let doctype
        else {
            return baseScore
        }
        let suppression: Double
        if let header = documentHeader {
            // The document-header overload fires the institution-anchor
            // path. The header is NOT the per-match context
            // window — it is the document-level prefix that identifies the
            // issuing institution.
            suppression = gazetteer.suppressionScore(
                category: category,
                doctype: doctype,
                context: contextWindow,
                documentHeader: header
            )
        } else {
            suppression = gazetteer.suppressionScore(
                category: category,
                doctype: doctype,
                context: contextWindow
            )
        }
        return max(profile.floor, baseScore * suppression)
    }

    /// Classify the context band produced by `score(...)` as a
    /// `MatchRationale.Signal`. Detectors that emit context signals call this
    /// after reading the numeric confidence so the band-decision logic lives
    /// in one place. Returns nil for the neutral band.
    ///
    /// S5 §2.7: `documentHeader` is forwarded to `score(...)` so the band
    /// classification reflects any institution-anchor suppression that fired.
    /// Note: the header-anchor path has no associated keyword to attach to a
    /// `negativeContextSuppressed` signal — that signal is emitted separately
    /// by `gazetteerSignal(...)` which calls `suppressionDetail` (keyword-only
    /// API). Header-anchor suppression is intentionally not surfaced here.
    public func signal(
        text: String,
        matchRange: NSRange,
        profile: KeywordProfile,
        category: PIICategory? = nil,
        doctype: DoctypeClass? = nil,
        gazetteer: NegativeContextGazetteer? = nil,
        documentHeader: String? = nil
    ) -> MatchRationale.Signal? {
        let confidence = score(
            text: text,
            matchRange: matchRange,
            profile: profile,
            category: category,
            doctype: doctype,
            gazetteer: gazetteer,
            documentHeader: documentHeader
        )
        if confidence >= profile.boostedConfidence - 0.001 {
            return .contextPositive(score: confidence)
        } else if confidence < profile.baseConfidence - 0.001 {
            return .contextNegative(multiplier: confidence / profile.baseConfidence)
        }
        return nil
    }

    /// WU-76 / [P4] — per-keyword breakdown emitted alongside the scalar
    /// `signal(...)`. Returns the matched keywords from the profile's
    /// positive or negative sets (NEVER page-extracted text — RR-31
    /// closed-vocabulary invariant). Each contribution is an even share
    /// of the band-adjustment so consumers can render compact per-key
    /// summaries without re-running the scorer.
    ///
    /// Detectors append the result alongside the existing scalar:
    /// ```swift
    /// if let scalar = scorer.signal(...) { signals.append(scalar) }
    /// if let detail = scorer.signalDetail(...) { signals.append(detail) }
    /// ```
    public func signalDetail(
        text: String,
        matchRange: NSRange,
        profile: KeywordProfile
    ) -> MatchRationale.Signal? {
        let nsText = text as NSString
        // Mirror score()'s date-collision dampener: a date-embedded match
        // is suppressed wholesale; we don't emit a per-keyword breakdown
        // for it (no positive keywords could have contributed).
        if isInsideDatePattern(text: nsText, matchRange: matchRange) {
            return nil
        }
        let window = extractContextWindow(
            text: nsText, matchRange: matchRange, radius: profile.windowRadius
        ).lowercased()

        let matchedPositives = profile.positiveKeywords.filter { window.contains($0) }
        if !matchedPositives.isEmpty {
            let share = (profile.boostedConfidence - profile.baseConfidence) /
                        Double(matchedPositives.count)
            let contributions = matchedPositives.sorted().map {
                KeywordContribution(keywordKey: $0, contribution: share)
            }
            return .contextPositiveDetail(keywords: contributions)
        }

        let matchedNegatives = profile.negativeKeywords.filter { window.contains($0) }
        if !matchedNegatives.isEmpty {
            let penalty = (profile.baseConfidence - profile.floor) * 0.5
            let share = penalty / Double(matchedNegatives.count)
            let contributions = matchedNegatives.sorted().map {
                KeywordContribution(keywordKey: $0, contribution: share)
            }
            return .contextNegativeDetail(keywords: contributions)
        }

        return nil
    }

    /// S3 / WS2 §1.2 — returns a `negativeContextSuppressed` signal when the
    /// gazetteer actually fires, carrying the matched keyword and its weight.
    /// Detectors call this alongside `signal(...)` and append the result when
    /// non-nil. Uses `suppressionDetail` (internal API on the gazetteer) so
    /// the keyword scan runs only once per call site.
    ///
    /// Header-anchor path is deliberately NOT included here (deferred to S5).
    public func gazetteerSignal(
        text: String,
        matchRange: NSRange,
        category: PIICategory,
        doctype: DoctypeClass,
        gazetteer: NegativeContextGazetteer
    ) -> MatchRationale.Signal? {
        let nsText = text as NSString
        if isInsideDatePattern(text: nsText, matchRange: matchRange) { return nil }
        let contextWindow = extractContextWindow(
            text: nsText, matchRange: matchRange, radius: 5
        ).lowercased()
        let (factor, keyword, weight) = gazetteer.suppressionDetail(
            category: category, doctype: doctype, context: contextWindow)
        guard factor < 1.0, let kw = keyword, let wt = weight else { return nil }
        return .negativeContextSuppressed(keyword: kw, weight: wt)
    }

    // MARK: - Private Helpers

    /// Check if the match range is embedded within a date pattern.
    private func isInsideDatePattern(text: NSString, matchRange: NSRange) -> Bool {
        // Expand search area: ±20 characters around the match.
        let searchStart = max(0, matchRange.location - 20)
        let searchEnd = min(text.length, matchRange.location + matchRange.length + 20)
        let searchRange = NSRange(location: searchStart, length: searchEnd - searchStart)
        let searchText = text.substring(with: searchRange)

        let adjustedMatchStart = matchRange.location - searchStart
        let adjustedMatchRange = NSRange(location: adjustedMatchStart, length: matchRange.length)

        for pattern in Self.datePatterns {
            let matches = pattern.matches(in: searchText, range: NSRange(location: 0, length: (searchText as NSString).length))
            for dateMatch in matches {
                // Check if the date match fully contains the SSN candidate
                if NSIntersectionRange(dateMatch.range, adjustedMatchRange).length == adjustedMatchRange.length {
                    return true
                }
            }
        }
        return false
    }

    /// Extract text within ±radius whitespace-separated tokens of the match.
    private func extractContextWindow(text: NSString, matchRange: NSRange, radius: Int) -> String {
        // Get text before the match
        let beforeStart = max(0, matchRange.location - 200) // cap at 200 chars before
        let beforeLength = matchRange.location - beforeStart
        let beforeText = text.substring(with: NSRange(location: beforeStart, length: beforeLength))
        let beforeTokens = beforeText.split(whereSeparator: { $0.isWhitespace })
        let relevantBefore = beforeTokens.suffix(radius).joined(separator: " ")

        // Get text after the match
        let afterStart = matchRange.location + matchRange.length
        let afterLength = min(200, text.length - afterStart) // cap at 200 chars after
        let afterText = text.substring(with: NSRange(location: afterStart, length: afterLength))
        let afterTokens = afterText.split(whereSeparator: { $0.isWhitespace })
        let relevantAfter = afterTokens.prefix(radius).joined(separator: " ")

        return relevantBefore + " " + relevantAfter
    }
}
