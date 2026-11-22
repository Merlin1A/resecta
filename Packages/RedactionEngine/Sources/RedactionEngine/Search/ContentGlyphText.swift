import Foundation

/// The text of a glyph by its name: a fixed table of the names the base
/// encodings use for printable ASCII, the f-ligatures, and the `uniXXXX` and
/// `uXXXX` forms. Any other name has no text here (the page is then not
/// mapped, never guessed).
enum GlyphNames {
    static func text(_ name: String) -> String? {
        if let text = table[name] { return text }
        if name.count == 1, let scalar = name.unicodeScalars.first, scalar.isASCII,
           scalar.properties.isAlphabetic { return name }
        if name.hasPrefix("uni"), name.count == 7, let value = UInt32(name.dropFirst(3), radix: 16),
           let scalar = Unicode.Scalar(value) { return String(scalar) }
        if name.hasPrefix("u"), (5...7).contains(name.count), let value = UInt32(name.dropFirst(1), radix: 16),
           let scalar = Unicode.Scalar(value) { return String(scalar) }
        return nil
    }

    static let table: [String: String] = [
        "space": " ", "exclam": "!", "quotedbl": "\"", "numbersign": "#", "dollar": "$", "percent": "%",
        "ampersand": "&", "quotesingle": "'", "quoteright": "\u{2019}", "quoteleft": "\u{2018}",
        "parenleft": "(", "parenright": ")", "asterisk": "*", "plus": "+", "comma": ",", "hyphen": "-",
        "period": ".", "slash": "/", "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
        "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9", "colon": ":", "semicolon": ";",
        "less": "<", "equal": "=", "greater": ">", "question": "?", "at": "@", "bracketleft": "[",
        "backslash": "\\", "bracketright": "]", "asciicircum": "^", "underscore": "_", "grave": "`",
        "braceleft": "{", "bar": "|", "braceright": "}", "asciitilde": "~",
        "fi": "fi", "fl": "fl", "ff": "ff", "ffi": "ffi", "ffl": "ffl",
    ]
}

/// A ToUnicode map for one-byte codes: its `bfchar` and `bfrange` entries.
/// Any other entry, a source wider than one byte, or a line it cannot read
/// makes the whole map unread.
enum ToUnicode {
    static func parse(_ data: Data) -> [Int: String]? {
        guard let text = String(data: data, encoding: .isoLatin1) else { return nil }
        var map: [Int: String] = [:]
        var tokens = Tokens(text)
        while let token = tokens.next() {
            switch token {
            case "beginbfchar":
                while let source = tokens.next(), source != "endbfchar" {
                    guard let code = byte(source), let target = tokens.next(), let string = utf16(target) else { return nil }
                    map[code] = string
                }
            case "beginbfrange":
                while let low = tokens.next(), low != "endbfrange" {
                    guard let first = byte(low), let highToken = tokens.next(), let last = byte(highToken),
                          first <= last, let target = tokens.next() else { return nil }
                    if target == "[" {
                        for code in first...last {
                            guard let entry = tokens.next(), let string = utf16(entry) else { return nil }
                            map[code] = string
                        }
                        guard tokens.next() == "]" else { return nil }
                    } else {
                        guard var units = units(target), !units.isEmpty else { return nil }
                        for code in first...last {
                            guard let string = String(utf16CodeUnits: units, count: units.count) as String? else { return nil }
                            map[code] = string
                            units[units.count - 1] &+= 1
                        }
                    }
                }
            case "begincidchar", "begincidrange", "beginnotdefchar", "beginnotdefrange":
                return nil
            case "begincodespacerange":
                while let low = tokens.next(), low != "endcodespacerange" {
                    guard byte(low) != nil, let high = tokens.next(), byte(high) != nil else { return nil }
                }
            default:
                continue
            }
        }
        return map
    }

    /// A one-byte hex source, `<41>`.
    static func byte(_ token: String) -> Int? {
        guard token.hasPrefix("<"), token.hasSuffix(">"), token.count == 4 else { return nil }
        return Int(token.dropFirst().dropLast(), radix: 16)
    }

    static func units(_ token: String) -> [UInt16]? {
        guard token.hasPrefix("<"), token.hasSuffix(">") else { return nil }
        let hex = token.dropFirst().dropLast().filter { !$0.isWhitespace }
        guard hex.count % 4 == 0, !hex.isEmpty else { return nil }
        var out: [UInt16] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 4)
            guard let unit = UInt16(hex[index..<next], radix: 16) else { return nil }
            out.append(unit)
            index = next
        }
        return out
    }

    static func utf16(_ token: String) -> String? {
        units(token).map { String(utf16CodeUnits: $0, count: $0.count) }
    }

    /// Whitespace-separated tokens; `<...>` (which may hold spaces), `[`
    /// and `]` are tokens of their own; comments are skipped.
    struct Tokens {
        private let scalars: [Character]
        private var index = 0
        init(_ text: String) { scalars = Array(text) }

        mutating func next() -> String? {
            while index < scalars.count {
                let c = scalars[index]
                if c == "%" {
                    while index < scalars.count, scalars[index] != "\n", scalars[index] != "\r" { index += 1 }
                } else if c.isWhitespace {
                    index += 1
                } else {
                    break
                }
            }
            guard index < scalars.count else { return nil }
            let c = scalars[index]
            if c == "[" || c == "]" { index += 1; return String(c) }
            if c == "<" {
                var out = ""
                while index < scalars.count {
                    let d = scalars[index]; out.append(d); index += 1
                    if d == ">" { break }
                }
                return out
            }
            var out = ""
            while index < scalars.count {
                let d = scalars[index]
                if d.isWhitespace || d == "[" || d == "]" || d == "<" || d == "%" { break }
                out.append(d); index += 1
            }
            return out
        }
    }
}
