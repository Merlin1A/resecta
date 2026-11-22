import Foundation

/// The information dictionary found through the file's own index.
///
/// A pure function from a file's bytes to the byte range of its information
/// dictionary and of the trailer that names it, or to a named refusal. It
/// follows the file's index: the last `startxref`, the classic
/// cross-reference table it points at, the trailer's `/Info` reference, that
/// object's entry in the table, and the object at that offset. It reads only
/// a classic table and an uncompressed object, and refuses everything else
/// with its reason; nothing is guessed. A refusal never fails an export: the
/// caller then searches the file's tail as before.
enum PDFTrailerLocator {

    /// What the index names.
    struct Found: Equatable, Sendable {
        /// The information dictionary, from its `<<` through its `>>`.
        let dictionary: Range<Int>
        /// The trailer dictionary that names it, from its `<<` through its `>>`.
        let trailer: Range<Int>
    }

    enum Outcome: Equatable, Sendable {
        case found(Found)
        case refused(RunRecord.IndexRefusal)
    }

    /// The longest information dictionary read, from its `<<` to its `>>`.
    static let dictionaryLimit = 4_096

    /// How far back from the end of the file the last `startxref` is looked for.
    static let startxrefWindow = 1_024

    /// The deepest nesting of dictionaries and arrays read inside a value.
    static let nestingLimit = 32

    /// The ranges are offsets from the start of `data`.
    static func locate(in data: Data) -> Outcome {
        // A mapped file is read in place; a slice is copied once so that its
        // offsets count from zero.
        Reader(data.startIndex == 0 ? data : Data(data)).locate()
    }

    // MARK: - The reader

    private struct Reader {
        let b: Data
        init(_ bytes: Data) { b = bytes }

        func locate() -> Outcome {
            // The last `startxref` and the offset after it.
            guard let sx = lastIndex(of: Array("startxref".utf8), from: max(0, b.count - PDFTrailerLocator.startxrefWindow)) else {
                return .refused(.indexUnreadable)
            }
            var i = skipSpace(sx + 9)
            guard let (offset, afterOffset) = integer(at: i), afterOffset > i, offset < b.count else {
                return .refused(.indexUnreadable)
            }
            i = offset
            // A classic table starts with `xref`; an object there is a
            // cross-reference stream.
            guard matches("xref", at: i) else {
                if objectHeader(at: i) != nil { return .refused(.crossReferenceStream) }
                return .refused(.indexUnreadable)
            }
            i = skipSpace(i + 4)
            var entries: [Int: (offset: Int, generation: Int, inUse: Bool)] = [:]
            while !matches("trailer", at: i) {
                guard let (first, a) = integer(at: i), let (count, c) = integer(at: skipSpace(a)) else {
                    return .refused(.indexUnreadable)
                }
                i = skipSpace(c)
                for n in 0..<count {
                    // nnnnnnnnnn ggggg n|f, then a two-byte end of line.
                    guard i + 18 <= b.count, let (off, o) = integer(at: i), o - i == 10,
                          b[o] == 0x20, let (gen, g) = integer(at: o + 1), g - o - 1 == 5,
                          b[g] == 0x20, b[g + 1] == 0x6E || b[g + 1] == 0x66 else {
                        return .refused(.indexUnreadable)
                    }
                    entries[first + n] = (off, gen, b[g + 1] == 0x6E)
                    i = skipSpace(g + 2)
                }
            }
            // The trailer dictionary.
            i = skipSpace(i + 7)
            guard let trailer = dictionary(at: i, limit: nil) else { return .refused(.indexUnreadable) }
            guard trailer.keys.count == Set(trailer.keys.map { $0.name }).count else { return .refused(.indexUnreadable) }
            if trailer.value(of: "Prev") != nil { return .refused(.previousSection) }
            if trailer.value(of: "XRefStm") != nil { return .refused(.crossReferenceStream) }
            guard let info = trailer.value(of: "Info") else { return .refused(.noInfoEntry) }
            guard let (number, generation) = reference(info) else { return .refused(.noInfoEntry) }
            // The table's entry for it, in use, of the generation named.
            guard let entry = entries[number], entry.inUse else { return .refused(.entryNotInUse) }
            guard entry.generation == generation, entry.offset < b.count,
                  let header = objectHeader(at: entry.offset), header.number == number,
                  header.generation == generation else {
                return .refused(.wrongObjectHeader)
            }
            let start = skipSpace(header.end)
            guard matches("<<", at: start) else { return .refused(.wrongObjectHeader) }
            guard let dict = dictionary(at: start, limit: PDFTrailerLocator.dictionaryLimit) else {
                return .refused(.dictionaryNotClosed)
            }
            if dict.keys.count != Set(dict.keys.map { $0.name }).count { return .refused(.repeatedKey) }
            return .found(Found(dictionary: dict.range, trailer: trailer.range))
        }

