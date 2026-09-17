import Foundation

// Context-sensitive OCR character substitution. Runs against cached
// Vision output in DocumentSearcher before PII detection; never re-OCRs.
//
// Classification operates at three levels:
//
// 1. **Token level** (primary). Each maximal alphanumeric token is examined
//    in isolation. Characters that are *unambiguous* (letters not in the
//    digit-confusable set; digits not in the letter-confusable set) provide
//    the signal. If a token has ≥1 clear digit and 0 clear letters, it's
//    digit context; vice versa for letter context.
//
// 2. **Run level** (digit groups). Tokens that carry no clear letter and are
//    linked only through the separators digit groups use — "-", ".", "/",
//    "(", ")" and whitespace — form a run. If any token in the run carries a
//    clear digit, every token in the run is digit context. This keeps a
//    labelled phone, card or date line intact: "Home Phone: (208) 555-0147"
//    is letter-majority as a line, but "555" sits in the run
//    "208 / 555 / 0147" whose neighbours carry clear digits, so it stays
//    "555" rather than becoming "SSS". The context carries across the whole
//    run ("4111 1111 1111 1111": only the first group has a clear digit). A
//    token with a clear letter never joins a run, so a mixed identifier
//    keeps its token-level decision.
//
// 3. **Line level** (fallback). Tokens composed entirely of ambiguous
//    characters (e.g., "1OO", "0IB") that belong to no digit run inherit the
//    line's overall tendency — the same clear-digit vs clear-letter majority
//    counted across the whole line. If the line has no clear chars of either
//    kind, the token passes through without substitution (no signal, no
//    guess). A lone all-ambiguous group on a letter-majority line ("Suite
//    100") therefore still resolves to letter context.
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

    /// Separators that link the groups of one digit run (phone, card, date
    /// and account shapes). Any other character between two tokens ends the
    /// run; whitespace links as a space does.
    private static let runSeparators: Set<Character> = [
        "-", ".", "/", "(", ")",
    ]

    private enum Context {
        case digit
        case letter
        case passthrough
    }

    /// The run-level class of one token: whether it carries a clear letter
    /// (never part of a run), a clear digit and no clear letter (anchors a
    /// run), or neither (joins a run and takes its context).
    private enum TokenClass {
        case clearLetter
        case clearDigit
        case ambiguous
    }

    init() {}

    /// Normalize one OCR line. Non-alphanumeric characters are preserved
    /// byte-for-byte; alphanumeric tokens are each classified and substituted.
    func normalize(_ line: String) -> String {
        guard !line.isEmpty else { return line }

        let lineTendency = Self.lineTendency(of: line)
        let digitRunMarks = Self.digitRunMarks(of: line)

        var output = String()
        output.reserveCapacity(line.count)
        var tokenBuffer: [Character] = []
        var tokenIndex = 0

        for char in line {
            if char.isLetter || char.isNumber {
                tokenBuffer.append(char)
            } else {
                if !tokenBuffer.isEmpty {
                    flushToken(
                        &tokenBuffer, into: &output, lineTendency: lineTendency,
                        inDigitRun: Self.mark(digitRunMarks, at: tokenIndex))
                    tokenIndex += 1
                }
                output.append(char)
            }
        }
        if !tokenBuffer.isEmpty {
            flushToken(
                &tokenBuffer, into: &output, lineTendency: lineTendency,
                inDigitRun: Self.mark(digitRunMarks, at: tokenIndex))
        }
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

    private static func mark(_ marks: [Bool], at index: Int) -> Bool {
        index < marks.count && marks[index]
    }

    /// Run level. Walks the line once to class every alphanumeric token (in
    /// line order) and to note whether the separator text before it links it
    /// to the previous token, then marks every token of each run that
    /// carries a clear-digit token. Returns one flag per token.
    private static func digitRunMarks(of line: String) -> [Bool] {
        var classes: [TokenClass] = []
        var linkedToPrevious: [Bool] = []
        var inToken = false
        var clearDigits = 0
        var clearLetters = 0
        var separatorLinks = true

        func closeToken() {
            let tokenClass: TokenClass
            if clearLetters > 0 {
                tokenClass = .clearLetter
            } else if clearDigits > 0 {
                tokenClass = .clearDigit
            } else {
                tokenClass = .ambiguous
            }
            classes.append(tokenClass)
            inToken = false
            separatorLinks = true
        }

        for c in line {
            if c.isLetter || c.isNumber {
                if !inToken {
                    inToken = true
                    clearDigits = 0
                    clearLetters = 0
                    linkedToPrevious.append(separatorLinks && !classes.isEmpty)
                }
                if c.isNumber, !ambiguousDigits.contains(c) {
                    clearDigits += 1
                } else if c.isLetter, !ambiguousLetters.contains(c) {
                    clearLetters += 1
                }
            } else {
                if inToken { closeToken() }
                if !(runSeparators.contains(c) || c.isWhitespace) {
                    separatorLinks = false
                }
            }
        }
        if inToken { closeToken() }

        var marks = [Bool](repeating: false, count: classes.count)
        var runStart = 0
        var runHasClearDigit = false

        func closeRun(endingBefore end: Int) {
            if runHasClearDigit, runStart < end {
                for i in runStart..<end { marks[i] = true }
            }
            runHasClearDigit = false
        }

        for i in classes.indices {
            if classes[i] == .clearLetter {
                // A clear-letter token is never part of a run and ends the
                // one before it.
                closeRun(endingBefore: i)
                runStart = i + 1
                continue
            }
            if i > runStart, !linkedToPrevious[i] {
                closeRun(endingBefore: i)
                runStart = i
            }
            if classes[i] == .clearDigit { runHasClearDigit = true }
        }
        closeRun(endingBefore: classes.count)
        return marks
    }

    private func flushToken(
        _ buffer: inout [Character],
        into output: inout String,
        lineTendency: Context,
        inDigitRun: Bool
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
        } else if inDigitRun {
            // Ambig-only token inside a digit run: the run's clear-digit
            // neighbour decides before the line-level fallback.
            context = .digit
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
