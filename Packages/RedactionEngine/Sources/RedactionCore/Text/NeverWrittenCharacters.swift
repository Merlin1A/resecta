import Foundation

/// The characters the hidden text never holds, whatever the fonts can draw:
/// the object mark U+FFFC (which is also a break between runs), the
/// replacement character U+FFFD, the direction controls, the other controls,
/// the private-use planes, and every character of a right-to-left script.
/// A run holding one of them, other than U+FFFC, is left out whole.
package enum NeverWrittenCharacters {

    /// The object mark: never written, and a break between runs, not a run.
    package static let objectMark: Unicode.Scalar = "\u{FFFC}"

    /// The ranges of scalar values, each named in its comment.
    package static let ranges: [ClosedRange<UInt32>] = [
        0xFFFC...0xFFFC, // the object mark
        0xFFFD...0xFFFD, // the replacement character
        0x0000...0x001F, // the controls below the space
        0x007F...0x009F, // delete and the controls after it, to U+009F
        0x061C...0x061C, // the Arabic letter mark
        0x200E...0x200F, // the left-to-right and right-to-left marks
        0x202A...0x202E, // the embeddings, overrides and their pop
        0x2066...0x2069, // the isolates and their pop
        0xE000...0xF8FF, // the private-use area
        0xF0000...0xFFFFD, // supplementary private-use area A
        0x100000...0x10FFFD, // supplementary private-use area B
        // Right-to-left scripts: Hebrew, Arabic, Syriac, Arabic Supplement,
        // Thaana, NKo, Samaritan, Mandaic, Syriac Supplement and Arabic
        // Extended-B and -A, which Unicode places together.
        0x0590...0x08FF, // the right-to-left scripts of U+0590 to U+08FF
        0xFB1D...0xFB4F, // the Hebrew presentation forms
        0xFB50...0xFDFF, // the Arabic presentation forms A
        // U+FEFF, the last code point of the block, is not an Arabic form.
        0xFE70...0xFEFE, // the Arabic presentation forms B
        0x10800...0x10FFF, // the right-to-left scripts of U+10800 to U+10FFF
        0x1E800...0x1EFFF, // the right-to-left scripts of U+1E800 to U+1EFFF
    ]

    /// Whether the hidden text never holds `scalar`.
    package static func contains(_ scalar: Unicode.Scalar) -> Bool {
        ranges.contains { $0.contains(scalar.value) }
    }
}
