import CoreText
import Foundation

/// The hidden text's laid-out line: a line's text at a size, as the writer
/// draws it and the drawn-cell rule measures it, or nil when a run of it is
/// in a face outside the ones the hidden text may use. A slot the alphabet's
/// second part fills; until then every line is Courier, as the writer has
/// always drawn it, and none is nil. Where it gives nil before the record
/// the page is a picture; at write time the page's hidden text is not
/// written.
enum HiddenTextLine {
    static func layout(_ text: String, size: CGFloat) -> CTLine? {
        let font = CTFontCreateWithName("Courier" as CFString, size, nil)
        return CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font]))
    }
}
