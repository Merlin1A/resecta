import CoreGraphics
import Foundation
import PDFKit

// The ink fit's alignment (`DocumentSearcher+InkFit.swift`): the layer's words
// placed on the words Vision read on the page, letter by letter along the line.

extension DocumentSearcher {

    /// A word as the alignment compares it: compatibility-folded (a ligature
    /// is its letters), lower case, letters and digits only, with the shapes
    /// a read confuses folded together (o and 0; i, l and 1).
    nonisolated static func alignmentKey(_ word: Substring) -> String {
        String(String(word).precomposedStringWithCompatibilityMapping.lowercased().compactMap { c -> Character? in
            guard c.isLetter || c.isNumber else { return nil }
            switch c {
            case "o": return "0"
            case "i", "l": return "1"
            default: return c
            }
        })
    }

    /// The ink box of `text` from the read tokens near `box` (visual points):
    /// for each word, a token on the box's line (its centre within a line
    /// height of the box's) that equals the word, else one that holds it, the
    /// nearest to the box first; a longer token is cut to the word's share, a
    /// character wider each side, and its cut recorded for the glyph columns.
    /// The box may grow past a side only where the word reaches its token's
    /// edge. Nil unless every word is placed.
    nonisolated static func tokenBox(for text: String, near box: CGRect, tokens: [InkToken])
        -> (rect: CGRect, growLeft: Bool, growRight: Bool, whole: CGRect?, cuts: [InkCut])? {
        let words = text.split(whereSeparator: \.isWhitespace).map(alignmentKey).filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        let reach = max(box.height, 4)
        let nearby = tokens.filter { abs($0.rect.midY - box.midY) <= reach && $0.rect.maxX >= box.minX - 4 * reach && $0.rect.minX <= box.maxX + 4 * reach }
        var placed: [(rect: CGRect, token: InkToken, lo: Int, hi: Int, exact: Bool)] = []
        for word in words {
            var best: (rect: CGRect, token: InkToken, lo: Int, hi: Int, exact: Bool, distance: CGFloat)?
            var rivals = 0
            for token in nearby {
                let key = token.key
                guard let range = key.range(of: word) else { continue }
                let exact = key == word
                let lo = key.distance(from: key.startIndex, to: range.lowerBound)
                let hi = key.distance(from: key.startIndex, to: range.upperBound) - 1
                var rect = token.rect
                if !exact {
                    let unit = token.rect.width / CGFloat(key.count)
                    let x0 = max(token.rect.minX, token.rect.minX + CGFloat(lo) * unit - unit)
                    let x1 = min(token.rect.maxX, token.rect.minX + CGFloat(hi + 1) * unit + unit)
                    rect = CGRect(x: x0, y: token.rect.minY, width: x1 - x0, height: token.rect.height)
                }
                let distance = abs(rect.midX - box.midX) + abs(rect.midY - box.midY)
                if let b = best, b.exact == exact { rivals += 1 }
                if let b = best, (b.exact && !exact) || (b.exact == exact && b.distance <= distance) { continue }
                if let b = best, b.exact != exact { rivals = 0 }
                best = (rect, token, lo, hi, exact, distance)
            }
            // Two read words that could be this one, or a short word found
            // only inside a longer one: not placed (the fit falls back).
            guard let best, rivals == 0, best.exact || word.count > 3 else { return nil }
            placed.append((best.rect, best.token, best.lo, best.hi, best.exact))
        }
        let ordered = placed.sorted { $0.rect.minX < $1.rect.minX }
        guard let first = ordered.first, let last = ordered.last else { return nil }
        let growLeft = first.exact || first.lo == 0
        let growRight = last.exact || last.hi == last.token.key.count - 1
        let rect = placed.dropFirst().reduce(placed[0].rect) { $0.union($1.rect) }
        let wholes = placed.filter(\.exact).map(\.rect)
        let whole = wholes.isEmpty ? nil : wholes.dropFirst().reduce(wholes[0]) { $0.union($1) }
        let cuts = placed.filter { !$0.exact && $0.token.keyToRaw.count == $0.token.key.count }
            .map { InkCut(token: $0.token, rawLo: $0.token.keyToRaw[$0.lo], rawHi: $0.token.keyToRaw[$0.hi]) }
        return (rect, growLeft, growRight, whole, cuts)
    }

    /// A token Vision read, in visual points, with its alignment key and line.
    struct InkToken: Sendable {
        let key: String
        let rect: CGRect
        let line: Int
        /// The token as read, and for each letter of `key` its character index in it.
        var raw: String = ""
        var keyToRaw: [Int] = []
    }

    /// A match cut from a longer token: its first and last character in the
    /// token as read.
    struct InkCut {
        let token: InkToken
        let rawLo: Int
        let rawHi: Int
    }

