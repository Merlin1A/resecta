import CoreGraphics
import Testing
@testable import RedactionEngine

@Suite("The fold of joined letters")
struct JoinedLetterFoldTests {

    static let box = CGRect(x: 72, y: 700, width: 14, height: 18)

    static func entry(_ text: String, _ offset: Int, line: Int = 0) -> CharacterInfo {
        CharacterInfo(character: text, bounds: box, stringIndex: offset, lineIndex: line)
    }

    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let code: String
        let letters: [String]
        var testDescription: String { name }
    }

    static let seven: [Case] = [
        Case(name: "ff", code: "\u{FB00}", letters: ["f", "f"]),
        Case(name: "fi", code: "\u{FB01}", letters: ["f", "i"]),
        Case(name: "fl", code: "\u{FB02}", letters: ["f", "l"]),
        Case(name: "ffi", code: "\u{FB03}", letters: ["f", "f", "i"]),
        Case(name: "ffl", code: "\u{FB04}", letters: ["f", "f", "l"]),
        Case(name: "long s and t", code: "\u{FB05}", letters: ["s", "t"]),
        Case(name: "st", code: "\u{FB06}", letters: ["s", "t"]),
    ]

    @Test("The seven cases are seven")
    func sevenLength() {
        #expect(Self.seven.count == 7)
    }

    @Test("A joined-letter code point becomes one entry per letter, each with its bounds, offset and line",
          arguments: seven)
    func joinedLetter(_ c: Case) {
        let folded = JoinedLetterFold.fold([Self.entry(c.code, 5, line: 2)])
        #expect(folded.map(\.character) == c.letters)
        #expect(folded.allSatisfy { $0.bounds == Self.box && $0.stringIndex == 5 && $0.lineIndex == 2 })
    }

    @Test("A word stored with U+FB03 reads as its letters, in order, and the entries around it are kept")
    func officeWithOneJoinedCode() {
        let entries = [Self.entry("o", 0), Self.entry("\u{FB03}", 1), Self.entry("c", 2), Self.entry("e", 3)]
        let folded = JoinedLetterFold.fold(entries)
        #expect(folded.map(\.character) == ["o", "f", "f", "i", "c", "e"])
        #expect(folded.map(\.stringIndex) == [0, 1, 1, 1, 2, 3])
    }

    @Test("Entries with no joined-letter code point are kept exactly")
    func noJoinedLetter() {
        let entries = [Self.entry("n", 0), Self.entry("a", 1), Self.entry("\u{00EF}", 2), Self.entry("\u{6771}", 3)]
        let folded = JoinedLetterFold.fold(entries)
        #expect(folded.map(\.character) == entries.map(\.character))
        #expect(folded.map(\.stringIndex) == entries.map(\.stringIndex))
    }

    @Test("In an entry that holds a joined letter beside another character, the other stays one entry in its place")
    func joinedLetterBesideAnother() {
        let folded = JoinedLetterFold.fold([Self.entry("x\u{FB01}", 4)])
        #expect(folded.map(\.character) == ["x", "f", "i"])
        #expect(folded.allSatisfy { $0.stringIndex == 4 })
    }

    @Test("No entries fold to no entries")
    func empty() {
        #expect(JoinedLetterFold.fold([]).isEmpty)
    }
}
