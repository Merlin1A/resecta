import Foundation

// The kinds of line Widen Boxes was measured on, and the one sentence that
// names those on which it reduced what the page shows about how long the
// text was. The sentence is shown only for kinds that earned the word in
// the measurement; which kinds earned it is decided where the caller's list
// is written, not here. This file turns a list of kinds into words: the
// names in their fixed order, joined by the one joining rule.

enum MeasuredLineKinds {

    /// A kind of line, in the fixed order its name is shown in.
    enum Kind: CaseIterable {
        case leftAlignedParagraph
        case justifiedParagraph
        case startsWithLabel
        case tableCells
    }

    /// The name that fills the sentence's slot, for each kind.
    static func name(_ kind: Kind) -> String {
        switch kind {
        case .leftAlignedParagraph: "lines of a left-aligned paragraph"
        case .justifiedParagraph: "lines of a justified paragraph"
        case .startsWithLabel: "lines that start with a label"
        case .tableCells: "lines in table cells"
        }
    }

    /// Names joined for a sentence: one name alone; two with "and"; three or
    /// more with a comma between each and a comma before the "and".
    static func joined(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        case 2: "\(names[0]) and \(names[1])"
        default: names.dropLast().joined(separator: ", ") + ", and " + names[names.count - 1]
        }
    }

    /// The sentence for the kinds that earned the word, named in the fixed
    /// order whatever order they are given in; nil when there are none, and
    /// the sentence is then not shown.
    static func sentence(for kinds: some Sequence<Kind>) -> String? {
        let earned = Set(kinds)
        let names = Kind.allCases.filter(earned.contains).map(name)
        guard !names.isEmpty else { return nil }
        return "In Resecta's test, Widen Boxes reduced what the page shows about how long the text was on "
            + joined(names) + "."
    }
}
