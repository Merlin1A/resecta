import Foundation

/// The text path's alphabet marks, part of its fifth step: the runs of the
/// filter's survivors the hidden text cannot write. A run is a word of the
/// page's one partition, its white space left out (a line's end is white
/// space). A run is marked when none of the three faces can write it, or it
/// holds a character the hidden text never holds (`HiddenTextFonts`).
enum TextPathAlphabetMarks {

    /// What the alphabet rule marks on one page.
    struct Marks: Equatable, Sendable {
        /// The marked words, by the page's one partition.
        var wordIndices: Set<Int>
        /// The runs left out: one for each marked run.
        var runsLeftOut: Int
        /// The reason the page is a picture when it ends with no word and the
        /// rule marked at least one; nil while the rule marks nothing.
        var reasonIfNoWordLeft: TextLayerDetector.FallbackReason?

        static let none = Marks(wordIndices: [], runsLeftOut: 0, reasonIfNoWordLeft: nil)
    }

    static func marks(_ survivors: [CharacterInfo]) -> Marks {
        var order: [Int] = []
        var runs: [Int: String] = [:]
        for entry in survivors where !SandwichMetrics.isLineageWhitespace(entry.character) {
            if runs[entry.wordIndex] == nil { order.append(entry.wordIndex) }
            runs[entry.wordIndex, default: ""] += entry.character
        }
        let marked = Set(order.filter { !HiddenTextFonts.canBeWritten(runs[$0] ?? "") })
        guard !marked.isEmpty else { return .none }
        return Marks(wordIndices: marked, runsLeftOut: marked.count, reasonIfNoWordLeft: .noWritableText)
    }
}
