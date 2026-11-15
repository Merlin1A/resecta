/// A rectangle in the page's own points as displayed, origin bottom-left.
package struct PointRect: Hashable, Sendable {
    package var minX: Double
    package var minY: Double
    package var maxX: Double
    package var maxY: Double

    package init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    package var height: Double { maxY - minY }

    /// The smallest rectangle that holds both.
    package func union(_ other: PointRect) -> PointRect {
        PointRect(minX: Swift.min(minX, other.minX), minY: Swift.min(minY, other.minY),
                  maxX: Swift.max(maxX, other.maxX), maxY: Swift.max(maxY, other.maxY))
    }
}

/// One letter's box as the text walk read it: the UTF-16 offset of the
/// page's string it starts at, and its selection box.
package struct LetterBox: Hashable, Sendable {
    package var offset: Int
    package var rect: PointRect

    package init(offset: Int, rect: PointRect) {
        self.offset = offset
        self.rect = rect
    }
}

/// Where a page's words were read from.
package enum WordSource: String, Hashable, Sendable, Codable, CaseIterable {
    /// The page's text layer.
    case textLayer
    /// Text recognition on the page's picture.
    case recognised
    /// The ink tokens of a read of the page's picture.
    case inkTokens
    /// No letter of the word has a box.
    case none
}

/// One word of a page, by the page's one partition.
package struct PageWord: Hashable, Sendable {
    /// The word's index in the partition.
    package var index: Int
    /// The word's letters: its offsets that are not white space, in order.
    package var letters: [Int]
    /// The bounding rectangle of its letters' boxes, or nil when none has one.
    package var box: PointRect?
    /// Its letters' own boxes, in the order of its letters; a letter the
    /// walk gave two boxes has both, in the walk's order, and a letter with
    /// no box has none.
    package var letterBoxes: [LetterBox]
    /// The most common height among its letters' boxes, in whole
    /// sixty-fourths of a point (each height rounded to the nearest); when
    /// two heights are equally common, the larger. Nil when no letter has a
    /// box.
    package var letterSize: Int?
    package var source: WordSource

    package init(index: Int, letters: [Int], box: PointRect?, letterSize: Int?, source: WordSource,
                 letterBoxes: [LetterBox] = []) {
        self.index = index
        self.letters = letters
        self.box = box
        self.letterBoxes = letterBoxes
        self.letterSize = letterSize
        self.source = source
    }
}

/// A page's words: the page's string split by its one partition, with each
/// word's letter boxes grouped under it. The words come from the string
/// alone; the boxes only fill them in, so a letter with no box leaves its
/// word in place, and a box at a white-space offset belongs to no word.
package struct PageWords: Hashable, Sendable {
    /// Every word with at least one letter, in the string's order.
    package var words: [PageWord]

    package init(words: [PageWord]) { self.words = words }

    /// The words of `text`, with `boxes` grouped under them. A box whose
    /// offset is white space or lies outside the string is left out; a word
    /// none of whose letters has a box has source `none`.
    package init(text: String, boxes: [LetterBox], source: WordSource) {
        let units = Array(text.utf16)
        let indices = WordPartition.wordIndices(utf16: units)
        var boxesAt: [Int: [PointRect]] = [:]
        for box in boxes where box.offset >= 0 && box.offset < units.count && !WordPartition.isWhiteSpace(units[box.offset]) {
            boxesAt[box.offset, default: []].append(box.rect)
        }
        var words: [PageWord] = []
        for letters in WordPartition.words(of: text) {
            let letterBoxes = letters.flatMap { offset in (boxesAt[offset] ?? []).map { LetterBox(offset: offset, rect: $0) } }
            let rects = letterBoxes.map(\.rect)
            let box = rects.dropFirst().reduce(rects.first) { $0?.union($1) }
            words.append(PageWord(index: indices[letters[0]], letters: letters, box: box,
                                  letterSize: Self.letterSize(of: rects), source: rects.isEmpty ? .none : source,
                                  letterBoxes: letterBoxes))
        }
        self.words = words
    }

    /// The most common height among `rects` in whole sixty-fourths of a
    /// point, the larger on a tie; nil for none.
    package static func letterSize(of rects: [PointRect]) -> Int? {
        var counts: [Int: Int] = [:]
        for rect in rects { counts[Int((rect.height * 64).rounded()), default: 0] += 1 }
        return counts.max { a, b in a.value != b.value ? a.value < b.value : a.key < b.key }?.key
    }

    /// The word whose letters include `offset`, if any.
    package func word(containing offset: Int) -> PageWord? {
        words.first { $0.letters.contains(offset) }
    }
}
