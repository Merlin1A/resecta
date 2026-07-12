import Foundation

// B02 — learned-context-scorer FEATURE BUILDER (additive; not yet wired).
//
// This file exposes the production `contextFeatures(...)` builder that the C1
// augment scorer will consume at the posterior seam
// (DetectionOrchestrator.swift:423-424). It is ADDITIVE in this PR: nothing in
// the live detection path calls it yet (B03 wires the seam at w=0). The B02
// measurement harness (@testable) calls it so the per-fire dump's features are
// LITERALLY what the seam will compute — closing the projection's count-only gap
// (plan 04 §5.4; one feature list, three consumers — §9).
//
// Contract (plan 04 §3.2, §9 — the single index authority):
//   13 features, returned as [Double] IN feature_order order (arity 13).
//   Features 1-2  : ±5-token presence window (reuses extractContextWindow
//                   semantics — radius 5, ±200-char cap; ContextWindowScorer.swift:292).
//   Features 3-4  : nearest-keyword distance over a ±200-char neighborhood,
//                   mapped 1/(1+gap/10).
//   Features 5-8  : structural signals from the match span.
//   Features 9-13 : one-hot of effectiveDoctype (court, medical, financial,
//                   foia, generic).
//
// Per-family keyword sets are the shipped KeywordProfile vocabularies read
// VERBATIM (AccountDetector.positiveKeywords; PIIDetector.phoneContextKeywords /
// phoneNegativeKeywords; MRNContextKeywords.profile; PIIDetector.einProfile /
// itinProfile) — no re-typed lists. A non-scored family yields empty sets, so
// features 1-4 are 0 for it (the builder is total over every kind, but only the
// five scored families have non-empty vocabularies).
//
// Pure (no I/O, no global state), deterministic. Internal visibility so both the
// B03 in-module seam and the @testable harness call the SAME code.
//
// Privacy (ARCH §12.2): the builder reads match.range + match.text + pageText to
// derive bounded numeric signals only; no document text, no PII value, and no
// coordinate ever leaves this function. The matched text is consumed solely to
// COUNT digits and test for a separator character.

/// The canonical 13-feature order (plan 04 §9). SINGLE index authority: the
/// File-5 dump, the Swift seam, and the Python trainer all key off this list.
enum ContextFeatureContract {
    static let featureOrder: [String] = [
        "kw_positive_window",
        "kw_negative_window",
        "nearest_positive_distance",
        "nearest_negative_distance",
        "digit_run_length",
        "has_separator",
        "left_is_label",
        "at_line_start",
        "doctype_is_court",
        "doctype_is_medical",
        "doctype_is_financial",
        "doctype_is_foia",
        "doctype_is_generic",
    ]

    /// The five families the scorer covers, keyed by `wireName(for:)`.
    static let scoredFamilies: Set<String> = ["account", "phone", "mrn", "ein", "itin"]
}

/// Per-family keyword vocabularies, sourced VERBATIM from the shipped detector
/// profiles. The builder selects the pair by the match's wire-name family.
/// Returns empty sets for any non-scored family (⇒ window features collapse to 0).
private enum ContextFeatureKeywords {
    /// (positive, negative) keyword sets for `family` (= wireName). Both
    /// lowercased for case-insensitive substring testing, mirroring the live
    /// scorer which lowercases the window before `contains` (ContextWindowScorer.swift:103/106).
    static func sets(for family: String) -> (positive: [String], negative: [String]) {
        switch family {
        case "account":
            // AccountDetector.positiveKeywords (negative set empty — profile :26).
            return (AccountDetector.positiveKeywords.map { $0.lowercased() }, [])
        case "phone":
            // PIIDetector phone keyword sets (PIIDetector.swift:871 / :880).
            return (
                PIIDetector.phoneContextKeywords.map { $0.lowercased() },
                PIIDetector.phoneNegativeKeywords.map { $0.lowercased() }
            )
        case "mrn":
            // MRNContextKeywords.profile (positive + negative; MRNContextKeywords.swift:16/31).
            let p = MRNContextKeywords.profile
            return (
                p.positiveKeywords.map { $0.lowercased() },
                p.negativeKeywords.map { $0.lowercased() }
            )
        case "ein":
            // PIIDetector.einProfile (negative set empty — profile :38).
            let p = PIIDetector.einProfile
            return (
                p.positiveKeywords.map { $0.lowercased() },
                p.negativeKeywords.map { $0.lowercased() }
            )
        case "itin":
            // PIIDetector.itinProfile (negative set empty — profile :53).
            let p = PIIDetector.itinProfile
            return (
                p.positiveKeywords.map { $0.lowercased() },
                p.negativeKeywords.map { $0.lowercased() }
            )
        default:
            return ([], [])
        }
    }
}

