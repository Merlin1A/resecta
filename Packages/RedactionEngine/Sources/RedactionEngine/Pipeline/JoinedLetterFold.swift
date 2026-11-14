import Foundation

/// The fold of a page's entries before the hidden text is laid out: a
/// joined-letter code point (U+FB00 to U+FB06) becomes one entry per letter,
/// each with the original entry's bounds, offset and line, as the walk
/// already leaves a joined glyph that reads as its letters. One entry is
/// still one letter, so neither the count's unit nor the lineage's changes.
enum JoinedLetterFold {

    /// `entries` with every joined-letter code point written as its letters,
    /// in order. An entry that holds no joined-letter code point is kept as
    /// it is. In an entry that holds one beside other characters, the other
    /// characters stay together as one entry, in their place.
    static func fold(_ entries: [CharacterInfo]) -> [CharacterInfo] {
        var folded: [CharacterInfo] = []
        folded.reserveCapacity(entries.count)
        for entry in entries {
            let scalars = entry.character.unicodeScalars
            guard scalars.contains(where: { JoinedLetters.letters(of: $0) != nil }) else {
                folded.append(entry)
                continue
            }
            var rest = String.UnicodeScalarView()
            func keep(_ text: String) {
                folded.append(CharacterInfo(
                    character: text, bounds: entry.bounds,
                    stringIndex: entry.stringIndex, lineIndex: entry.lineIndex))
            }
            for scalar in scalars {
                guard let letters = JoinedLetters.letters(of: scalar) else {
                    rest.append(scalar)
                    continue
                }
                if !rest.isEmpty { keep(String(rest)); rest = String.UnicodeScalarView() }
                for letter in letters { keep(String(letter)) }
            }
            if !rest.isEmpty { keep(String(rest)) }
        }
        return folded
    }
}
