/// The characters of a page that a box selects, as UTF-16 offsets of the
/// page's string. A Search match selects its own characters only: "Roe"
/// matched in "Roe." selects three characters, and the full stop stays a
/// character of the page that is not selected. Selection by whole word takes
/// every letter of each word a range touches, by the page's one partition.
package struct WordSelection: Hashable, Sendable {
    /// The selected offsets. White space is never selected.
    package private(set) var offsets: Set<Int>

    private init(offsets: Set<Int>) { self.offsets = offsets }

    /// The characters of `ranges` in `text`, white space left out. Offsets
    /// outside the string are left out.
    package static func characters(_ ranges: [Range<Int>], in text: String) -> WordSelection {
        let units = Array(text.utf16)
        var offsets: Set<Int> = []
        for range in ranges {
            for offset in range.clamped(to: 0..<units.count) where !WordPartition.isWhiteSpace(units[offset]) {
                offsets.insert(offset)
            }
        }
        return WordSelection(offsets: offsets)
    }

    /// Every letter of each word that a range touches with a letter of its
    /// own (a range of white space alone selects nothing).
    package static func wholeWords(_ ranges: [Range<Int>], in text: String) -> WordSelection {
        let units = Array(text.utf16)
        let indices = WordPartition.wordIndices(utf16: units)
        let touched = characters(ranges, in: text).offsets
        let words = Set(touched.map { indices[$0] })
        var offsets: Set<Int> = []
        for (offset, unit) in units.enumerated() where words.contains(indices[offset]) && !WordPartition.isWhiteSpace(unit) {
            offsets.insert(offset)
        }
        return WordSelection(offsets: offsets)
    }

    /// Whether the offset is selected.
    package func contains(_ offset: Int) -> Bool { offsets.contains(offset) }
}
