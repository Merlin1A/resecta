import Foundation

// The words of the Redaction Boxes section in Settings: its header, the
// switch's name and spoken hint, and its footer. The footer is one function,
// so a second screen that shows the same two paragraphs reads them from here.
enum RedactionBoxesCopy {
    static let sectionHeader = "Redaction Boxes"

    /// The switch's name. The sentences below and the measured sentence use it.
    static let switchName = "Cover Other Words"

    static let switchHint = "Where it can, runs boxes out along their lines, stopping short of words in another column, cell, or field. Can cover the other words there."

    /// The footer's first paragraph: what a box's width can show.
    static let widthParagraph = "A box removes the text under it, but its width can still show how long that text was. That can be enough to tell which name or month it was, or how many digits an amount has."

    /// The kinds of line the measured sentence names. Empty until the
    /// measured list is committed, so that sentence does not show.
    static let measuredKinds: [MeasuredLineKinds.Kind] = []

    /// The footer's second paragraph: what the switch does and what it
    /// leaves. The measured sentence is there only for a list of kinds.
    static func switchParagraph(measured kinds: [MeasuredLineKinds.Kind] = measuredKinds) -> String {
        [
            "Where it can, \(switchName) runs a box across every line it touches, out to where the lines above and below reach, and stops short of words that belong to another column, cell, or field.",
            "It can cover the other words there too, and that is its cost.",
            "It leaves a box as it is over a scan or a picture, on a page with text with no ink of its own, or on a page that is half or more a picture. It also leaves a box as it is over print that does not run upright and left to right, where there is too little unselected text above and below it to show its column, and where you drew, moved, or resized the box by hand.",
            MeasuredLineKinds.sentence(for: kinds),
            "A widened box can still show about how long its text was: in a paragraph, by where the lines break, and more closely each time the same text appears.",
        ].compactMap { $0 }.joined(separator: " ")
    }

    /// The section's footer: the two paragraphs.
    static func footer(measured kinds: [MeasuredLineKinds.Kind] = measuredKinds) -> String {
        widthParagraph + "\n\n" + switchParagraph(measured: kinds)
    }
}
