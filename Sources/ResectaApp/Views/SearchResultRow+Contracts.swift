import SwiftUI
import RedactionEngine

// The pure display contracts of `SearchResultRow`: the confidence-bar
// tiers, the context-first row helpers and the rationale summary the
// `MatchRationaleSheet` footer reads. Other surfaces and the tests
// consume them as `SearchResultRow.` statics; the row's `body`, its
// press-highlight modifier and the equatable accessory wrappers stay in
// `SearchResultRow.swift`.

// MARK: - Confidence-Bar Contract

extension SearchResultRow {
    /// Three-tier classification driving the confidence-bar color.
    /// Reuses existing `ResectaTokens.SemanticColor.confidenceHigh/Medium/Low` —
    /// no new tokens introduced.
    /// `nonisolated`: under the SE-0466 MainActor-default flip this pure
    /// value type (no MainActor state) would otherwise become
    /// MainActor-isolated, which breaks `RegionMetadata`'s nonisolated
    /// init reading `.descriptor` off `absoluteConfidenceTier`'s
    /// result. Mirrors `ResectaTokens.SemanticColor`'s same-rationale pin.
    nonisolated enum ConfidenceTier: Equatable {
        case high
        case medium
        case low

        var color: Color {
            switch self {
            case .high: return ResectaTokens.SemanticColor.confidenceHigh
            case .medium: return ResectaTokens.SemanticColor.confidenceMedium
            case .low: return ResectaTokens.SemanticColor.confidenceLow
            }
        }

        /// Qualitative descriptor replacing the retired "N% confidence"
        /// copy. Lowercase, for mid-sentence / spoken use (e.g. "Social
        /// Security Number, high confidence").
        /// Thresholds live ONLY on `absoluteConfidenceTier` /
        /// `confidenceTier(for:ocrFloor:)` — this is a pure label over an
        /// already-computed tier, never a second threshold source.
        var descriptor: String {
            switch self {
            case .high: return "high confidence"
            case .medium: return "medium confidence"
            case .low: return "low confidence"
            }
        }

        /// Sentence-position form: first letter capitalized, for a
        /// standalone visible line (e.g. detection-row secondary text)
        /// or a sentence-final accessibility clause (e.g. "Page 2. High
        /// confidence.").
        var descriptorLabel: String {
            switch self {
            case .high: return "High confidence"
            case .medium: return "Medium confidence"
            case .low: return "Low confidence"
            }
        }
    }

    /// Within-floor band (15 percentage points) for OCR grading —
    /// confidence at or above `floor + bandwidth` is `.high`; within
    /// the band is `.medium`; below the floor is `.low`.
    static let confidenceBandwidth: Double = 0.15

    /// Shared absolute confidence bands for classifier findings —
    /// the same tiers the detection review rows use, so one confidence
    /// grammar covers both origins of the unified surface. ≥ 0.9 high,
    /// ≥ 0.7 medium, else low.
    /// `nonisolated`: under the SE-0466 MainActor-default flip this pure
    /// function would otherwise become MainActor-isolated, which breaks
    /// `RegionMetadata`'s nonisolated init, the one other non-View
    /// call site.
    nonisolated static func absoluteConfidenceTier(_ confidence: Double) -> ConfidenceTier {
        if confidence >= 0.9 { return .high }
        if confidence >= 0.7 { return .medium }
        return .low
    }

    /// Mode-meaningful confidence-bar grading. Branch order
    /// mirrors the source badge's precedence: Custom → PII → OCR → text.
    /// PII rows grade on the shared absolute bands: the former
    /// `piiThreshold` input read `minimumPIIConfidence`, which is
    /// schema-compat state no live control can change since the per-run
    /// Confidence slider retired — grading against it described a
    /// control that no longer exists. This two-parameter signature
    /// stays the public/test contract and delegates to the flag-taking
    /// canonical form.
    static func confidenceTier(
        for result: SearchResult,
        ocrFloor: Double
    ) -> ConfidenceTier {
        confidenceTier(
            for: result,
            ocrFloor: ocrFloor,
            isCustomHit: Self.isCustomTermHit(result)
        )
    }

    /// Canonical grading over the precomputed custom-hit flag, so the
    /// row build scans `rationale.signals` once for all three
    /// signal-derived display inputs.
    static func confidenceTier(
        for result: SearchResult,
        ocrFloor: Double,
        isCustomHit: Bool
    ) -> ConfidenceTier {
        if isCustomHit {
            return .high
        }
        if let piiConf = result.piiConfidence, result.piiCategory != nil {
            return absoluteConfidenceTier(piiConf)
        }
        if case .ocr(let confidence) = result.source {
            let conf = Double(confidence)
            if conf >= ocrFloor + Self.confidenceBandwidth { return .high }
            if conf >= ocrFloor { return .medium }
            return .low
        }
        // .textLayer + no piiCategory + not Custom → literal text/regex match.
        return .high
    }

