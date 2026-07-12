import Foundation

// W3 — compiled representation of the user's custom keyword lists.
//
// Built once per scan kickoff from the `[UserTerm]` pair persisted in
// `SettingsState.customUserTerms`, then installed on `DocumentSearcher`
// via `setUserTerms(_:)` to drive two behaviors inside `.piiScan`:
//
// 1. Never-flag suppression — drop detector matches whose text equals a
//    literal never-flag term (Unicode-normalized, case-insensitive) or
//    is fully matched by a never-flag regex.
// 2. Always-flag emission — enumerate user-provided patterns in the
//    page text and emit synthetic `SearchResult`s alongside detector hits.
//
// Regex terms funnel through `DocumentSearcher.validateRegexPattern` so
// the existing 200-char + nested-quantifier ReDoS safeguards are the one
// source of truth. The per-page `ContinuousClock` bail-out from
// `searchRegex` is reused for always-flag enumeration.

/// A single user term ready for matching.
struct CompiledUserTerm: Sendable {
    /// Original user-authored pattern (for rationale reporting).
    let pattern: String
    /// Compiled regex, or nil for literal matching.
    let regex: NSRegularExpression?
    /// Pre-normalized literal text (nil when `regex` is set).
    /// Stored for fast reuse in the never-flag suppression path.
    let normalizedLiteral: String?
}

/// Per-page result of `alwaysFlagHits`. Carries the match list plus any
/// user-authored patterns whose enumeration bailed on the §S4 per-page
/// wall-clock budget so the call site can route a non-error per-term-
/// per-page skip signal (custom-terms timeout toast — REDACTION_ENGINE.md
/// §9.4). Order in `timedOutPatterns` matches enumeration order; the
/// outer loop's budget check breaks before any subsequent terms run, so
/// at most one entry per page is expected in practice.
struct AlwaysFlagPageResult {
    let hits: [(range: NSRange, pattern: String)]
    let timedOutPatterns: [String]
}

/// Ready-to-apply user-term matcher. Value type so copies across actor
/// boundaries are cheap; regex objects are thread-safe for read-only use.
public struct UserTermMatcher: Sendable {
    let alwaysFlag: [CompiledUserTerm]
    let neverFlag: [CompiledUserTerm]

    /// True when both lists are empty — the hot path can skip all work.
    public var isEmpty: Bool { alwaysFlag.isEmpty && neverFlag.isEmpty }

    /// Compile the two user-term lists. Invalid regex terms (pattern >
    /// 200 chars, nested quantifier, or uncompilable) are silently dropped
    /// — belt-and-suspenders given the UI validates on insertion; this
    /// also protects against blobs persisted before validator tightening.
    public static func compile(
        alwaysFlag: [UserTerm],
        neverFlag: [UserTerm]
    ) -> UserTermMatcher {
        UserTermMatcher(
            alwaysFlag: alwaysFlag.compactMap(compileOne),
            neverFlag: neverFlag.compactMap(compileOne)
        )
    }

    private static func compileOne(_ term: UserTerm) -> CompiledUserTerm? {
        guard !term.pattern.isEmpty else { return nil }
        if term.isRegex {
            guard let regex = DocumentSearcher.validateRegexPattern(term.pattern) else {
                return nil
            }
            return CompiledUserTerm(
                pattern: term.pattern,
                regex: regex,
                normalizedLiteral: nil
            )
        } else {
            return CompiledUserTerm(
                pattern: term.pattern,
                regex: nil,
                normalizedLiteral: TextNormalizer.normalizeForSearch(
                    term.pattern, caseSensitive: false
                )
            )
        }
    }

    /// W9 — mirror of `shouldSuppress(_:)` against the always-flag list.
    /// Returns the user-authored pattern that matches `matchedText`, or nil.
    /// Used by `PIIDetector.reverseRationale` to report why a snippet would
    /// be promoted to a match regardless of detector outcome.
    func matchesAlwaysFlag(_ matchedText: String) -> String? {
        guard !alwaysFlag.isEmpty else { return nil }

        let normalized = TextNormalizer.normalizeForSearch(
            matchedText, caseSensitive: false
        )

        for term in alwaysFlag {
            if let literal = term.normalizedLiteral {
                if literal == normalized { return term.pattern }
            } else if let regex = term.regex {
                let ns = matchedText as NSString
                let fullRange = NSRange(location: 0, length: ns.length)
                if let match = regex.firstMatch(
                    in: matchedText, range: fullRange
                ), match.range == fullRange {
                    return term.pattern
                }
            }
        }
        return nil
    }

