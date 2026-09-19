import Foundation

/// The nested-quantifier scan behind `DocumentSearcher.validateRegexPatternWithError`.
///
/// Tokenizes the pattern with the same escape and `[...]` skipping the
/// safety precheck uses, then classifies every quantifier by the bound it
/// places on repetition:
///
///   - **bounded** — `?`, `{n}`, `{n,m}` with m ≤ `boundedCeiling`
///   - **unbounded** — `*`, `+`, `{n,}`, and `{n,m}` with m > `boundedCeiling`
///
/// and applies three rules:
///
///   1. A group closed by a **bounded** quantifier never counts as nesting
///      — `(-\d{4})?`, `(\.\d{2})?`, `4111(\s?\d{4}){3}` are the optional
///      suffixes and grouped digits users write, and they run in linear
///      time.
///   2. A group closed by an **unbounded** quantifier counts as nesting iff
///      the group itself contains an unbounded quantifier — `(x+)+`,
///      `(.*)*`, `(a{2,})*`: the exponential backtracking shape.
///   3. Along any nesting chain of bounded quantifiers, the product of the
///      maxima must not exceed `productCap` — `(a{0,40}){0,40}` explores up
///      to 1,600 repetitions although every bound is small. Quantifiers
///      stacked on one atom (`a{0,40}{0,40}`) form the same chain.
///
/// With `literalSeparatorDemotion` on, rule 2 ignores an inner unbounded
/// run that is delimited inside its group by a literal character the run
/// cannot match (`\.` beside `\d+`, a space after `[a-z]+`): the literal
/// fixes every iteration boundary, so the shape is at worst polynomial —
/// the class the runtime sentinel probe backstops, not this scan's.
///
/// The scan is a structural heuristic: it reads the pattern text, never
/// the engine's compiled form, and errs on the side of refusing.
enum RegexQuantifierScan {

    /// Why a pattern's quantifier structure was refused.
    enum Violation: Equatable {
        /// An unbounded quantifier over a group (or an atom) that itself
        /// carries an unbounded quantifier.
        case nestedUnbounded
        /// A chain of bounded quantifiers whose product of maxima exceeds
        /// the cap.
        case nestedBoundProduct
    }

    static func violation(
        in pattern: String,
        boundedCeiling: Int,
        productCap: Int,
        literalSeparatorDemotion: Bool
    ) -> Violation? {
        let tokens = tokenize(Array(pattern))
        return evaluate(
            tokens, boundedCeiling: boundedCeiling, productCap: productCap,
            literalSeparatorDemotion: literalSeparatorDemotion)
    }

    /// True when the pattern carries the rule-2 shape (an unbounded
    /// quantifier over an unbounded run that no literal separates). The
    /// safety precheck's nested-quantifier rule defers to this so the two
    /// readings of the shape cannot drift.
    static func hasNestedUnbounded(_ pattern: String, boundedCeiling: Int, literalSeparatorDemotion: Bool) -> Bool {
        let tokens = tokenize(Array(pattern))
        return evaluate(
            tokens, boundedCeiling: boundedCeiling, productCap: Int.max,
            literalSeparatorDemotion: literalSeparatorDemotion) == .nestedUnbounded
    }

    // MARK: - Tokens

    fileprivate struct Quantifier {
        enum Form { case star, plus, openBrace, exact, range, question }
        let form: Form
        /// The bounded forms' maximum: `?` → 1, `{n}` → n, `{n,m}` → m.
        /// nil for `*`, `+`, `{n,}`.
        let max: Int?

        func countsAsUnbounded(ceiling: Int) -> Bool {
            switch form {
            case .star, .plus, .openBrace: return true
            case .range: return (max ?? 0) > ceiling
            case .exact, .question: return false
            }
        }
    }

    fileprivate struct CharClass {
        var negated = false
        var singles: [Character] = []
        var ranges: [ClosedRange<UInt32>] = []
        var shorthands: [Atom] = []

        func contains(_ c: Character) -> Bool {
            var inside = false
            if shorthands.contains(where: { $0.canMatch(c) }) { inside = true }
            if !inside, singles.contains(where: { Atom.sameIgnoringCase($0, c) }) { inside = true }
            if !inside {
                let variants = [c, Character(c.lowercased()), Character(c.uppercased())]
                    .filter { $0.unicodeScalars.count == 1 }
                    .map { $0.unicodeScalars.first!.value }
                if ranges.contains(where: { r in variants.contains { r.contains($0) } }) { inside = true }
            }
            return negated ? !inside : inside
        }
    }

