/// The page's one word partition: every UTF-16 offset of the page's string
/// is given a word index, and a word is the offsets that share one. The
/// index ticks at every white-space offset, so it depends on the string
/// alone: an offset the text walk skips (no selection, a box of no size)
/// still ticks, and no box or reading of the page can move a word's edges.
///
/// A white-space offset takes the new index, so it belongs to the word after
/// it; it is never one of that word's letters. A run of white space ticks
/// once for each of its offsets.
package enum WordPartition {
    /// The white-space code units: Unicode's White_Space property, written
    /// out so every system reads the same set whatever its own tables say.
    /// All lie in the Basic Multilingual Plane, so a code unit is white space
    /// exactly when its value is listed; a surrogate never is.
    package static let whiteSpaceUnits: Set<UInt16> = [
        0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x0020, 0x0085, 0x00A0, 0x1680,
        0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A,
        0x2028, 0x2029, 0x202F, 0x205F, 0x3000,
    ]

    /// Whether the code unit is white space.
    package static func isWhiteSpace(_ unit: UInt16) -> Bool { whiteSpaceUnits.contains(unit) }

    /// One word index for each UTF-16 code unit, in order. The first index
    /// is 0; it ticks by one at each white-space unit, which takes the new
    /// index.
    package static func wordIndices(utf16 units: some Sequence<UInt16>) -> [Int] {
        var index = 0
        var indices: [Int] = []
        indices.reserveCapacity(units.underestimatedCount)
        for unit in units {
            if isWhiteSpace(unit) { index += 1 }
            indices.append(index)
        }
        return indices
    }

    /// `wordIndices(utf16:)` over the string's UTF-16 code units: the
    /// offsets PDFKit and the text walk use.
    package static func wordIndices(of text: String) -> [Int] { wordIndices(utf16: text.utf16) }

    /// Each word's letters: for every word index that has a letter, the
    /// offsets of that word that are not white space, in order. A word of
    /// white space alone is left out.
    package static func words(of text: String) -> [[Int]] {
        var words: [[Int]] = []
        var current: [Int] = []
        for (offset, unit) in text.utf16.enumerated() {
            if isWhiteSpace(unit) {
                if !current.isEmpty { words.append(current) }
                current = []
            } else {
                current.append(offset)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}
