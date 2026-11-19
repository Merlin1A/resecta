import Foundation
import Testing
@testable import RedactionEngine
@testable import ResectaApp

// Typed Search matches the text typed, under its folds, and nothing else.
// Each form in `SearchUntriedForm` keeps a case that Search misses with its
// default options. A release that starts matching one of these cases must
// change the list of forms in the same change. The cases run through the
// literal matcher's own primitives, as the engine's tests do. Each case's
// page is also searched for its own text, so a miss here is a miss of the
// matcher, not a matcher that matches nothing.

@Suite("Forms Search does not try")
struct SearchUntriedFormsTests {

    enum MissCase: String, CaseIterable, CustomTestStringConvertible {
        case surnameOnItsOwn
        case initials
        case nickname
        case misspelling
        case accent
        case lastNameFirst
        case shortFormOfAWord
        case dateWrittenAnotherWay
        case amountWrittenAnotherWay

        var testDescription: String { rawValue }

        var form: SearchUntriedForm {
            switch self {
            case .surnameOnItsOwn: .partOfAName
            case .initials: .initials
            case .nickname: .nickname
            case .misspelling: .misspelling
            case .accent: .accent
            case .lastNameFirst, .shortFormOfAWord: .nameWrittenAnotherWay
            case .dateWrittenAnotherWay, .amountWrittenAnotherWay: .numberWrittenAnotherWay
            }
        }

        /// The text on the page.
        var page: String {
            switch self {
            case .surnameOnItsOwn: "Hartwell"
            case .initials: "D. Hartwell"
            case .nickname: "Dee Hartwell"
            case .misspelling: "Hartwel"
            case .accent: "Mu\u{00F1}oz"
            case .lastNameFirst: "Hartwell, Delia"
            case .shortFormOfAWord: "Acme Incorporated"
            case .dateWrittenAnotherWay: "March 4, 2026"
            case .amountWrittenAnotherWay: "1,200.00"
            }
        }

        /// The text typed into Search.
        var query: String {
            switch self {
            case .surnameOnItsOwn, .initials, .nickname, .lastNameFirst: "Delia Hartwell"
            case .misspelling: "Hartwell"
            case .accent: "Munoz"
            case .shortFormOfAWord: "Acme Inc."
            case .dateWrittenAnotherWay: "03/04/2026"
            case .amountWrittenAnotherWay: "1200"
            }
        }
    }

    /// The number of literal matches of `query` on `page`, by the matcher's
    /// own steps: the effective options, the prepared page, the prepared
    /// query, then the literal walk with no cap.
    static func matches(page: String, query: String, options: SearchOptions) -> Int {
        let effective = SearchCore.effectiveOptions(options, pageText: page, detectCJK: true)
        let prepared = SearchCore.preparePage(page, options: effective)
        let typed = SearchCore.preparedQuery(
            normalized: SearchCore.normalizedText(query, options: effective), options: effective)
        guard !typed.isEmpty else { return 0 }
        return SearchCore.literalSpans(
            in: prepared, query: typed, comparison: [], wholeWord: effective.wholeWord, cap: nil
        ).spans.count
    }

    @Test("The miss cases are all here, and every form has one")
    func casesAreAllHere() {
        #expect(MissCase.allCases.count == 9)
        #expect(SearchUntriedForm.allCases.count == 7)
        #expect(Set(MissCase.allCases.map(\.form)) == Set(SearchUntriedForm.allCases))
    }

    @Test("A form Search does not try stays a miss with the default options", arguments: MissCase.allCases)
    func staysAMiss(_ row: MissCase) {
        let defaults = SearchOptions()
        #expect(Self.matches(page: row.page, query: row.query, options: defaults) == 0)
        #expect(Self.matches(page: row.page, query: row.page, options: defaults) == 1)
        if row == .accent {
            var accents = defaults
            accents.foldDiacritics = true
            #expect(Self.matches(page: row.page, query: row.query, options: accents) == 1)
        }
    }
}