    fileprivate indirect enum Atom {
        case literal(Character)
        case digit, nonDigit, word, nonWord, space, nonSpace
        case any
        /// nil = a class this scan cannot read; treated as matching anything.
        case charClass(CharClass?)
        /// Unicode properties, backreferences, quoted runs: may match anything.
        case other

        static func sameIgnoringCase(_ a: Character, _ b: Character) -> Bool {
            a == b || a.lowercased() == b.lowercased()
        }

        /// Conservative: true whenever the atom might match `c`.
        func canMatch(_ c: Character) -> Bool {
            switch self {
            case .literal(let l): return Atom.sameIgnoringCase(l, c)
            case .digit: return c.isNumber
            case .nonDigit: return !c.isNumber
            case .word:
                return c.isLetter || c.isNumber || c == "_"
                    || !(c.isPunctuation || c.isSymbol || c.isWhitespace || c.isNewline)
            case .nonWord: return !(c.isLetter || c.isNumber || c == "_")
            case .space: return c.isWhitespace || c.isNewline
            case .nonSpace: return !(c.isWhitespace || c.isNewline)
            case .any: return true
            case .charClass(let cc): return cc?.contains(c) ?? true
            case .other: return true
            }
        }
    }

    fileprivate enum Token {
        case open
        case close
        case alternation
        case anchor
        case atom(Atom)
        case quantifier(Quantifier)

        var isQuantifier: Bool {
            if case .quantifier = self { return true }
            return false
        }
    }

    // MARK: - Tokenizer

    fileprivate static func tokenize(_ chars: [Character]) -> [Token] {
        var tokens: [Token] = []
        var i = 0
        let n = chars.count
        while i < n {
            let c = chars[i]
            switch c {
            case "\\":
                guard i + 1 < n else {
                    tokens.append(.atom(.literal("\\")))
                    i += 1
                    continue
                }
                let e = chars[i + 1]
                i += 2
                switch e {
                case "d": tokens.append(.atom(.digit))
                case "D": tokens.append(.atom(.nonDigit))
                case "w": tokens.append(.atom(.word))
                case "W": tokens.append(.atom(.nonWord))
                case "s": tokens.append(.atom(.space))
                case "S": tokens.append(.atom(.nonSpace))
                case "b", "B", "A", "z", "Z", "G": tokens.append(.anchor)
                case "p", "P", "N", "x", "u", "X":
                    // Property, named or numeric escapes: consume a following
                    // `{…}` (or the fixed hex digits of `\uHHHH`) and treat the
                    // atom as one that may match anything.
                    if i < n, chars[i] == "{" {
                        while i < n, chars[i] != "}" { i += 1 }
                        if i < n { i += 1 }
                    } else if e == "u" {
                        i = min(n, i + 4)
                    } else if e == "x" {
                        i = min(n, i + 2)
                    } else if e == "p" || e == "P" {
                        i = min(n, i + 1)
                    }
                    tokens.append(.atom(.other))
                case "Q":
                    // Quoted run up to `\E`: literal characters.
                    while i < n {
                        if chars[i] == "\\", i + 1 < n, chars[i + 1] == "E" { i += 2; break }
                        tokens.append(.atom(.literal(chars[i])))
                        i += 1
                    }
                case "0"..."9", "k": tokens.append(.atom(.other))
                case "t": tokens.append(.atom(.literal("\t")))
                case "n": tokens.append(.atom(.literal("\n")))
                case "r": tokens.append(.atom(.literal("\r")))
                case "f", "a", "e", "R", "h", "H", "v", "V": tokens.append(.atom(.other))
                default: tokens.append(.atom(.literal(e)))
                }
            case "[":
                let (cls, end) = parseCharClass(chars, from: i)
                tokens.append(.atom(.charClass(cls)))
                i = end
            case "(":
                if i + 1 < n, chars[i + 1] == "?" {
                    // `(?#…)` comments and `(?flags)` inline settings are not
                    // groups; every other `(?…` form opens one.
                    var j = i + 2
                    if j < n, chars[j] == "#" {
                        while j < n, chars[j] != ")" { j += 1 }
                        i = min(n, j + 1)
                        continue
                    }
                    var k = j
                    while k < n, chars[k].isLetter || chars[k] == "-" { k += 1 }
                    if k < n, chars[k] == ")", k > j {
                        i = k + 1
                        continue
                    }
                    if k < n, chars[k] == ":" { j = k + 1 }
                    else if j < n, chars[j] == ":" || chars[j] == "=" || chars[j] == "!" || chars[j] == ">" { j += 1 }
                    else if j < n, chars[j] == "<" {
                        j += 1
                        if j < n, chars[j] == "=" || chars[j] == "!" { j += 1 }
                        else { while j < n, chars[j] != ">" { j += 1 }; if j < n { j += 1 } }
                    } else if j + 1 < n, chars[j] == "P", chars[j + 1] == "<" {
                        j += 2
                        while j < n, chars[j] != ">" { j += 1 }
                        if j < n { j += 1 }
                    }
                    tokens.append(.open)
                    i = j
                } else {
                    tokens.append(.open)
                    i += 1
                }
            case ")":
                tokens.append(.close)
                i += 1
            case "|":
                tokens.append(.alternation)
                i += 1
            case "^", "$":
                tokens.append(.anchor)
                i += 1
            case ".":
                tokens.append(.atom(.any))
                i += 1
            case "*", "+", "?":
                let form: Quantifier.Form = c == "*" ? .star : (c == "+" ? .plus : .question)
                tokens.append(.quantifier(Quantifier(form: form, max: c == "?" ? 1 : nil)))
                i += 1
                i = consumeModifier(chars, at: i)
            case "{":
                if let (q, end) = parseBrace(chars, from: i) {
                    tokens.append(.quantifier(q))
                    i = consumeModifier(chars, at: end)
                } else {
                    tokens.append(.atom(.literal("{")))
                    i += 1
                }
            default:
                tokens.append(.atom(.literal(c)))
                i += 1
            }
        }
        return tokens
    }

