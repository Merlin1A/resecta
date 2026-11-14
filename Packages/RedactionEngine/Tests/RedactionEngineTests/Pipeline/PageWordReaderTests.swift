import Foundation
import PDFKit
import Testing
@testable import RedactionEngine

/// The page reader fills the core's words from the engine's own extractor:
/// the same boxes, in the page's points as displayed.
@Suite struct PageWordReaderTests {
    @Test("A drawn page's words come from its string, with the extractor's boxes")
    func drawnPage() async throws {
        let data = TestFixtures.textLayerPDF(text: "Roe. Ann Lee-Park", fontSize: 24)
        let page = try #require(PDFDocument(data: data)?.page(at: 0))
        let text = try #require(page.string)
        let displayed = page.bounds(for: .cropBox)
        let words = try await PageWordReader.words(on: page)
        let units = Array(text.utf16)
        let spelled = words.words.map { word in String(decoding: word.letters.map { units[$0] }, as: UTF16.self) }
        #expect(spelled == ["Roe.", "Ann", "Lee-Park"])
        // The same page read again through the extractor directly gives the same words.
        let again = try #require(PDFDocument(data: data)?.page(at: 0))
        let characters = try await TextLayerExtractor().extractCharacters(from: again)
        #expect(words == PageWordReader.words(text: text, characters: characters))
        for word in words.words {
            #expect(word.source == .textLayer)
            let box = try #require(word.box)
            #expect(box.minX >= 0 && box.maxX <= Double(displayed.width) && box.minY >= 0 && box.maxY <= Double(displayed.height))
            #expect((word.letterSize ?? 0) > 0)
        }
    }

    @Test("The reader turns each character's box into a letter box at its offset")
    func boxesByOffset() {
        let characters = [
            CharacterInfo(character: "A", bounds: CGRect(x: 10, y: 20, width: 6, height: 9.5), stringIndex: 0, lineIndex: 0),
            CharacterInfo(character: "b", bounds: CGRect(x: 16, y: 20, width: 6, height: 9.5), stringIndex: 1, lineIndex: 0),
            CharacterInfo(character: "c", bounds: CGRect(x: 30, y: 20, width: 6, height: 12), stringIndex: 3, lineIndex: 0),
        ]
        let words = PageWordReader.words(text: "Ab c", characters: characters)
        #expect(words.words.map(\.letters) == [[0, 1], [3]])
        #expect(words.words[0].box == PointRect(minX: 10, minY: 20, maxX: 22, maxY: 29.5))
        #expect(words.words.map(\.letterSize) == [608, 768])
    }
}