        // MARK: Tokens

        struct Token {
            enum Kind { case name, string, open, close, arrayOpen, arrayClose, other }
            let kind: Kind
            let range: Range<Int>
        }

        struct Dictionary {
            let range: Range<Int>
            /// Each key's name (without the slash) and its value's tokens.
            let keys: [(name: String, value: [Token])]
            func value(of name: String) -> [Token]? { keys.first { $0.name == name }?.value }
        }

        static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x0C || c == 0x00 }
        static func isDelimiter(_ c: UInt8) -> Bool { "()<>[]{}/%".utf8.contains(c) }

        func skipSpace(_ start: Int) -> Int {
            var i = start
            while i < b.count {
                if Self.isSpace(b[i]) { i += 1; continue }
                if b[i] == 0x25 { while i < b.count && b[i] != 0x0A && b[i] != 0x0D { i += 1 }; continue }  // comment
                break
            }
            return i
        }

        func matches(_ s: String, at i: Int) -> Bool {
            let w = Array(s.utf8)
            return i >= 0 && i + w.count <= b.count && b[i..<i + w.count].elementsEqual(w)
        }

        func lastIndex(of word: [UInt8], from lower: Int) -> Int? {
            var i = b.count - word.count
            while i >= lower {
                if b[i..<i + word.count].elementsEqual(word) { return i }
                i -= 1
            }
            return nil
        }

        /// A run of decimal digits at `i`: its value and the index after it.
        func integer(at i: Int) -> (Int, Int)? {
            var j = i, v = 0
            while j < b.count, b[j] >= 0x30, b[j] <= 0x39, j - i < 18 { v = v * 10 + Int(b[j] - 0x30); j += 1 }
            return j > i ? (v, j) : nil
        }

        /// `n g obj` at `i`: the numbers and the index after `obj`.
        func objectHeader(at i: Int) -> (number: Int, generation: Int, end: Int)? {
            guard let (n, a) = integer(at: i), a < b.count, Self.isSpace(b[a]),
                  let (g, c) = integer(at: skipSpace(a)), c < b.count, Self.isSpace(b[c]) else { return nil }
            let o = skipSpace(c)
            guard matches("obj", at: o) else { return nil }
            return (n, g, o + 3)
        }

        /// `n g R` as a value's tokens.
        func reference(_ value: [Token]) -> (Int, Int)? {
            guard value.count == 3, value[2].kind == .other, b[value[2].range].elementsEqual([0x52]),
                  let (n, a) = integer(at: value[0].range.lowerBound), a == value[0].range.upperBound,
                  let (g, c) = integer(at: value[1].range.lowerBound), c == value[1].range.upperBound else { return nil }
            return (n, g)
        }