/// Compute the canonical 13-feature vector for one match, in feature_order order.
///
/// - Parameters:
///   - match: the detector hit (range + kind + confidence + text).
///   - doctype: the doctype the detector ran under (the gate doctype). Present
///     for signature parity with the seam; the feature one-hots use
///     `effectiveDoctype`.
///   - effectiveDoctype: the doctype whose one-hot is emitted (features 9-13).
///   - pageText: the full page text the match was located in.
/// - Returns: `[Double]` of length 13 (`ContextFeatureContract.featureOrder`).
func contextFeatures(
    match: PIIDetector.PIIMatch,
    doctype: DoctypeClass,
    effectiveDoctype: DoctypeClass,
    pageText: String
) -> [Double] {
    let nsText = pageText as NSString
    let family = PIICategory(piiKind: match.kind).flatMap { PresetThresholdVector.wireName(for: $0) } ?? ""
    let (positives, negatives) = ContextFeatureKeywords.sets(for: family)

    // Features 1-2: ±5-token presence window (radius 5, ±200-char cap),
    // lowercased, substring test — the exact live-scorer semantics.
    let window = Self_extractContextWindow(text: nsText, matchRange: match.range, radius: 5).lowercased()
    let kwPositiveWindow = positives.contains(where: { window.contains($0) }) ? 1.0 : 0.0
    let kwNegativeWindow = negatives.contains(where: { window.contains($0) }) ? 1.0 : 0.0

    // Features 3-4: nearest-keyword distance over the ±200-char neighborhood,
    // mapped 1/(1+gap/10); 0 when no keyword occurs in the neighborhood.
    let neighborhood = Self_neighborhood(text: nsText, matchRange: match.range, radius: 200)
    let nearestPositive = Self_nearestDistanceFeature(
        neighborhood: neighborhood, keywords: positives)
    let nearestNegative = Self_nearestDistanceFeature(
        neighborhood: neighborhood, keywords: negatives)

    // Feature 5: digit count of the matched text (a count, not the text).
    let digitRun = Double(match.text.reduce(into: 0) { acc, ch in
        if ch.isNumber { acc += 1 }
    })

    // Feature 6: 1 if the matched text contains a non-alphanumeric separator.
    let hasSeparator = match.text.contains(where: { !$0.isLetter && !$0.isNumber }) ? 1.0 : 0.0

    // Feature 7: 1 if the token immediately left of the match ends in ':' or '#'.
    let leftIsLabel = Self_leftTokenIsLabel(text: nsText, matchRange: match.range) ? 1.0 : 0.0

    // Feature 8: 1 if the match begins a line (only whitespace back to a newline
    // or to the document start).
    let atLineStart = Self_atLineStart(text: nsText, matchRange: match.range) ? 1.0 : 0.0

    // Features 9-13: one-hot of effectiveDoctype.
    let isCourt = effectiveDoctype == .court ? 1.0 : 0.0
    let isMedical = effectiveDoctype == .medical ? 1.0 : 0.0
    let isFinancial = effectiveDoctype == .financial ? 1.0 : 0.0
    let isFoia = effectiveDoctype == .foia ? 1.0 : 0.0
    let isGeneric = effectiveDoctype == .generic ? 1.0 : 0.0

    return [
        kwPositiveWindow,
        kwNegativeWindow,
        nearestPositive,
        nearestNegative,
        digitRun,
        hasSeparator,
        leftIsLabel,
        atLineStart,
        isCourt,
        isMedical,
        isFinancial,
        isFoia,
        isGeneric,
    ]
}

// MARK: - Window helpers (pure, deterministic)

