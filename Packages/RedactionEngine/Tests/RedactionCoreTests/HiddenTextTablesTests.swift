import Foundation
import Testing
import RedactionCore

@Suite("The hidden text's two tables")
struct HiddenTextTablesTests {

    struct Row: CustomTestStringConvertible, Sendable {
        let name: String
        let scalar: Unicode.Scalar
        var testDescription: String { name }
    }

    @Test("The joined-letter table holds the seven code points U+FB00 to U+FB06 and their letters")
    func joinedLetterTable() {
        let expected: [UInt32: String] = [
            0xFB00: "ff", 0xFB01: "fi", 0xFB02: "fl", 0xFB03: "ffi",
            0xFB04: "ffl", 0xFB05: "st", 0xFB06: "st",
        ]
        #expect(JoinedLetters.letters.count == 7)
        for (value, letters) in expected {
            #expect(JoinedLetters.letters(of: Unicode.Scalar(value)!) == letters,
                    "U+\(String(value, radix: 16, uppercase: true))")
        }
    }

    static let notJoined: [Row] = [
        Row(name: "a letter", scalar: "f"),
        Row(name: "the Armenian joined letters after the Latin seven", scalar: "\u{FB13}"),
        Row(name: "the code point before the seven", scalar: "\u{FAFF}"),
    ]

    @Test("A character that is not one of the seven has no letters of its own", arguments: notJoined)
    func notAJoinedLetter(_ row: Row) {
        #expect(JoinedLetters.letters(of: row.scalar) == nil)
    }

    @Test("The not-joined table holds three rows")
    func notJoinedLength() {
        #expect(Self.notJoined.count == 3)
    }

    static let neverWritten: [Row] = [
        Row(name: "the object mark", scalar: "\u{FFFC}"),
        Row(name: "the replacement character", scalar: "\u{FFFD}"),
        Row(name: "a control below the space", scalar: "\u{0007}"),
        Row(name: "a control after delete", scalar: "\u{0085}"),
        Row(name: "the Arabic letter mark", scalar: "\u{061C}"),
        Row(name: "the left-to-right mark", scalar: "\u{200E}"),
        Row(name: "a right-to-left override", scalar: "\u{202E}"),
        Row(name: "a first-strong isolate", scalar: "\u{2068}"),
        Row(name: "a private-use character", scalar: "\u{E000}"),
        Row(name: "a character of the last private-use plane", scalar: "\u{10FFFD}"),
        Row(name: "a Hebrew letter", scalar: "\u{05D0}"),
        Row(name: "an Arabic letter", scalar: "\u{0628}"),
        Row(name: "a Syriac letter", scalar: "\u{0710}"),
        Row(name: "a Thaana letter", scalar: "\u{0780}"),
        Row(name: "an NKo letter", scalar: "\u{07CA}"),
        Row(name: "a Hebrew presentation form", scalar: "\u{FB2A}"),
        Row(name: "an Arabic presentation form", scalar: "\u{FE8F}"),
        Row(name: "a Phoenician letter", scalar: "\u{10900}"),
        Row(name: "an Adlam letter", scalar: "\u{1E900}"),
    ]

    @Test("A character the hidden text never holds is in the table", arguments: neverWritten)
    func inTheTable(_ row: Row) {
        #expect(NeverWrittenCharacters.contains(row.scalar))
    }

    @Test("The never-written rows are nineteen")
    func neverWrittenLength() {
        #expect(Self.neverWritten.count == 19)
    }

    static let written: [Row] = [
        Row(name: "a space", scalar: " "),
        Row(name: "a Latin letter", scalar: "a"),
        Row(name: "a Latin letter with a stroke", scalar: "\u{0141}"),
        Row(name: "a Greek letter", scalar: "\u{03A9}"),
        Row(name: "a Cyrillic letter", scalar: "\u{0416}"),
        Row(name: "the euro sign", scalar: "\u{20AC}"),
        Row(name: "an arrow", scalar: "\u{2192}"),
        Row(name: "a Han character", scalar: "\u{6771}"),
        Row(name: "a joined letter", scalar: "\u{FB01}"),
        Row(name: "an emoji", scalar: "\u{1F600}"),
    ]

    @Test("A character any font might draw is not in the table", arguments: written)
    func notInTheTable(_ row: Row) {
        #expect(!NeverWrittenCharacters.contains(row.scalar))
    }

    @Test("The written rows are ten")
    func writtenLength() {
        #expect(Self.written.count == 10)
    }
}
