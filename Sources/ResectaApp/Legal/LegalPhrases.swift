import Foundation

// Banned outcome-promise vocabulary. Every user-facing
// string in `Legal.xcstrings` (all locales) must be mechanism-description
// language, not outcome-promise. `LegalPhraseLintTests` walks the xcstrings
// catalog and fails if any localized value contains a banned term.
//
// The list below is maintained directly. Additions here are
// additive — a new banned term immediately tightens the lint.

public enum LegalPhrases {

    /// Case-insensitive substrings that must not appear in any user-facing
    /// string. Rationale: these create express warranties under the
    /// Consolidated Data Terminals / Castrol analysis.
    public static let bannedTerms: [String] = [
        // Express-warranty phrases.
        "structurally impossible",
        "the only provably secure approach",
        "destroy-level sanitization per nist",
        "mathematically irreversible",
        "security invariant",
        "provably reliable",
        // Outcome-promise vocabulary.
        "guaranteed",
        "ensures",
        "securely removes",
        "100%",
        "impossible to recover",
        "military-grade",
        "bank-level",
        "certified",
    ]
}
