import Foundation

// The match skeleton of the OCR literal route. Vision reads a scanned "100"
// as "100", "1OO" or "IOO" depending on the glyphs, and a typed query is
// whatever the user typed; matching the two Character for Character misses
// every number or code whose digits look like letters. Inside a token (a run
// of letters and digits) that holds a digit, the skeleton maps each
// Character of a confusable class to the class's one symbol, on BOTH sides
// of an OCR literal match: the recognised text (after the literal
// preparation) and the typed query, each token read before the separator
// strip runs words together. A token of letters alone is left as
// it is, so a typed "ID" does not match the "ld" of "field". The classes are
// read from Scan's own
// confusable tables (`OCRTextNormalizer.digitContextMap` and
// `letterContextMap`), each letter with its lower case:
// {0 O o} · {1 I i l} · {5 S s} · {8 B b} · {2 Z z} · {6 G g}.
// Every member and symbol is a single-unit ASCII Character, so the skeleton
// keeps a text's Character count and UTF-16 length, and every offset map
// and raw-text map of the prepared page stays valid. The text layer never
// takes the skeleton: a typed "SOO" does not match a printed "500".
//
// Privacy rule (audit-lint M-1): locate/match/cover vocabulary.
enum OCRMatchSkeleton {

    /// Each confusable Character and the symbol of its class (the class's digit).
    static let symbols: [Character: Character] = {
        var symbols: [Character: Character] = [:]
        func add(_ letter: Character, _ digit: Character) {
            symbols[letter] = digit
            symbols[Character(letter.lowercased())] = digit
            symbols[digit] = digit
        }
        for (letter, digit) in OCRTextNormalizer.digitContextMap { add(letter, digit) }
        for (digit, letter) in OCRTextNormalizer.letterContextMap { add(letter, digit) }
        return symbols
    }()

    /// Per Character of `text`: whether it sits in a token (a run of letters
    /// and digits) that holds an ASCII digit.
    static func inDigitToken(_ text: [Character]) -> [Bool] {
        var flags = [Bool](repeating: false, count: text.count)
        var start = 0
        while start < text.count {
            guard text[start].isLetter || text[start].isNumber else { start += 1; continue }
            var end = start
            while end < text.count, text[end].isLetter || text[end].isNumber { end += 1 }
            if text[start..<end].contains(where: { $0.isASCII && $0.isNumber }) {
                for i in start..<end { flags[i] = true }
            }
            start = end
        }
        return flags
    }

    /// A normalized query (before the separator strip, which would run its
    /// tokens together) with every confusable Character of a token that
    /// holds a digit replaced by its class's symbol.
    static func skeleton(_ query: String) -> String {
        let characters = Array(query)
        let flags = inDigitToken(characters)
        return String(characters.indices.map { flags[$0] ? (symbols[characters[$0]] ?? characters[$0]) : characters[$0] })
    }

    /// A prepared page with its searched text skeletonised, the tokens read
    /// on its base text (before the separator strip); its maps are
    /// unchanged, since the skeleton keeps every Character and UTF-16 unit.
    static func skeleton(_ page: SearchCore.PreparedPage) -> SearchCore.PreparedPage {
        let flags = inDigitToken(page.baseChars ?? Array(page.baseText))
        let text = String(page.searchText.enumerated().map { index, character in
            let base = page.offsetMap?[index] ?? index
            return base < flags.count && flags[base] ? (symbols[character] ?? character) : character
        })
        return SearchCore.PreparedPage(
            searchText: text, nsString: text as NSString, baseText: page.baseText,
            offsetMap: page.offsetMap, baseChars: page.baseChars, rawMap: page.rawMap)
    }

    /// A typed query without its leading and trailing symbols (a currency
    /// or math sign Vision may read as a letter: "$1,000" → "1,000");
    /// punctuation stays, so "Hartwell," still asks for the comma. A query
    /// made only of symbols is kept as typed.
    static func trimmedQuery(_ query: String) -> String {
        let edges = CharacterSet.symbols.union(.whitespacesAndNewlines)
        let trimmed = query.trimmingCharacters(in: edges)
        return trimmed.isEmpty ? query : trimmed
    }

    /// The options of an OCR literal match: accents fold on both sides
    /// (Vision reads "Núñez" and "Nunez" alike often enough that the typed
    /// form decides nothing).
    static func options(_ options: SearchOptions) -> SearchOptions {
        var ocr = options
        ocr.foldDiacritics = true
        return ocr
    }
}
