import Foundation
import Testing
@testable import ResectaApp
import RedactionEngine

// The units the stop at Redact keeps accounts for, and when one covers
// another (K7-30, K7-31 at the unit).

@Suite("Redact stop: units and covering")
struct RedactStopUnitTests {

    /// The 32 settings of the five matching options, each with Include OCR
    /// Pages and all-terms set both ways.
    static func settings() -> [[SearchOptions]] {
        (0..<32).map { bits in
            [(false, false), (true, true), (true, false), (false, true)].map { ocr, all in
                SearchOptions(caseSensitive: bits & 1 != 0, wholeWord: bits & 2 != 0, includeOCR: ocr,
                              stripDigitSeparators: bits & 4 != 0, normalizeSmartPunctuation: bits & 8 != 0,
                              foldDiacritics: bits & 16 != 0, multiTermConjunction: all)
            }
        }
    }

    @Test("K7-30: covering over every pair of the 32 settings: from a setting to itself, never both ways between two, through a third; Include OCR Pages and all-terms change nothing")
    func coveringIsAnOrder() {
        let all = Self.settings()
        let units = all.map { $0.map { RedactStopUnit(kind: .text, text: "Hartwell", options: $0) } }
        var broken: [String] = []
        for a in 0..<32 {
            if Set(units[a]).count != 1 { broken.append("OCR or all-terms changed unit \(a)") }
            let ua = units[a][0]
            if !ua.covers(ua) { broken.append("\(a) does not cover itself") }
            for b in 0..<32 where a != b {
                let ub = units[b][0]
                if ua.covers(ub) && ub.covers(ua) { broken.append("\(a) and \(b) cover each other") }
                for c in 0..<32 where ua.covers(ub) && ub.covers(units[c][0]) && !ua.covers(units[c][0]) {
                    broken.append("\(a) covers \(b) covers \(c), but not \(a) \(c)")
                }
            }
        }
        #expect(broken.isEmpty, "\(broken.prefix(5))")
    }

    @Test("K7-28 and K7-31 at the unit: Whole Word off covers Whole Word on, never the other way")
    func looserCoversStricter() {
        let off = RedactStopUnit(kind: .text, text: "Hartwell", options: SearchOptions(wholeWord: false))
        let on = RedactStopUnit(kind: .text, text: "Hartwell", options: SearchOptions(wholeWord: true))
        #expect(off.covers(on))
        #expect(!on.covers(off))
    }

    @Test("K7-29 at the unit: case-sensitive with Accents on, and ignoring case with Accents off: neither covers the other")
    func neitherCovers() {
        let one = RedactStopUnit(kind: .text, text: "Hartwell", options: SearchOptions(caseSensitive: true, foldDiacritics: true))
        let two = RedactStopUnit(kind: .text, text: "Hartwell", options: SearchOptions(caseSensitive: false, foldDiacritics: false))
        #expect(!one.covers(two) && !two.covers(one))
    }

    @Test("A different text, or a different kind with the same text, is never covered")
    func kindAndText() {
        let text = RedactStopUnit(kind: .text, text: "a+", options: SearchOptions())
        #expect(!text.covers(RedactStopUnit(kind: .pattern, text: "a+", options: SearchOptions())))
        #expect(!text.covers(RedactStopUnit(kind: .text, text: "b+", options: SearchOptions())))
    }

    @Test("Units of a search: one per text, one per term, the pattern, one Scan")
    func unitsOfASearch() {
        let options = SearchOptions()
        #expect(RedactStopUnit.units(of: AppliedSearchQuery(kind: .text("Delia"), options: options)).map(\.text) == ["Delia"])
        let terms = RedactStopUnit.units(of: AppliedSearchQuery(kind: .multiTerm(["Delia", "Rourke"]), options: options))
        #expect(terms.map(\.text) == ["Delia", "Rourke"] && terms.allSatisfy { $0.kind == .text })
        #expect(RedactStopUnit.units(of: AppliedSearchQuery(kind: .regex("[0-9]+"), options: options)).map(\.kind) == [.pattern])
        let scan = RedactStopUnit.units(of: AppliedSearchQuery(kind: .piiScan(categories: []), options: options))
        #expect(scan.map(\.kind) == [.scan] && scan.map(\.text) == [""])
    }
}
