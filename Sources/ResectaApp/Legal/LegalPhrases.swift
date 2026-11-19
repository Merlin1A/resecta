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
        // Length-claim stems: a box's width can still show how long the text
        // under it was, so no sentence may say a box hides or conceals it.
        // `Scripts/claims-lint.sh` also matches the paraphrases by pattern.
        "hide text length",
        "length hidden",
        "hidden length",
        "length is hidden",
        "hides the length",
        "hide the length",
        "hides its length",
        "hiding the length",
        "hides how long",
        "hide how long",
        "conceals the length",
        "conceal the length",
        "masks the length",
        "cannot show how long",
        "can't show how long",
        "no longer shows how long",
        "can no longer show",
        "width says nothing",
        "says nothing about the text",
        "no longer follows the text",
    ]

    /// Words matched only where they stand whole: no letter, digit or
    /// underscore may touch either end, so "proven" bans "proven" but not
    /// "provenance", and "anonymous" bans "anonymous" but not "anonymousness".
    /// Read by `Scripts/claims-lint.sh` for its sweep, case-insensitively.
    public static let wordEdgeTerms: [String] = [
        // Words that promise an outcome no tool can promise.
        "proven",
        "formally verified",
        "compliant",
        "court-ready",
        "de-identified",
        "deidentified",
        "anonymised",
        "anonymized",
        "anonymous",
        "anonymously",
        "hipaa",
        // Sentences that size what a box still shows.
        "only narrows",
        "a few bits",
        "safe from",
    ]
}
