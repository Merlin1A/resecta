import Foundation

// Context-sensitive OCR character substitution. Runs against cached
// Vision output in DocumentSearcher before PII detection; never re-OCRs.
//
// Classification operates at two levels:
//
// 1. **Token level** (primary). Each maximal alphanumeric token is examined
//    in isolation. Characters that are *unambiguous* (letters not in the
//    digit-confusable set; digits not in the letter-confusable set) provide
//    the signal. If a token has ≥1 clear digit and 0 clear letters, it's
//    digit context; vice versa for letter context.
//
// 2. **Line level** (fallback). Tokens composed entirely of ambiguous
//    characters (e.g., "1OO", "0IB") inherit the line's overall tendency —
//    the same clear-digit vs clear-letter majority counted across the whole
//    line. If the line has no clear chars of either kind, the token passes
//    through without substitution (no signal, no guess).
//
// This handles "1OO-23-4567" (ambig token inherits digit context from its
// digit-majority line) and "SW-2026" (letter token decides at token level
// independent of line tendency) correctly. Confusables are hardcoded per the
// plan; DataPipeline has not shipped a schema for this table.

struct OCRTextNormalizer: Sendable {

    /// Letters Vision commonly emits when the source glyph was a digit.
    /// Applied to tokens that resolve to digit context.
    static let digitContextMap: [Character: Character] = [
        "O": "0", "o": "0",
        "I": "1", "l": "1",
        "B": "8",
        "S": "5",
        "Z": "2",
        "G": "6",
    ]

    /// Digits Vision commonly emits when the source glyph was a letter.
    /// Applied to tokens that resolve to letter context.
    static let letterContextMap: [Character: Character] = [
        "0": "O",
        "1": "I",
        "5": "S",
        "8": "B",
    ]

    /// Letters that are visually confusable with digits; not counted as
    /// clear-letter signal during classification.
    private static let ambiguousLetters: Set<Character> = [
        "O", "o", "I", "l", "B", "S", "Z", "G",
    ]

    /// Digits that are visually confusable with letters; not counted as
    /// clear-digit signal during classification.
    private static let ambiguousDigits: Set<Character> = [
        "0", "1", "5", "8",
    ]

    private enum Context {
        case digit
        case letter
        case passthrough
    }

    init() {}

    /// Normalize one OCR line. Non-alphanumeric characters are preserved
    /// byte-for-byte; alphanumeric tokens are each classified and substituted.
    func normalize(_ line: String) -> String {
        guard !line.isEmpty else { return line }

        let lineTendency = Self.lineTendency(of: line)

        var output = String()
        output.reserveCapacity(line.count)
        var tokenBuffer: [Character] = []

        for char in line {
            if char.isLetter || char.isNumber {
                tokenBuffer.append(char)
            } else {
                flushToken(&tokenBuffer, into: &output, lineTendency: lineTendency)
                output.append(char)
            }
        }
        flushToken(&tokenBuffer, into: &output, lineTendency: lineTendency)
        return output
    }

    // MARK: - Classification

    private static func lineTendency(of line: String) -> Context {
        var clearDigits = 0
        var clearLetters = 0
        for c in line {
            if c.isNumber, !ambiguousDigits.contains(c) {
                clearDigits += 1
            } else if c.isLetter, !ambiguousLetters.contains(c) {
                clearLetters += 1
            }
        }
        if clearDigits > clearLetters { return .digit }
        if clearLetters > clearDigits { return .letter }
        return .passthrough
    }

    private func flushToken(
        _ buffer: inout [Character],
        into output: inout String,
        lineTendency: Context
    ) {
        guard !buffer.isEmpty else { return }

        var tokenClearDigits = 0
        var tokenClearLetters = 0
        for c in buffer {
            if c.isNumber, !Self.ambiguousDigits.contains(c) {
                tokenClearDigits += 1
            } else if c.isLetter, !Self.ambiguousLetters.contains(c) {
                tokenClearLetters += 1
            }
        }

        let context: Context
        if tokenClearDigits > tokenClearLetters {
            context = .digit
        } else if tokenClearLetters > tokenClearDigits {
            context = .letter
        } else {
            // Ambig-only token: inherit from line. Passthrough if the line
            // also lacks clear signal — we don't guess in the dark.
            context = lineTendency
        }

        switch context {
        case .digit:
            for c in buffer { output.append(Self.digitContextMap[c] ?? c) }
        case .letter:
            for c in buffer { output.append(Self.letterContextMap[c] ?? c) }
        case .passthrough:
            output.append(contentsOf: buffer)
        }
        buffer.removeAll(keepingCapacity: true)
    }
}
