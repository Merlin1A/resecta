import Foundation

/// The text path's fold, its third step: each entry's text before the
/// filter, by `JoinedLetterFold`: joined letters as their letters, break
/// marks taken out.
enum TextPathFold {
    static func fold(_ entries: [CharacterInfo]) -> [CharacterInfo] {
        JoinedLetterFold.fold(entries)
    }
}