    /// Text/regex/Custom rows surface the
    /// literal-match tooltip on the bar; PII/OCR rows return empty
    /// (their confidence is rendered inline on the source badge).
    /// SAFE — mechanism description, no outcome promise. Public/test
    /// contract signature; delegates to the flag-taking form.
    static func confidenceBarTooltip(for result: SearchResult) -> String {
        confidenceBarTooltip(for: result, isCustomHit: Self.isCustomTermHit(result))
    }

    /// Canonical tooltip over the precomputed custom-hit flag.
    static func confidenceBarTooltip(
        for result: SearchResult,
        isCustomHit: Bool
    ) -> String {
        if isCustomHit {
            return "Literal match — strength matches the input text."
        }
        if result.piiCategory == nil, result.source == .textLayer {
            return "Literal match — strength matches the input text."
        }
        return ""
    }

    /// Capsule label for OCR
    /// rows. The percent the user used to see here is encoded by the
    /// leading-edge confidence bar; VoiceOver still speaks the percent
    /// via the badge's accessibility label.
    static func ocrCapsuleLabel(confidence: Float) -> String {
        "OCR"
    }

    /// OCR source-badge accessibility label. Takes the row's
    /// already-computed floor-relative `tier` (not a raw confidence) so
    /// the spoken label matches what the leading-edge confidence bar
    /// shows, and so no percent threshold is duplicated here.
    static func ocrCapsuleAccessibilityLabel(tier: ConfidenceTier) -> String {
        "OCR, \(tier.descriptor)"
    }
}

// MARK: - Context-first row contracts

extension SearchResultRow {
    /// True where the tier is graded: PII rows (absolute bands) and
    /// OCR-source rows (floor-relative). Literal text / regex / custom
    /// text-layer hits grade `.high` by construction, so a spoken tier
    /// would be noise; their bar still renders the literal-match
    /// green. The meta line no longer renders a tier word, so this
    /// predicate gates ONLY the spoken tier in the merged a11y label
    /// (the bar's non-visual twin); the name is kept for the pins that
    /// reference it.
    nonisolated static func showsTierWord(for result: SearchResult) -> Bool {
        if result.piiConfidence != nil { return true }
        if case .ocr = result.source { return true }
        return false
    }

    /// The merged row element's spoken label — the shape "Address,
    /// page 1, medium confidence, applied": the category word where
    /// the row has one (a PII hit's category; a literal / regex /
    /// custom hit reads "Search match"), the page, the
    /// tier descriptor where the row is graded (spoken for parity with
    /// the bar, no longer mirrored by a visible word), and "applied"
    /// once the match is marked (the visual marker's non-visual twin).
    /// Never the matched text, never the window.
    static func accessibilityLabel(
        for result: SearchResult,
        tier: ConfidenceTier,
        showsTier: Bool,
        isApplied: Bool = false
    ) -> String {
        var parts = [Self.spokenCategory(for: result).map { "\($0), page \(result.pageIndex + 1)" }
                     ?? "Search match, page \(result.pageIndex + 1)"]
        if showsTier { parts.append(tier.descriptor) }
        if isApplied { parts.append("applied") }
        return parts.joined(separator: ", ")
    }

    /// The category word a row speaks in place of its text: the PII
    /// category's name ("Address", "SSN", …) for a PII hit; nil for a
    /// literal / regex / custom hit, whose adapter string stands.
    nonisolated static func spokenCategory(for result: SearchResult) -> String? {
        result.piiCategory?.rawValue
    }

    /// The per-row XCUI / VoiceOver identifier — stable across the
    /// list's re-sorts (the result's id, not its position).
    nonisolated static func accessibilityIdentifier(for result: SearchResult) -> String {
        "searchResultRow-\(result.id.uuidString)"
    }

    /// The collapsed window's line clamp: two lines through XXL, three
    /// from XXXL up (the same threshold the compact strip's counter
    /// uses) so a long match the lead-in pushes past line 2 at large
    /// type still shows whole while collapsed.
    nonisolated static func collapsedLineLimit(for size: DynamicTypeSize) -> Int {
        size >= .xxxLarge ? 3 : 2
    }

    /// Brand-teal wash opacity under the match run. Tuned on-sim in
    /// both appearances.
    nonisolated static let matchWashOpacity: Double = 0.16

