import Testing
import Foundation
@testable import RedactionEngine

// The same-occurrence count of the ink fit's alignment (`alignedBox`): a word
// is counted on the read row and on the layer's line over the stretch the
// alignment matched, so a copy of it in another printed column, read into the
// same row, is not counted against it.

@Suite("Ink fit: same-occurrence count")
struct InkFitOrdinalTests {
    /// Read tokens for `words` on one read row at `y` (10 pt type, 5 pt a
    /// character, a space between words), from `x`.
    static func row(_ words: [String], x: CGFloat, y: CGFloat, line: Int) -> [DocumentSearcher.InkToken] {
        var at = x
        return words.map { word in
            defer { at += CGFloat(word.count + 1) * 5 }
            // Each key letter's character in the word (as `inkTokens(from:size:)` maps it).
            var keyToRaw: [Int] = []
            for (index, character) in word.enumerated() {
                keyToRaw += Array(repeating: index, count: DocumentSearcher.alignmentKey(Substring(String(character))).count)
            }
            return DocumentSearcher.InkToken(key: DocumentSearcher.alignmentKey(Substring(word)),
                                             rect: CGRect(x: at, y: y, width: CGFloat(word.count) * 5, height: 10),
                                             line: line, raw: word, keyToRaw: keyToRaw)
        }
    }

    @Test("A date the other column repeats on the same read row counts once on the match's own stretch, as on its layer line")
    func otherColumnsCopyIsNotCounted() throws {
        // Two printed columns that Vision reads as one row; the layer writes
        // each column as a line of its own.
        let left = "Posted 05/01/2026 to the account", right = "Due 05/01/2026 by return mail"
        let pageText = "\(left)\n\(right)\n" as NSString
        let tokens = Self.row(left.components(separatedBy: " "), x: 72, y: 600, line: 0)
            + Self.row(right.components(separatedBy: " "), x: 330, y: 600, line: 0)
        let range = pageText.range(of: "05")
        // The left date's layer box, drifted 2 pt low.
        let box = CGRect(x: 72 + 7 * 5, y: 598, width: 10, height: 10)
        var model: DocumentSearcher.InkLineModel?
        let placed = DocumentSearcher.alignedBox(range: range, pageText: pageText, near: box, tokens: tokens, model: &model)
        try #require(placed != nil, "the left line aligns to the row's left stretch")
        let m = try #require(model)
        #expect(m.layerOccurrences.count == 1, "the left layer line holds one 05: \(m.layerOccurrences)")
        #expect(m.readTotal == m.layerOccurrences.count,
                "the row's 05s counted over the left stretch (\(m.readTotal)) match the layer line's (\(m.layerOccurrences.count))")
        #expect(m.readBefore == 0, "no 05 before the match on its stretch: \(m.readBefore)")
    }
}
