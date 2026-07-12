import Foundation

/// A verifier sensitive term plus its matching discipline (PD-3).
///
/// `text` is the byte-search subject for Layers 3 and 10 (and the plain-text
/// subject for Layer 2's OCR gate, which reads `text` only).
///
/// `requiresTokenBoundary` narrows byte-level matching to complete tokens:
/// a hit counts only when the bytes adjacent to the match (the byte before
/// the match start and the byte after the match end) are non-alphanumeric
/// ASCII or absent (buffer start/end). Separators (0x1F), whitespace, and
/// punctuation all qualify as boundaries. Callers set this for terms whose
/// text is a single bare word likely to occur embedded inside unrelated
/// longer words (a lone given name or surname); multi-word spans, digit
/// strings, and typed queries keep plain substring matching so partial or
/// embedded leaks remain detectable.
public struct SensitiveTerm: Sendable, Equatable, Hashable {
    /// The term text to search for.
    public let text: String
    /// True when byte matches must be token-bounded on both sides.
    public let requiresTokenBoundary: Bool

    public init(text: String, requiresTokenBoundary: Bool = false) {
        self.text = text
        self.requiresTokenBoundary = requiresTokenBoundary
    }
}
