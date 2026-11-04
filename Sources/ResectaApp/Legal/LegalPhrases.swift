import Foundation

// Banned outcome-promise vocabulary. Every user-facing
// string in `Legal.xcstrings` (all locales) must be mechanism-description
// language, not outcome-promise. `LegalPhraseLintTests` walks the xcstrings
// catalog and fails if any localized value contains a banned term.
//
// The list below is maintained directly and is the one home of the banned
// vocabulary: `Scripts/claims-lint.sh` reads these literals for its sweep of
// the shipping documents and the Swift string literals. A term is a
// case-insensitive substring, so a stem bans each of its inflections.
// Additions here are additive — a new banned term immediately tightens both.

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
        "guarantee", // LegalPhrases:safe — the stem: guarantee, guarantees, guaranteed
        "ensures",
        "securely removes",
        "100%",
        "impossible to recover",
        "military-grade",
        "bank-level",
        "certified",
    ]
}
