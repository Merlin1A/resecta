import Foundation
import Testing
import RedactionCore

/// One table for the page's word partition, its words and selection. Each
/// row gives a page string, the letters that have no box, and what the
/// partition, the words and a selection must give.
@Suite struct WordPartitionTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let text: String
        /// The word index of every UTF-16 offset.
        let indices: [Int]
        /// Each word's letters, as (word index, offsets).
        let words: [(Int, [Int])]
        /// Offsets with no box. Every other offset has one, white space included.
        var unboxed: Set<Int> = []
        /// A Search match as UTF-16 ranges, and what selecting it by character
        /// and by whole word gives.
        var match: [Range<Int>] = []
        var byCharacter: Set<Int> = []
        var byWholeWord: Set<Int> = []
        /// Box heights by offset, where not the default 10 pt; and each
        /// word's letter size in sixty-fourths, where checked.
        var heights: [Int: Double] = [:]
        var letterSizes: [Int?] = []
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "Roe. matched by Roe: three letters selected, the full stop stays",
             text: "Roe.", indices: [0, 0, 0, 0], words: [(0, [0, 1, 2, 3])],
             match: [0..<3], byCharacter: [0, 1, 2], byWholeWord: [0, 1, 2, 3]),
        Case(name: "a run of white space ticks at each offset",
             text: "Ann  Roe", indices: [0, 0, 0, 1, 2, 2, 2, 2], words: [(0, [0, 1, 2]), (2, [5, 6, 7])],
             match: [5..<8], byCharacter: [5, 6, 7], byWholeWord: [5, 6, 7]),
        Case(name: "white space at either end",
             text: " Ann ", indices: [1, 1, 1, 1, 2], words: [(1, [1, 2, 3])],
             match: [0..<5], byCharacter: [1, 2, 3], byWholeWord: [1, 2, 3]),
        Case(name: "a no-break space ticks",
             text: "Ann\u{00A0}Roe", indices: [0, 0, 0, 1, 1, 1, 1], words: [(0, [0, 1, 2]), (1, [4, 5, 6])],
             match: [4..<6], byCharacter: [4, 5], byWholeWord: [4, 5, 6]),
        Case(name: "a zero-width space does not tick",
             text: "Ann\u{200B}Roe", indices: [0, 0, 0, 0, 0, 0, 0], words: [(0, [0, 1, 2, 3, 4, 5, 6])],
             match: [4..<7], byCharacter: [4, 5, 6], byWholeWord: [0, 1, 2, 3, 4, 5, 6]),
        Case(name: "a hyphenated word is one word",
             text: "Mary-Ann Roe", indices: [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1],
             words: [(0, [0, 1, 2, 3, 4, 5, 6, 7]), (1, [9, 10, 11])],
             match: [5..<8], byCharacter: [5, 6, 7], byWholeWord: [0, 1, 2, 3, 4, 5, 6, 7]),
        Case(name: "a joined letter is one character",
             text: "\u{FB01}ne fit", indices: [0, 0, 0, 1, 1, 1, 1], words: [(0, [0, 1, 2]), (1, [4, 5, 6])],
             match: [0..<1], byCharacter: [0], byWholeWord: [0, 1, 2]),
        Case(name: "a letter with no box stays in its word",
             text: "Ann Roe", indices: [0, 0, 0, 1, 1, 1, 1], words: [(0, [0, 1, 2]), (1, [4, 5, 6])],
             unboxed: [5], match: [4..<7], byCharacter: [4, 5, 6], byWholeWord: [4, 5, 6]),
        Case(name: "white space the walk skipped still ticks",
             text: "Ann Roe", indices: [0, 0, 0, 1, 1, 1, 1], words: [(0, [0, 1, 2]), (1, [4, 5, 6])],
             unboxed: [3]),
        Case(name: "a line break ticks",
             text: "Ann\nRoe", indices: [0, 0, 0, 1, 1, 1, 1], words: [(0, [0, 1, 2]), (1, [4, 5, 6])]),
        Case(name: "a letter outside the basic plane takes two offsets in its word",
             text: "a \u{1D400}b", indices: [0, 1, 1, 1, 1], words: [(0, [0]), (1, [2, 3, 4])],
             match: [2..<4], byCharacter: [2, 3], byWholeWord: [2, 3, 4]),
        Case(name: "the letter size is the most common height",
             text: "Ann", indices: [0, 0, 0], words: [(0, [0, 1, 2])],
             heights: [0: 12, 1: 10, 2: 10], letterSizes: [640]),
        Case(name: "each height is rounded to the nearest sixty-fourth before it is counted",
             text: "Ann Roe", indices: [0, 0, 0, 1, 1, 1, 1], words: [(0, [0, 1, 2]), (1, [4, 5, 6])],
             heights: [0: 10, 1: 10.004, 2: 12, 4: 9.99, 5: 10, 6: 10.007], letterSizes: [640, 640]),
        Case(name: "two heights equally common: the larger",
             text: "Ann", indices: [0, 0, 0], words: [(0, [0, 1, 2])],
             unboxed: [2], heights: [0: 10, 1: 12], letterSizes: [768]),
        Case(name: "two heights equally common: the larger, whichever letter comes first",
             text: "Ann", indices: [0, 0, 0], words: [(0, [0, 1, 2])],
             unboxed: [2], heights: [0: 12, 1: 9.5], letterSizes: [768]),
        Case(name: "a word with no box has no box, no letter size and no source",
             text: "Ann Roe", indices: [0, 0, 0, 1, 1, 1, 1], words: [(0, [0, 1, 2]), (1, [4, 5, 6])],
             unboxed: [0, 1, 2], heights: [4: 9.5, 5: 9.5, 6: 9.5], letterSizes: [nil, 608]),
    ]

    static func boxes(_ c: Case) -> [LetterBox] {
        (0..<c.text.utf16.count).filter { !c.unboxed.contains($0) }.map { offset in
            let height = c.heights[offset] ?? 10
            return LetterBox(offset: offset, rect: PointRect(minX: Double(offset) * 6, minY: 100,
                                                            maxX: Double(offset) * 6 + 6, maxY: 100 + height))
        }
    }

    @Test("Each case", arguments: cases)
    func eachCase(_ c: Case) {
        #expect(WordPartition.wordIndices(of: c.text) == c.indices)
        let words = PageWords(text: c.text, boxes: Self.boxes(c), source: .textLayer)
        #expect(words.words.map(\.index) == c.words.map(\.0))
        #expect(words.words.map(\.letters) == c.words.map(\.1))
        for word in words.words {
            let boxed = word.letters.filter { !c.unboxed.contains($0) }
            #expect(word.source == (boxed.isEmpty ? WordSource.none : WordSource.textLayer))
            #expect((word.box == nil) == boxed.isEmpty)
            if let first = boxed.first, let last = boxed.last, let box = word.box {
                #expect(box.minX == Double(first) * 6 && box.maxX == Double(last) * 6 + 6)
            }
        }
        if !c.letterSizes.isEmpty {
            #expect(words.words.map(\.letterSize) == c.letterSizes)
        }
        if !c.match.isEmpty {
            #expect(WordSelection.characters(c.match, in: c.text).offsets == c.byCharacter)
            #expect(WordSelection.wholeWords(c.match, in: c.text).offsets == c.byWholeWord)
        }
    }

    @Test("The table's length is pinned")
    func tableLength() { #expect(Self.cases.count == 16) }

    /// The partition is a function of the string alone: the same string with
    /// boxes dropped, moved or resized gives the same indices and letters.
    @Test("The partition depends on the string alone")
    func partitionDependsOnTheStringAlone() {
        let text = "  Dr. Ann\u{00A0}Roe-Smith,\n\u{FB01}le 12\u{200B}3 \u{1D400} "
        let count = text.utf16.count
        let reference = PageWords(text: text, boxes: [], source: .textLayer)
        var generator = SplitMix64(seed: 0x6A09E667F3BCC908)
        for _ in 0..<64 {
            var boxes: [LetterBox] = []
            for offset in 0..<count where generator.next() % 3 != 0 {
                let x = Double(generator.next() % 600), y = Double(generator.next() % 800)
                boxes.append(LetterBox(offset: offset, rect: PointRect(minX: x, minY: y, maxX: x + 5,
                                                                      maxY: y + Double(1 + generator.next() % 20))))
            }
            boxes.shuffle(using: &generator)
            let words = PageWords(text: text, boxes: boxes, source: .recognised)
            #expect(words.words.map(\.index) == reference.words.map(\.index))
            #expect(words.words.map(\.letters) == reference.words.map(\.letters))
        }
        #expect(WordPartition.wordIndices(of: text).count == count)
    }

    @Test("A box at a white-space offset or off the string belongs to no word")
    func stray() {
        let boxes = [LetterBox(offset: 3, rect: PointRect(minX: 0, minY: 0, maxX: 500, maxY: 50)),
                     LetterBox(offset: 99, rect: PointRect(minX: 0, minY: 0, maxX: 500, maxY: 50)),
                     LetterBox(offset: -1, rect: PointRect(minX: 0, minY: 0, maxX: 500, maxY: 50))]
        let words = PageWords(text: "Ann Roe", boxes: boxes, source: .inkTokens)
        #expect(words.words.allSatisfy { $0.box == nil && $0.source == WordSource.none })
    }
}

/// A small seeded generator, so the property's draws are the same each run.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