    /// The ink box of the match at `range` by its place on its line: the
    /// layer's line around the match (the page text between line breaks) is
    /// aligned, letter by letter, with the read line on the box's band most
    /// like it; the match's letters land on the read tokens that hold them,
    /// each token cut to its share. A layer misplaced by a whole word along
    /// its line still names the right letters. Nil when no read line is close.
    nonisolated static func alignedBox(range: NSRange, pageText: NSString, near box: CGRect, tokens: [InkToken])
        -> (rect: CGRect, growLeft: Bool, growRight: Bool, whole: CGRect?, cuts: [InkCut])? {
        var model: InkLineModel?
        return alignedBox(range: range, pageText: pageText, near: box, tokens: tokens, model: &model)
    }

    /// The line's drift as the alignment reads it: the first and last letters
    /// of the layer's line that land on the same letter read (their indices
    /// in the page text), and where along the read row they lie (points).
    struct InkLineModel {
        /// The agreeing letters in line order: each one's index in the page
        /// text and its place along the read row (points).
        let letters: [(text: Int, read: CGFloat)]
        /// The match is the same occurrence of its text, counted along the
        /// aligned stretch, in the layer and in the read row, and both hold
        /// it as often.
        let sameOrdinal: Bool
    }

    /// `alignedBox`, and in `model` the line's drift it read.
    nonisolated static func alignedBox(range: NSRange, pageText: NSString, near box: CGRect, tokens: [InkToken],
                                       model: inout InkLineModel?)
        -> (rect: CGRect, growLeft: Bool, growRight: Bool, whole: CGRect?, cuts: [InkCut])? {
        guard range.location >= 0, range.length > 0, NSMaxRange(range) <= pageText.length else { return nil }
        let lineRange = pageText.lineRange(for: range)
        let before = pageText.substring(with: NSRange(location: lineRange.location, length: range.location - lineRange.location))
        let lineKey = Array(alignmentKey(Substring(pageText.substring(with: lineRange))))
        let start = alignmentKey(Substring(before)).count
        let length = alignmentKey(Substring(pageText.substring(with: range))).count
        guard length > 0, start + length <= lineKey.count else { return nil }

        // The read rows near the box: Vision's lines on its band, those at one
        // height joined left to right (a table row the layer wrote as one line,
        // read as several), lines at different heights kept apart (tight
        // leading puts the next line within reach). The row whose letters
        // agree most with the layer's line is the one.
        let reach = max(box.height, 4)
        var lines: [Int: [InkToken]] = [:]
        for token in tokens where abs(token.rect.midY - box.midY) <= reach { lines[token.line, default: []].append(token) }
        var rows: [[InkToken]] = []
        for line in lines.values.sorted(by: { $0[0].rect.midY > $1[0].rect.midY }) {
            let mid = line.map(\.rect.midY).reduce(0, +) / CGFloat(line.count)
            let height = line.map(\.rect.height).max() ?? 0
            if let i = rows.firstIndex(where: { row in
                abs(row.map(\.rect.midY).reduce(0, +) / CGFloat(row.count) - mid) <= 0.35 * height
            }) { rows[i] += line } else { rows.append(line) }
        }
        var best: (row: [InkToken], readKey: [Character], map: [Int], score: Int)?
        for unsorted in rows {
            let row = unsorted.sorted { $0.rect.minX < $1.rect.minX }
            let readKey = Array(row.map(\.key).joined())
            guard !readKey.isEmpty else { continue }
            let (map, score) = align(lineKey, readKey)
            if best == nil || score > best!.score { best = (row, readKey, map, score) }
        }
        guard let best else { return nil }
        let (row, readKey, map, score) = best
        // Most of the shorter of the two lines agrees (the layer may have
        // joined a cell's wrapped lines that Vision reads apart), and every
        // letter of the match lands on the same letter read.
        guard score * 2 >= min(lineKey.count, readKey.count) else { return nil }
        for k in start..<(start + length) {
            let j = map[k]
            guard j >= 0, j < readKey.count, readKey[j] == lineKey[k] else { return nil }
        }
        let first = map[start], last = map[start + length - 1]
        guard last >= first else { return nil }
        // The line's model: its first and last agreeing letters, in the text
        // and along the row (a letter's place in its token by share).
        let agreeing = (0..<lineKey.count).filter { map[$0] >= 0 && map[$0] < readKey.count && readKey[map[$0]] == lineKey[$0] }
        if let k0 = agreeing.first, let k1 = agreeing.last, k1 > k0 {
            var textIndex: [Int] = []
            let line = pageText.substring(with: lineRange) as NSString
            var offset16 = 0
            for character in String(line) {
                let width = String(character).utf16.count
                textIndex += Array(repeating: lineRange.location + offset16, count: alignmentKey(Substring(String(character))).count)
                offset16 += width
            }
            func readX(_ j: Int) -> CGFloat? {
                var at = 0
                for token in row {
                    let n = token.key.count
                    if j < at + n, n > 0 { return token.rect.minX + (CGFloat(j - at) + 0.5) * token.rect.width / CGFloat(n) }
                    at += n
                }
                return nil
            }
            // The match's place among the same text along the aligned stretch.
            func occurrences(_ key: [Character], of word: ArraySlice<Character>, in span: ClosedRange<Int>, before limit: Int)
                -> (total: Int, before: Int) {
                guard !word.isEmpty, span.lowerBound >= 0, span.upperBound < key.count else { return (0, 0) }
                var total = 0, before = 0, i = span.lowerBound
                while i + word.count - 1 <= span.upperBound {
                    if key[i..<(i + word.count)].elementsEqual(word) { total += 1; if i < limit { before += 1 } }
                    i += 1
                }
                return (total, before)
            }
            let word = lineKey[start..<(start + length)]
            let layerSpan = min(k0, start)...max(k1, start + length - 1)
            let readSpan = min(map[k0], first)...max(map[k1], last)
            let inLayer = occurrences(lineKey, of: word, in: layerSpan, before: start)
            let inRead = occurrences(readKey, of: word, in: readSpan, before: first)
            let letters = agreeing.compactMap { k -> (text: Int, read: CGFloat)? in
                guard k < textIndex.count, let x = readX(map[k]) else { return nil }
                return (textIndex[k], x)
            }
            model = InkLineModel(letters: letters,
                                 sameOrdinal: inLayer.total == inRead.total && inLayer.before == inRead.before)
        }
        var offset = 0
        var found: CGRect?
        var growLeft = true, growRight = true
        var cuts: [InkCut] = []
        var whole: CGRect?
        for token in row {
            let n = token.key.count
            defer { offset += n }
            let lo = max(first, offset), hi = min(last, offset + n - 1)
            guard n > 0, lo <= hi else { continue }
            if hi - lo + 1 == n {
                found = found.map { $0.union(token.rect) } ?? token.rect
                whole = whole.map { $0.union(token.rect) } ?? token.rect
                continue
            }
            if lo > offset { growLeft = false }
            if hi < offset + n - 1 { growRight = false }
            if token.keyToRaw.count == n {
                cuts.append(InkCut(token: token, rawLo: token.keyToRaw[lo - offset], rawHi: token.keyToRaw[hi - offset]))
            }
            let unit = token.rect.width / CGFloat(n)
            let x0 = max(token.rect.minX, token.rect.minX + CGFloat(lo - offset) * unit - unit)
            let x1 = min(token.rect.maxX, token.rect.minX + CGFloat(hi - offset + 1) * unit + unit)
            let cut = CGRect(x: x0, y: token.rect.minY, width: x1 - x0, height: token.rect.height)
            found = found.map { $0.union(cut) } ?? cut
        }
        // A word cannot be read wider than its selection by more than a line
        // height on each side (a misalignment across a row would be).
        guard let found, found.width <= box.width + 2 * reach + 4 * box.height else { return nil }
        return (found, growLeft, growRight, whole, cuts)
    }

