import Foundation

// The regex safety gate every regex entry point shares, and the typed reasons it
// refuses a pattern with. Moved whole from DocumentSearcher.swift; no line inside a
// moved body changes.

extension DocumentSearcher {

    /// Validate a regex pattern for safety before execution.
    /// Returns the compiled regex or nil if the pattern is unsafe.
    /// Thin wrapper over `validateRegexPatternWithError` so the
    /// two entry points share one rule set and cannot drift.
    public static func validateRegexPattern(_ pattern: String) -> NSRegularExpression? {
        try? validateRegexPatternWithError(pattern)
    }

    /// Throwing variant that preserves WHY a
    /// pattern was rejected, so the sheet can surface the engine's
    /// `NSRegularExpression` NSError verbatim
    /// (`SearchToolbarSection+Contracts.swift` already promises it).
    /// `options` is the session's search options: the search legs pass
    /// theirs so the pattern compiles case-insensitively when Case-sensitive
    /// is off (`regexCompileOptions`); a validation-only caller passes none
    /// and the pattern compiles as written.
    ///
    /// Sync entry point gates ad-hoc trigger, compose
    /// sub-mode, custom-terms editor, and saved-regex compile via a
    /// single check. `RegexQuantifierScan` refuses the nested-quantifier
    /// shapes — an unbounded quantifier over a group that itself carries
    /// one (`(x+)+`, `(.*)*`, `(a{2,})*`), and bounded chains whose
    /// product of maxima exceeds `nestedBoundProductCap` — while a group
    /// closed by a bounded quantifier (`(-\d{4})?`, `(,\d{3})*`,
    /// `4111(\s?\d{4}){3}`) is never nesting. `RegexSafetyPrecheck`
    /// additionally rejects unbounded group-quantifiers over alternation
    /// (e.g. `(a|aa)*b`, `(ab|abc)*xyz`) that compile cleanly but
    /// backtrack catastrophically. The async `RegexSentinelCheck.validate`
    /// adds a sentinel-string runtime probe at compose-execution
    /// and profile-import time on top of this.
    public static func validateRegexPatternWithError(
        _ pattern: String, options: SearchOptions? = nil
    ) throws -> NSRegularExpression {
        // Pattern length cap
        guard pattern.count <= maxRegexPatternLength else {
            throw RegexValidationError.patternTooLong(maxLength: maxRegexPatternLength)
        }

        if RegexSafetyPrecheck.isLikelyPathological(pattern) {
            throw RegexValidationError.likelyPathological
        }

        // Nested quantifier rejection — the structural heuristic for
        // catastrophic backtracking, bounded-quantifier aware; an inner
        // unbounded run that a literal inside its group delimits is not
        // nesting (the sentinel probe's polynomial class, not this one's).
        if let violation = RegexQuantifierScan.violation(
            in: pattern,
            boundedCeiling: boundedQuantifierCeiling,
            productCap: nestedBoundProductCap,
            literalSeparatorDemotion: true
        ) {
            switch violation {
            case .nestedUnbounded:
                throw RegexValidationError.nestedQuantifiers
            case .nestedBoundProduct:
                throw RegexValidationError.nestedBoundProduct(cap: nestedBoundProductCap)
            }
        }

        // Attempt compilation; an engine rejection propagates as the
        // system NSError whose localizedDescription the sheet surfaces.
        // The page text is never case-folded on the regex path, so the
        // Case-sensitive option reaches the engine as a compile option.
        return try NSRegularExpression(pattern: pattern, options: regexCompileOptions(options))
    }

    /// The compile options the session's search options call for: the
    /// anchors match at every line (a user typing `^Total$` means the line,
    /// not the page) and, when Case-sensitive is off, the case-insensitive
    /// flag; the validation-only callers (no options) and a case-sensitive
    /// session compile with the line anchors alone.
    static func regexCompileOptions(_ options: SearchOptions?) -> NSRegularExpression.Options {
        guard let options, !options.caseSensitive else { return [.anchorsMatchLines] }
        return [.anchorsMatchLines, .caseInsensitive]
    }
}

// MARK: - Typed validation errors

/// Reasons `DocumentSearcher.validateRegexPatternWithError` rejects a
/// pattern before compilation. Engine-compile failures are NOT wrapped —
/// they propagate as the system `NSError` so its `localizedDescription`
/// reaches the regex error callout verbatim.
///
/// Copy constraint: these strings are app-owned user-facing copy and
/// use mechanism-description language ("has not been
/// accepted" — names the response, promises no outcome). The strings never
/// echo the submitted pattern text.
public enum RegexValidationError: Error, LocalizedError {
    case patternTooLong(maxLength: Int)
    case likelyPathological
    case nestedQuantifiers
    /// A chain of bounded repetitions whose combined count exceeds `cap`.
    case nestedBoundProduct(cap: Int)

    public var errorDescription: String? {
        switch self {
        case .patternTooLong(let max):
            return "Pattern exceeds the \(max)-character limit."
        case .likelyPathological:
            return "Pattern may cause performance issues and has not been accepted."
        case .nestedQuantifiers:
            return "Pattern contains nested quantifiers and has not been accepted."
        case .nestedBoundProduct(let cap):
            return "Pattern repeats a repeated group more than \(cap) times in total and has not been accepted."
        }
    }
}