    /// A lazy `?` or possessive `+` directly after a quantifier modifies it
    /// rather than quantifying again.
    private static func consumeModifier(_ chars: [Character], at i: Int) -> Int {
        if i < chars.count, chars[i] == "?" || chars[i] == "+" { return i + 1 }
        return i
    }

    /// `{n}`, `{n,}` or `{n,m}` at `from`; nil when the brace is not an
    /// interval (the engine rejects such patterns at compile time).
    private static func parseBrace(_ chars: [Character], from: Int) -> (Quantifier, Int)? {
        var j = from + 1
        var first = ""
        while j < chars.count, chars[j].isASCII, chars[j].isNumber { first.append(chars[j]); j += 1 }
        guard !first.isEmpty, let lower = Int(first) else { return nil }
        if j < chars.count, chars[j] == "}" {
            return (Quantifier(form: .exact, max: lower), j + 1)
        }
        guard j < chars.count, chars[j] == "," else { return nil }
        j += 1
        var second = ""
        while j < chars.count, chars[j].isASCII, chars[j].isNumber { second.append(chars[j]); j += 1 }
        guard j < chars.count, chars[j] == "}" else { return nil }
        if second.isEmpty {
            return (Quantifier(form: .openBrace, max: nil), j + 1)
        }
        guard let upper = Int(second) else { return nil }
        return (Quantifier(form: .range, max: Swift.max(lower, upper)), j + 1)
    }

    /// Parses a bracket expression; the class is nil when it uses a
    /// construct this scan does not read (nested sets, POSIX names,
    /// properties), and the index after the closing `]` is returned in
    /// either case.
    private static func parseCharClass(_ chars: [Character], from: Int) -> (CharClass?, Int) {
        var cls = CharClass()
        var readable = true
        var i = from + 1
        let n = chars.count
        if i < n, chars[i] == "^" { cls.negated = true; i += 1 }
        var pending: Character? = nil   // a single that may start a range
        var first = true
        while i < n {
            let c = chars[i]
            if c == "]" && !first { return (readable ? cls : nil, i + 1) }
            first = false
            var single: Character? = nil
            if c == "\\", i + 1 < n {
                let e = chars[i + 1]
                i += 2
                switch e {
                case "d": cls.shorthands.append(.digit)
                case "D": cls.shorthands.append(.nonDigit)
                case "w": cls.shorthands.append(.word)
                case "W": cls.shorthands.append(.nonWord)
                case "s": cls.shorthands.append(.space)
                case "S": cls.shorthands.append(.nonSpace)
                case "p", "P", "N", "x", "u", "X", "Q", "E", "k", "0"..."9": readable = false
                case "t": single = "\t"
                case "n": single = "\n"
                case "r": single = "\r"
                default: single = e
                }
            } else if c == "[" {
                readable = false
                i += 1
            } else if c == "&", i + 1 < n, chars[i + 1] == "&" {
                readable = false
                i += 2
            } else if c == "-", let lo = pending, i + 1 < n, chars[i + 1] != "]" {
                // A range: `lo-hi`.
                var hi: Character = chars[i + 1]
                i += 2
                if hi == "\\", i < n { hi = chars[i]; i += 1 }
                if let l = lo.unicodeScalars.first, let h = hi.unicodeScalars.first,
                   lo.unicodeScalars.count == 1, hi.unicodeScalars.count == 1, l.value <= h.value {
                    cls.ranges.append(l.value...h.value)
                } else {
                    readable = false
                }
                pending = nil
                continue
            } else {
                single = c
                i += 1
            }
            if let s = single {
                cls.singles.append(s)
                pending = s
            } else {
                pending = nil
            }
        }
        return (nil, n)   // unterminated class: the engine rejects it
    }