    /// An edit-distance alignment of `a` onto a stretch of `b` (free gaps at
    /// both ends of `b`: a read row may hold more than the layer's line): for
    /// each letter of `a`, the letter of `b` it lands on (a dropped letter
    /// takes its left neighbour's, or -1 at the start), and the count of
    /// agreeing letters.
    nonisolated static func align(_ a: [Character], _ b: [Character]) -> (map: [Int], score: Int) {
        let n = a.count, m = b.count
        var cost = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { cost[i][0] = i }
        if n > 0, m > 0 {
            for i in 1...n { for j in 1...m {
                cost[i][j] = min(cost[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1), cost[i - 1][j] + 1, cost[i][j - 1] + 1)
            } }
        }
        var map = [Int](repeating: -1, count: n)
        var score = 0
        var i = n
        var j = (0...m).min { cost[n][$0] < cost[n][$1] } ?? 0
        while i > 0, j > 0 {
            if cost[i][j] == cost[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1) {
                map[i - 1] = j - 1
                if a[i - 1] == b[j - 1] { score += 1 }
                i -= 1; j -= 1
            } else if cost[i][j] == cost[i - 1][j] + 1 { i -= 1 } else { j -= 1 }
        }
        var last = -1
        for k in 0..<n { if map[k] >= 0 { last = map[k] } else { map[k] = last } }
        return (map, score)
    }
}
