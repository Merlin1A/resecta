import Foundation

// The forms of a name or number that Search does not try. Typed Search
// matches the text typed, under its folds (capitals, the Unicode and
// punctuation folds, and the options the person turns on), and nothing
// else. Each form below keeps one or more cases that Search misses with
// its default options, pinned by `SearchUntriedFormsTests`: a release
// that starts matching one of them changes this list in the same change.
// It holds no words a person reads; the sentence that names these forms
// is built from it where it is shown.

enum SearchUntriedForm: String, CaseIterable, Sendable {
    /// A surname or a first name on its own.
    case partOfAName
    /// Initials in place of a name.
    case initials
    /// A nickname in place of a name.
    case nickname
    /// A misspelling of a name.
    case misspelling
    /// A letter with an accent against the same letter without it, unless
    /// the Accents option is on.
    case accent
    /// The same name written another way: last name first, or an
    /// organisation's word in its short form.
    case nameWrittenAnotherWay
    /// The same number, date or amount written another way.
    case numberWrittenAnotherWay
}
