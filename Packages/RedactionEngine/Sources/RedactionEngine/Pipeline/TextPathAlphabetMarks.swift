import Foundation

/// The text path's alphabet marks, part of its fifth step: the words of the
/// filter's survivors the hidden text cannot write. A slot the alphabet's
/// second part fills; until then it marks nothing.
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
        .none
    }
}