    /// The row's one text block: the context window
    /// in proportional secondary text with the match run set
    /// semibold-monospaced in primary on the brand-teal wash. Mono stays
    /// the exclusive signature of detected content. `matchRange` is the
    /// engine's Character range inside `snippet`; nil (hand-built
    /// results) falls back to the first verbatim occurrence of
    /// `matchedText`; with no occurrence the plain base returns. Both
    /// runs use text styles so they scale together under Dynamic Type.
    nonisolated static func attributedSnippet(
        _ snippet: String,
        matchRange: Range<Int>?,
        matchedText: String
    ) -> AttributedString {
        var attributed = AttributedString(snippet)
        attributed.font = .footnote
        attributed.foregroundColor = .secondary
        guard let run = matchRun(in: attributed, matchRange: matchRange, matchedText: matchedText) else {
            return attributed
        }
        attributed[run].font = .footnote.monospaced().weight(.semibold)
        attributed[run].foregroundColor = .primary
        attributed[run].backgroundColor = ResectaTokens.BrandTeal.tint.opacity(matchWashOpacity)
        return attributed
    }

    /// The attributed range of the match run: the engine's Character
    /// range when it is in bounds, else the first verbatim occurrence.
    private nonisolated static func matchRun(
        in attributed: AttributedString,
        matchRange: Range<Int>?,
        matchedText: String
    ) -> Range<AttributedString.Index>? {
        let characters = attributed.characters
        if let matchRange,
           matchRange.lowerBound >= 0,
           !matchRange.isEmpty,
           matchRange.upperBound <= characters.count {
            let lower = characters.index(characters.startIndex, offsetBy: matchRange.lowerBound)
            let upper = characters.index(lower, offsetBy: matchRange.count)
            return lower..<upper
        }
        guard !matchedText.isEmpty else { return nil }
        return attributed.range(of: matchedText)
    }
}

// MARK: - Rationale Summary (the MatchRationaleSheet Signals footer)

extension SearchResultRow {
    /// Short mechanism-noun label per `MatchRationale.Signal` case.
    /// The labels feed `inlineRationaleSummaryString(for:)`'s `+`-joined
    /// summary. Each label is mechanism-only — describes
    /// what the detector matched, not what the user should do. Returns
    /// `nil` for cases that don't contribute to the summary (e.g.
    /// `userNeverFlag`, `suppressedByOverlap` are suppression signals,
    /// not match-strength evidence).
    static func signalShortLabel(for signal: MatchRationale.Signal) -> String? {
        switch signal {
        case .regexPattern:
            return "regex"
        case .structuralValidator:
            return "validator"
        case .contextPositive, .contextNegative:
            return "context"
        case .bloomSurnameHit, .bloomGivenHit, .bloomFuzzySurnameHit:
            return "name"
        case .doctypeGate:
            return "doctype"
        case .presetThresholdPass:
            return "threshold"
        case .ocrConfidence:
            return "ocr"
        case .userAlwaysFlag:
            return "custom"
        case .userNeverFlag, .suppressedByOverlap:
            return nil
        case .contextPositiveDetail, .contextNegativeDetail:
            // Fold the detail variants into the existing
            // "context" bucket so the inline summary stays a 1-word
            // mechanism noun. The detail keywords surface in the
            // expanded sheets (MatchRationaleSheet, RegionRationaleSheet)
            // not in this compact row summary.
            return "context"
        case .negativeContextSuppressed:
            // Gazetteer suppression
            // folds into the same "context" mechanism bucket; the
            // keyword + weight surface in the expanded sheets.
            return "context"
        }
    }

    /// One-line rationale summary. It renders as the Signals footer of
    /// `MatchRationaleSheet` (it used to sit in the row-expansion
    /// area). Format: `"Reason: <signals> (detector
    /// score <score>)."` —
    /// signals join with `+` (deduped, preserving first-encounter order),
    /// score formats to two decimal places. The number carries the
    /// "detector score" noun so it can't be misread as the row's match
    /// confidence — they are different quantities. The summary stays
    /// mechanism-only — never includes outcome verbs
    /// ("flagged", "redacted") or imperatives ("redact this"). The
    /// "Reason:" prefix is itself SAFE.
    static func inlineRationaleSummaryString(for rationale: MatchRationale) -> String {
        var labels: [String] = []
        var seen = Set<String>()
        for signal in rationale.signals {
            guard let label = signalShortLabel(for: signal) else { continue }
            guard !seen.contains(label) else { continue }
            labels.append(label)
            seen.insert(label)
        }
        let scoreString = String(format: "%.2f", rationale.finalScore)
        if labels.isEmpty {
            return "Reason: detector score \(scoreString)."
        }
        return "Reason: \(labels.joined(separator: "+")) (detector score \(scoreString))."
    }
}
