import Foundation

/// The fold of a page's entries before the filter: a joined-letter code
/// point (U+FB00 to U+FB06) becomes one entry per letter, each with the
/// original entry's bounds, offset, line and word, as the walk already leaves
/// a joined glyph that reads as its letters; a break mark
/// (`TextNormalizer.breakMarks`) becomes nothing; and an entry that is only
/// the object mark U+FFFC, which the hidden text never holds
/// (`NeverWrittenCharacters`) and which is a break between runs rather than
/// part of one, becomes a space in its place, so the words on either side
/// stay two. A space is outside both count checks, and one entry is still
/// one letter, so neither the count's unit nor the lineage's changes.
enum JoinedLetterFold {

    /// `entries` with every joined-letter code point written as its letters,
    /// in order, and every break mark taken out. An entry that holds neither
    /// is kept as it is. In an entry that holds a joined-letter code point
    /// beside other characters, the characters before it and after it are
    /// entries of their own, in their place: "a\u{FB01}b" gives "a", "f",
    /// "i" and "b", and a combining mark after the joined letters is an entry
    /// of its own. An entry left with no character is dropped.
    static func fold(_ entries: [CharacterInfo]) -> [CharacterInfo] {
        var folded: [CharacterInfo] = []
        folded.reserveCapacity(entries.count)
        for entry in entries {
            let scalars = entry.character.unicodeScalars
            if !scalars.isEmpty, scalars.allSatisfy({
                $0 == NeverWrittenCharacters.objectMark && NeverWrittenCharacters.contains($0)
            }) {
                folded.append(CharacterInfo(
                    character: " ", bounds: entry.bounds,
                    stringIndex: entry.stringIndex, lineIndex: entry.lineIndex,
                    wordIndex: entry.wordIndex))
                continue
            }
            let hasJoined = scalars.contains(where: { JoinedLetters.letters(of: $0) != nil })
            let hasMark = scalars.contains(where: TextNormalizer.breakMarks.contains)
            guard hasJoined || hasMark else {
                folded.append(entry)
                continue
            }
            var rest = String.UnicodeScalarView()
            func keep(_ text: String) {
                folded.append(CharacterInfo(
                    character: text, bounds: entry.bounds,
                    stringIndex: entry.stringIndex, lineIndex: entry.lineIndex,
                    wordIndex: entry.wordIndex))
            }
            for scalar in scalars where !TextNormalizer.breakMarks.contains(scalar) {
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
