import Foundation

// The context the reverse-rationale sheet receives for a search row.
//
// Every engine producer path builds `contextSnippet` as a window around
// `matchedText`, so the primary rule is containment: the snippet IS the
// context. The fallback — the snippet followed by the match — exists for
// hand-built rows (fixtures, older callers) whose snippet was never a
// window; it must never be the path a producer takes, and the engine's
// own invariant suite pins that on every producer.

enum ReverseRationaleContext {

    /// `snippet` when it contains `matchedText` verbatim; otherwise the
    /// snippet followed by a space and the match, so the sheet's keyword
    /// highlight always has the match text to locate.
    static func make(snippet: String, matchedText: String) -> String {
        if snippet.contains(matchedText) { return snippet }
        return "\(snippet) \(matchedText)"
    }
}
