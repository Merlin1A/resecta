import Foundation
import Testing
@testable import RedactionEngine

// The pages the hidden text's alphabet is measured on, made on the joined-glyph
// builder: named, unembedded fonts, a ToUnicode map giving each code its text,
// and a painted rectangle for each glyph's ink. All text is invented. Each page
// carries, written by hand, the runs the alphabet leaves out of its hidden
// text (a run is text between white space; a line's end is white space; the
// object mark is a break between runs and is never a run of its own) and the
// runs a box takes, which are not counted. A right-to-left word stands on a
// line of its own or beside left-to-right words, so the reader's order is the
// page's.

struct HiddenTextAlphabetPage: Sendable, CustomTestStringConvertible {
    let name: String
    let lines: [String]
    /// How a joined letter stored on the page reads: its letters, or the one
    /// presentation-form code point.
    var text: TestFixtures.JoinedGlyphText = .letters
    /// The runs taken by a box drawn over them, which the count leaves out.
    var boxed: [String] = []
    /// The runs left out of the hidden text, by hand; nil for the page the
    /// right-to-left rule makes a picture before and after, where no run is
    /// written or counted.
    let leftOut: [String]?
    var testDescription: String { name }

    /// The page as a writer stores it: a run of right-to-left letters in
    /// the order it is drawn, left to right, which a reader turns back.
    var data: Data { TestFixtures.joinedGlyphPDF(lines: lines.map(Self.drawnOrder), text: text) }

    static func drawnOrder(_ line: String) -> String {
        line.split(separator: " ", omittingEmptySubsequences: false).map { run in
            let rightToLeft = run.unicodeScalars.contains { (0x0590...0x08FF).contains($0.value) }
            return rightToLeft ? String(String.UnicodeScalarView(run.unicodeScalars.reversed())) : String(run)
        }.joined(separator: " ")
    }
}

extension TestFixtures {

    static let hiddenTextAlphabetPages: [HiddenTextAlphabetPage] = [
        HiddenTextAlphabetPage(
            name: "the seven joined letters, each stored as one character",
            lines: ["o\u{FB03}ce wa\u{FB04}e e\u{FB00}ort", "\u{FB01}le \u{FB02}ag fa\u{FB05} la\u{FB06}"],
            text: .presentationForm, leftOut: []),
        HiddenTextAlphabetPage(
            name: "fi stored as one character three times",
            lines: ["\u{FB01}ve \u{FB01}les \u{FB01}rst"], text: .presentationForm, leftOut: []),
        HiddenTextAlphabetPage(
            name: "an English page", lines: ["Report summary"], leftOut: []),
        HiddenTextAlphabetPage(
            name: "English and Chinese words", lines: ["Report \u{6771}\u{4EAC} summary"],
            leftOut: ["\u{6771}\u{4EAC}"]),
        HiddenTextAlphabetPage(
            name: "a page wholly in Chinese", lines: ["\u{6771}\u{4EAC} \u{5927}\u{962A}", "\u{540D}\u{53E4}\u{5C4B}"],
            leftOut: ["\u{6771}\u{4EAC}", "\u{5927}\u{962A}", "\u{540D}\u{53E4}\u{5C4B}"]),
        HiddenTextAlphabetPage(
            name: "one English word under a box and the rest Chinese",
            lines: ["Secret \u{6771}\u{4EAC} \u{5927}\u{962A}"], boxed: ["Secret"],
            leftOut: ["\u{6771}\u{4EAC}", "\u{5927}\u{962A}"]),
        HiddenTextAlphabetPage(
            name: "a year with a Han character on an English page", lines: ["Paid 2024\u{5E74} in full"],
            leftOut: ["2024\u{5E74}"]),
        HiddenTextAlphabetPage(
            name: "a lone private-use bullet", lines: ["\u{E000} Item one"], leftOut: ["\u{E000}"]),
        HiddenTextAlphabetPage(
            name: "the object mark between two words, and alone", lines: ["Before\u{FFFC}after", "\u{FFFC}"],
            leftOut: []),
        HiddenTextAlphabetPage(
            name: "Syriac and Thaana words on an English page",
            lines: ["Report summary", "\u{0710}\u{072A}\u{0721}\u{071D}\u{0710}", "\u{0780}\u{07A6}"],
            leftOut: ["\u{0710}\u{072A}\u{0721}\u{071D}\u{0710}", "\u{0780}\u{07A6}"]),
        HiddenTextAlphabetPage(
            name: "emoji beside and inside English words", lines: ["Due \u{1F4C5} Friday", "Done\u{1F600}"],
            leftOut: ["\u{1F4C5}", "Done\u{1F600}"]),
        HiddenTextAlphabetPage(
            name: "every word under a box", lines: ["Secret words"], boxed: ["Secret", "words"], leftOut: []),
        HiddenTextAlphabetPage(
            name: "an English page with one Hebrew word (the right-to-left control)",
            lines: ["Report \u{05E9}\u{05DC}\u{05D5}\u{05DD} summary"], leftOut: nil),
    ]
}