/// ±radius-token window around the match, ±200-char capped.
/// Source: ContextWindowScorer.swift:292 (`extractContextWindow`, private there).
/// Replicated byte-for-byte so the seam and the B03 Swift↔Python parity test
/// share one windowing definition.
private func Self_extractContextWindow(text: NSString, matchRange: NSRange, radius: Int) -> String {
    // Text before the match (cap 200 chars back).
    let beforeStart = max(0, matchRange.location - 200)
    let beforeLength = matchRange.location - beforeStart
    let beforeText = text.substring(with: NSRange(location: beforeStart, length: beforeLength))
    let beforeTokens = beforeText.split(whereSeparator: { $0.isWhitespace })
    let relevantBefore = beforeTokens.suffix(radius).joined(separator: " ")

    // Text after the match (cap 200 chars forward).
    let afterStart = matchRange.location + matchRange.length
    let afterLength = min(200, text.length - afterStart)
    let afterText = text.substring(with: NSRange(location: afterStart, length: afterLength))
    let afterTokens = afterText.split(whereSeparator: { $0.isWhitespace })
    let relevantAfter = afterTokens.prefix(radius).joined(separator: " ")

    return relevantBefore + " " + relevantAfter
}

/// The ±radius-char left/right neighborhood, lowercased, with the char offset of
/// the match's left edge WITHIN the neighborhood string, so distances are
/// measured from the match edge to the nearest keyword occurrence.
private struct ContextNeighborhood {
    let lowered: String       // lowercased neighborhood text
    let matchStartInNbhd: Int // UTF-16 offset of the match's left edge in `lowered`
    let matchEndInNbhd: Int   // UTF-16 offset of the match's right edge in `lowered`
}

private func Self_neighborhood(text: NSString, matchRange: NSRange, radius: Int) -> ContextNeighborhood {
    let start = max(0, matchRange.location - radius)
    let end = min(text.length, matchRange.location + matchRange.length + radius)
    let nbhdRange = NSRange(location: start, length: end - start)
    let nbhd = text.substring(with: nbhdRange).lowercased()
    return ContextNeighborhood(
        lowered: nbhd,
        matchStartInNbhd: matchRange.location - start,
        matchEndInNbhd: matchRange.location + matchRange.length - start
    )
}

/// `1/(1+gap/10)` where gap = the smallest UTF-16 char distance from a match
/// edge to any occurrence of any keyword in the neighborhood; 0 when none occur.
/// Distance is 0 when an occurrence overlaps the match span itself.
private func Self_nearestDistanceFeature(
    neighborhood: ContextNeighborhood, keywords: [String]
) -> Double {
    guard !keywords.isEmpty else { return 0.0 }
    let hay = neighborhood.lowered as NSString
    let hayLen = hay.length
    var bestGap: Int? = nil
    for kw in keywords where !kw.isEmpty {
        var searchFrom = 0
        while searchFrom < hayLen {
            let r = hay.range(
                of: kw, options: [],
                range: NSRange(location: searchFrom, length: hayLen - searchFrom))
            if r.location == NSNotFound { break }
            let kwStart = r.location
            let kwEnd = r.location + r.length
            // Gap from the keyword span to the match span (0 if they overlap).
            let gap: Int
            if kwEnd <= neighborhood.matchStartInNbhd {
                gap = neighborhood.matchStartInNbhd - kwEnd
            } else if kwStart >= neighborhood.matchEndInNbhd {
                gap = kwStart - neighborhood.matchEndInNbhd
            } else {
                gap = 0
            }
            if bestGap == nil || gap < bestGap! { bestGap = gap }
            searchFrom = kwEnd > searchFrom ? kwEnd : searchFrom + 1
        }
    }
    guard let gap = bestGap else { return 0.0 }
    return 1.0 / (1.0 + Double(gap) / 10.0)
}

/// 1 if the non-whitespace token immediately left of the match ends in ':' or '#'.
private func Self_leftTokenIsLabel(text: NSString, matchRange: NSRange) -> Bool {
    let leftStart = max(0, matchRange.location - 200)
    let leftLen = matchRange.location - leftStart
    guard leftLen > 0 else { return false }
    let left = text.substring(with: NSRange(location: leftStart, length: leftLen))
    guard let lastToken = left.split(whereSeparator: { $0.isWhitespace }).last else { return false }
    return lastToken.hasSuffix(":") || lastToken.hasSuffix("#")
}

/// 1 if only whitespace (no other character) separates the match's left edge
/// from a newline or the document start.
private func Self_atLineStart(text: NSString, matchRange: NSRange) -> Bool {
    var i = matchRange.location - 1
    while i >= 0 {
        let scalarRange = NSRange(location: i, length: 1)
        let ch = text.substring(with: scalarRange)
        if ch == "\n" || ch == "\r" { return true }
        if let c = ch.unicodeScalars.first, CharacterSet.whitespaces.contains(c) {
            i -= 1
            continue
        }
        return false
    }
    // Reached the document start through whitespace only.
    return true
}
