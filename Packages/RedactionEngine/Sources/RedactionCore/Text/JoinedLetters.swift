import Foundation

/// The seven joined-letter code points Unicode keeps for Latin text
/// (U+FB00 to U+FB06), each with the letters it stands for. A page may store
/// "office" with U+FB03 as one character; the hidden text writes the letters,
/// because the three fonts it is drawn in do not all have the joined forms.
package enum JoinedLetters {

    /// Each joined-letter code point and its letters, in order.
    package static let letters: [Unicode.Scalar: String] = [
        "\u{FB00}": "ff",
        "\u{FB01}": "fi",
        "\u{FB02}": "fl",
        "\u{FB03}": "ffi",
        "\u{FB04}": "ffl",
        "\u{FB05}": "st",
        "\u{FB06}": "st",
    ]

    /// The letters `scalar` stands for, or nil when it is not a joined letter.
    package static func letters(of scalar: Unicode.Scalar) -> String? {
        letters[scalar]
    }
}