        /// The token at `start` (after any space), or nil at the end.
        func token(at start: Int) -> Token? {
            let i = skipSpace(start)
            guard i < b.count else { return nil }
            switch b[i] {
            case 0x3C where i + 1 < b.count && b[i + 1] == 0x3C: return Token(kind: .open, range: i..<i + 2)
            case 0x3E where i + 1 < b.count && b[i + 1] == 0x3E: return Token(kind: .close, range: i..<i + 2)
            case 0x3C:  // hex string
                var j = i + 1
                while j < b.count && b[j] != 0x3E { j += 1 }
                return j < b.count ? Token(kind: .string, range: i..<j + 1) : nil
            case 0x28:  // literal string: escapes and balanced parentheses
                var j = i + 1, depth = 1
                while j < b.count {
                    if b[j] == 0x5C { j += 2; continue }
                    if b[j] == 0x28 { depth += 1 } else if b[j] == 0x29 { depth -= 1; if depth == 0 { break } }
                    j += 1
                }
                return j < b.count ? Token(kind: .string, range: i..<j + 1) : nil
            case 0x5B: return Token(kind: .arrayOpen, range: i..<i + 1)
            case 0x5D: return Token(kind: .arrayClose, range: i..<i + 1)
            case 0x2F:  // name
                var j = i + 1
                while j < b.count && !Self.isSpace(b[j]) && !Self.isDelimiter(b[j]) { j += 1 }
                return Token(kind: .name, range: i..<j)
            case 0x3E, 0x29, 0x7B, 0x7D:
                return nil
            default:
                var j = i
                while j < b.count && !Self.isSpace(b[j]) && !Self.isDelimiter(b[j]) { j += 1 }
                return j > i ? Token(kind: .other, range: i..<j) : nil
            }
        }

        /// One value starting at `start`: its tokens and the index after it.
        /// A nested dictionary or array is one value; `n g R` is one value.
        func value(at start: Int, end: Int, depth: Int) -> ([Token], Int)? {
            guard depth < PDFTrailerLocator.nestingLimit, let t = token(at: start), t.range.upperBound <= end else { return nil }
            switch t.kind {
            case .open:
                guard let d = dictionary(at: t.range.lowerBound, limit: end - t.range.lowerBound, depth: depth + 1) else { return nil }
                return ([Token(kind: .other, range: d.range)], d.range.upperBound)
            case .arrayOpen:
                var i = t.range.upperBound
                while let n = token(at: i), n.kind != .arrayClose {
                    guard let (_, after) = value(at: i, end: end, depth: depth + 1) else { return nil }
                    i = after
                }
                guard let close = token(at: i), close.range.upperBound <= end else { return nil }
                return ([Token(kind: .other, range: t.range.lowerBound..<close.range.upperBound)], close.range.upperBound)
            case .close, .arrayClose:
                return nil
            case .other:
                // `n g R`: two integers and R.
                if let g = token(at: t.range.upperBound), g.kind == .other,
                   let r = token(at: g.range.upperBound), r.kind == .other, b[r.range].elementsEqual([0x52]),
                   r.range.upperBound <= end {
                    return ([t, g, r], r.range.upperBound)
                }
                return ([t], t.range.upperBound)
            case .name, .string:
                return ([t], t.range.upperBound)
            }
        }

        /// The dictionary whose `<<` is at `start`, closing within `limit`
        /// bytes of it when a limit is given.
        func dictionary(at start: Int, limit: Int?, depth: Int = 0) -> Dictionary? {
            guard matches("<<", at: start) else { return nil }
            let end = limit.map { min(b.count, start + $0) } ?? b.count
            var keys: [(name: String, value: [Token])] = []
            var i = start + 2
            while true {
                guard let t = token(at: i), t.range.upperBound <= end else { return nil }
                if t.kind == .close { return Dictionary(range: start..<t.range.upperBound, keys: keys) }
                guard t.kind == .name, let (v, after) = value(at: t.range.upperBound, end: end, depth: depth) else { return nil }
                keys.append((String(decoding: b[t.range.lowerBound + 1..<t.range.upperBound], as: UTF8.self), v))
                i = after
            }
        }
    }
}
