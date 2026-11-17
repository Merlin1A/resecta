import Foundation
import Testing
import RedactionCore

/// A page's words keep their letters' own boxes, so what is left of a word
/// when some of its letters are selected still has its boxes, and a word's
/// first and last letters can be compared.
@Suite struct PageWordLetterBoxesTests {
    private static func box(_ offset: Int, x: Double, y: Double = 100, width: Double = 6, height: Double = 10) -> LetterBox {
        LetterBox(offset: offset, rect: PointRect(minX: x, minY: y, maxX: x + width, maxY: y + height))
    }

    @Test("Each letter's box is kept at its offset, in the word's letter order, and the word's box is their union")
    func lettersKeepTheirBoxes() throws {
        // "Roe. Ann": the boxes arrive out of order; white space has a box too.
        let boxes = [Self.box(3, x: 18), Self.box(0, x: 0), Self.box(2, x: 12), Self.box(1, x: 6),
                     Self.box(4, x: 24), Self.box(5, x: 30), Self.box(6, x: 36), Self.box(7, x: 42)]
        let words = PageWords(text: "Roe. Ann", boxes: boxes, source: .textLayer)
        let roe = try #require(words.words.first)
        #expect(roe.letterBoxes.map(\.offset) == [0, 1, 2, 3])
        #expect(roe.letterBoxes.map(\.rect.minX) == [0, 6, 12, 18])
        #expect(roe.box == roe.letterBoxes.dropFirst().reduce(roe.letterBoxes[0].rect) { $0.union($1.rect) })
        // The full stop alone, as it is left when "Roe" is selected, keeps its box.
        #expect(roe.letterBoxes.last == Self.box(3, x: 18))
        #expect(words.words[1].letterBoxes.map(\.offset) == [5, 6, 7])
    }

    @Test("A letter with no box has none; a letter the walk gave two boxes keeps both, in the walk's order")
    func missingAndDoubleBoxes() throws {
        let boxes = [Self.box(0, x: 0), Self.box(2, x: 12), Self.box(2, x: 15, width: 3)]
        let word = try #require(PageWords(text: "Ann", boxes: boxes, source: .textLayer).words.first)
        #expect(word.letterBoxes == [Self.box(0, x: 0), Self.box(2, x: 12), Self.box(2, x: 15, width: 3)])
    }

    @Test("A word none of whose letters has a box keeps no letter box")
    func unboxedWord() throws {
        let word = try #require(PageWords(text: "Ann", boxes: [], source: .textLayer).words.first)
        #expect(word.letterBoxes.isEmpty)
        #expect(word.source == WordSource.none)
    }

    @Test("Two pages whose words differ only in one letter's box are not equal")
    func boxesEnterEquality() {
        let a = PageWords(text: "Ann", boxes: [Self.box(0, x: 0), Self.box(1, x: 6), Self.box(2, x: 12)], source: .textLayer)
        let b = PageWords(text: "Ann", boxes: [Self.box(0, x: 0), Self.box(1, x: 7, width: 5), Self.box(2, x: 12)], source: .textLayer)
        #expect(a.words[0].box == b.words[0].box)
        #expect(a != b)
    }
}
