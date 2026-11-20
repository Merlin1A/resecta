import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

@Suite("The hidden text's alphabet pages")
struct HiddenTextAlphabetPagesTests {

    /// `text` as runs: split at white space and at the object mark, each
    /// joined-letter code point written as its letters.
    static func runs(_ text: String) -> [String] {
        var folded = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if let letters = JoinedLetters.letters(of: scalar) {
                folded.append(contentsOf: letters.unicodeScalars)
            } else {
                folded.append(scalar)
            }
        }
        return String(folded)
            .split(whereSeparator: { $0.isWhitespace || $0.unicodeScalars.elementsEqual([NeverWrittenCharacters.objectMark]) })
            .map(String.init)
    }

    @Test("The pages are thirteen")
    func pageCount() {
        #expect(TestFixtures.hiddenTextAlphabetPages.count == 13)
    }

    @Test("Each page is one page with no document information", arguments: TestFixtures.hiddenTextAlphabetPages)
    func onePageNoInformation(_ page: HiddenTextAlphabetPage) throws {
        let document = try #require(PDFDocument(data: page.data))
        #expect(document.pageCount == 1)
        let attributes = document.documentAttributes ?? [:]
        for key in [PDFDocumentAttribute.titleAttribute, .authorAttribute, .subjectAttribute,
                    .creatorAttribute, .producerAttribute, .keywordsAttribute] {
            #expect(attributes[key] == nil, "\(key.rawValue)")
        }
    }

    @Test("Each page reads back its own runs", arguments: TestFixtures.hiddenTextAlphabetPages)
    func readsBackItsRuns(_ page: HiddenTextAlphabetPage) throws {
        let document = try #require(PDFDocument(data: page.data))
        let text = try #require(document.page(at: 0)?.string)
        #expect(Self.runs(text) == Self.runs(page.lines.joined(separator: "\n")))
    }

    @Test("Each page's hand-listed runs left out are the runs the fonts cannot write",
          arguments: TestFixtures.hiddenTextAlphabetPages.filter { $0.leftOut != nil })
    func handListAgreesWithTheFonts(_ page: HiddenTextAlphabetPage) {
        let counted = Self.runs(page.lines.joined(separator: "\n"))
            .filter { !page.boxed.contains($0) }
            .filter { !HiddenTextFonts.canBeWritten($0) }
        #expect(counted == page.leftOut)
    }
}