    /// Check `matchedText` against every never-flag term. Returns the
    /// user-authored pattern that suppressed the match, or nil to keep.
    ///
    /// Literal terms use normalized + case-folded equality (symmetric with
    /// `findTextMatches`). Regex terms must match the entire `matchedText`
    /// — anchoring semantics are explicit so users can write a partial
    /// pattern without suppressing a superset. No per-call timeout: the
    /// input is a single match's text (bounded by detector output, never
    /// page-size), so regex.numberOfMatches over it is O(ms) at worst.
    func shouldSuppress(_ matchedText: String) -> String? {
        guard !neverFlag.isEmpty else { return nil }

        let normalized = TextNormalizer.normalizeForSearch(
            matchedText, caseSensitive: false
        )

        for term in neverFlag {
            if let literal = term.normalizedLiteral {
                if literal == normalized { return term.pattern }
            } else if let regex = term.regex {
                let ns = matchedText as NSString
                let fullRange = NSRange(location: 0, length: ns.length)
                if let match = regex.firstMatch(
                    in: matchedText, range: fullRange
                ), match.range == fullRange {
                    return term.pattern
                }
            }
        }
        return nil
    }

    /// Enumerate all always-flag occurrences in `pageText`, yielding their
    /// NSRange and originating pattern. Regex enumeration honours the same
    /// 5-second per-page bail-out as `searchRegex`; literal enumeration
    /// steps with `NSString.range(of:options:range:)` so it's bounded by
    /// page length.
    ///
    /// Literal patterns are case-insensitively matched via `.caseInsensitive`
    /// NSString options — we operate on the raw `pageText` (not normalized)
    /// so the returned NSRange maps cleanly back to PDFKit selection bounds
    /// via `DocumentSearcher.boundingRect(for:page:)`.
    ///
    /// Returns `AlwaysFlagPageResult.timedOutPatterns` populated with the
    /// user-authored patterns whose `enumerateMatches` bailed on the per-
    /// page budget. F-001 — `[.reportProgress]` lets the engine fire the
    /// closure between match attempts on long alternation walks, so the
    /// `Task.isCancelled` + `ContinuousClock` checks below sample inside
    /// a single `enumerateMatches` invocation. Catastrophic backtracking
    /// inside one match attempt still blocks the synchronous C call;
    /// `DocumentSearcher.validateRegexPattern` remains the primary defense.
    ///
    /// `timeoutOverride` mirrors `DocumentSearcher.regexTimeoutOverride`
    /// as a per-call test seam — production code passes nil (or omits the
    /// argument) and the static `DocumentSearcher.perPageRegexTimeout`
    /// applies. Per-instance avoids the cross-test race a global override
    /// would expose.
    func alwaysFlagHits(
        in pageText: String,
        timeoutOverride: Duration? = nil
    ) -> AlwaysFlagPageResult {
        guard !alwaysFlag.isEmpty else {
            return AlwaysFlagPageResult(hits: [], timedOutPatterns: [])
        }

        var hits: [(range: NSRange, pattern: String)] = []
        var timedOutPatterns: [String] = []
        let ns = pageText as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let startTime = ContinuousClock.now
        let timeout = timeoutOverride ?? DocumentSearcher.perPageRegexTimeout

        for term in alwaysFlag {
            if ContinuousClock.now - startTime > timeout { break }
            if Task.isCancelled { break }

            if let regex = term.regex {
                var thisTermTimedOut = false
                regex.enumerateMatches(
                    in: pageText,
                    options: [.reportProgress],
                    range: fullRange
                ) { match, _, stop in
                    if Task.isCancelled {
                        stop.pointee = true
                        return
                    }
                    if ContinuousClock.now - startTime > timeout {
                        thisTermTimedOut = true
                        stop.pointee = true
                        return
                    }
                    guard let match, match.range.location != NSNotFound else { return }
                    hits.append((range: match.range, pattern: term.pattern))
                }
                if thisTermTimedOut {
                    timedOutPatterns.append(term.pattern)
                }
            } else {
                var searchRange = fullRange
                while searchRange.length > 0 {
                    let found = ns.range(
                        of: term.pattern,
                        options: .caseInsensitive,
                        range: searchRange
                    )
                    if found.location == NSNotFound { break }
                    hits.append((range: found, pattern: term.pattern))
                    let advanceTo = found.location + max(1, found.length)
                    if advanceTo >= fullRange.length { break }
                    searchRange = NSRange(
                        location: advanceTo,
                        length: fullRange.length - advanceTo
                    )
                }
            }
        }
        return AlwaysFlagPageResult(hits: hits, timedOutPatterns: timedOutPatterns)
    }
}
