import CoreGraphics

// See ENGINE §5B for CharacterInfo definition.

/// A single character's identity and position in PDF page space.
/// Used by the text extraction, character filtering, and text layer
/// reconstruction pipeline (Searchable Redaction mode).
public struct CharacterInfo: Sendable {
    /// The Unicode character(s) — may be multi-codeunit for composed sequences.
    public let character: String
    /// Bounding box in PDF page coordinates (bottom-left origin, in points).
    public let bounds: CGRect
    /// UTF-16 offset into PDFPage.string.
    public let stringIndex: Int
    /// Ordinal of the character's source line: the count of synthesized
    /// line-separator offsets preceding it in `page.string` (PD-7). The
    /// partition is string-order, so it is invariant under page rotation.
    /// Callers that construct `CharacterInfo` without line information get
    /// a single shared line (index 0), under which the line-aware character
    /// filter reduces to its previous whole-page halo behavior.
    public let lineIndex: Int

    public init(character: String, bounds: CGRect, stringIndex: Int,
                lineIndex: Int = 0) {
        self.character = character
        self.bounds = bounds
        self.stringIndex = stringIndex
        self.lineIndex = lineIndex
    }
}