    // MARK: - Rules

    private struct GroupState {
        /// The group carries an unbounded quantifier that no literal separates.
        var hasUnbounded = false
        /// The largest product of bounded maxima along any chain inside.
        var maxBoundedChain = 1
    }

    fileprivate static func evaluate(
        _ tokens: [Token], boundedCeiling: Int, productCap: Int, literalSeparatorDemotion: Bool
    ) -> Violation? {
        var stack: [GroupState] = [GroupState()]
        // The quantifier just applied, for a quantifier stacked on it:
        // its bounded chain (nil once a star-form joins) and whether it
        // counts as unbounded.
        var lastQuantifier: (chain: Int?, unbounded: Bool)? = nil
        var i = 0
        while i < tokens.count {
            switch tokens[i] {
            case .open:
                stack.append(GroupState())
                lastQuantifier = nil
            case .close:
                let group = stack.count > 1 ? stack.removeLast() : GroupState()
                if i + 1 < tokens.count, case .quantifier(let q) = tokens[i + 1] {
                    i += 1
                    let chain: Int? = q.max.map { $0.multipliedReportingOverflow(by: group.maxBoundedChain).overflow ? Int.max : $0 * group.maxBoundedChain }
                    if let chain, chain > productCap { return .nestedBoundProduct }
                    let unbounded = q.countsAsUnbounded(ceiling: boundedCeiling)
                    if unbounded, group.hasUnbounded { return .nestedUnbounded }
                    stack[stack.count - 1].hasUnbounded =
                        stack[stack.count - 1].hasUnbounded || unbounded || group.hasUnbounded
                    if let chain {
                        stack[stack.count - 1].maxBoundedChain = max(stack[stack.count - 1].maxBoundedChain, chain)
                    }
                    lastQuantifier = (chain, unbounded)
                } else {
                    stack[stack.count - 1].hasUnbounded =
                        stack[stack.count - 1].hasUnbounded || group.hasUnbounded
                    stack[stack.count - 1].maxBoundedChain =
                        max(stack[stack.count - 1].maxBoundedChain, group.maxBoundedChain)
                    lastQuantifier = nil
                }
            case .alternation, .anchor:
                lastQuantifier = nil
            case .atom(let atom):
                if i + 1 < tokens.count, case .quantifier(let q) = tokens[i + 1] {
                    let atomIndex = i
                    i += 1
                    let unbounded = q.countsAsUnbounded(ceiling: boundedCeiling)
                    if unbounded {
                        let separated = literalSeparatorDemotion
                            && isSeparated(tokens, atomIndex: atomIndex, quantifierIndex: i, atom: atom)
                        if !separated { stack[stack.count - 1].hasUnbounded = true }
                    }
                    if let m = q.max {
                        stack[stack.count - 1].maxBoundedChain = max(stack[stack.count - 1].maxBoundedChain, m)
                    }
                    lastQuantifier = (q.max, unbounded)
                } else {
                    lastQuantifier = nil
                }
            case .quantifier(let q):
                // Stacked directly on the previous quantifier (`a{0,40}{0,40}`).
                guard let previous = lastQuantifier else { break }
                let unbounded = q.countsAsUnbounded(ceiling: boundedCeiling)
                if let pc = previous.chain, let m = q.max {
                    let product = pc.multipliedReportingOverflow(by: m)
                    let chain = product.overflow ? Int.max : product.partialValue
                    if chain > productCap { return .nestedBoundProduct }
                    stack[stack.count - 1].maxBoundedChain = max(stack[stack.count - 1].maxBoundedChain, chain)
                    lastQuantifier = (chain, unbounded || previous.unbounded)
                } else {
                    lastQuantifier = (nil, unbounded || previous.unbounded)
                }
                if unbounded, previous.unbounded { return .nestedUnbounded }
                if unbounded { stack[stack.count - 1].hasUnbounded = true }
            }
            i += 1
        }
        return nil
    }

    /// True when the quantified atom is delimited, on either side inside
    /// its group, by an unquantified literal character it cannot match.
    private static func isSeparated(_ tokens: [Token], atomIndex: Int, quantifierIndex: Int, atom: Atom) -> Bool {
        let right = quantifierIndex + 1
        if right < tokens.count, case .atom(.literal(let ch)) = tokens[right] {
            let quantified = right + 1 < tokens.count && tokens[right + 1].isQuantifier
            if !quantified, !atom.canMatch(ch) { return true }
        }
        let left = atomIndex - 1
        if left >= 0, case .atom(.literal(let ch)) = tokens[left], !atom.canMatch(ch) {
            // The literal is followed directly by the atom, so it carries no
            // quantifier of its own.
            return true
        }
        return false
    }
}
