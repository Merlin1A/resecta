import Foundation

/// Lightweight pre-compile heuristic for catastrophic-backtracking shapes.
///
/// Runs before `RegexSentinelCheck.validate` detaches tasks — rejects obvious
/// ReDoS shapes synchronously so adversarial patterns can't orphan the
/// sentinel's `enumerateMatches` task for seconds (the regex engine spins
/// inside a synchronous C call that neither `cancelAll()` nor the 200 ms
/// wall-clock timer can interrupt).
///
/// Scope: conservative. False positives (rejecting safe patterns) are
/// preferred to false negatives on the regex-import path where profiles can
/// be adversarial. Users needing alternation-under-quantification can
/// rewrite with bounded repetition (`{n,m}` with finite upper bound) or
/// atomic groups.
enum RegexSafetyPrecheck {

    /// Returns true if the pattern contains a group followed by an unbounded
    /// quantifier (`*`, `+`, `{n,}`) and that group either contains another
    /// unbounded quantifier (nested case) or a top-level alternation `|`
    /// (overlapping-alternation proxy) — unless that alternation is a
    /// prefix-free set of literal strings, which repeats deterministically
    /// (`isPrefixFreeLiteralAlternation`).
    ///
    /// The nested case defers to `RegexQuantifierScan`'s reading of the
    /// same shape, which ignores an inner run that a literal character
    /// inside the group delimits (`(\.\d+)*`, `([a-z]+ )+`): with the
    /// iteration boundary fixed by the literal the shape is at worst
    /// polynomial — the runtime sentinel's class, not this precheck's.
    static func isLikelyPathological(_ pattern: String) -> Bool {
        let chars = Array(pattern)
        var nestedUnboundedCache: Bool? = nil
        func nestedUnboundedStands() -> Bool {
            if let cached = nestedUnboundedCache { return cached }
            let value = RegexQuantifierScan.hasNestedUnbounded(
                pattern,
                boundedCeiling: DocumentSearcher.boundedQuantifierCeiling,
                literalSeparatorDemotion: true)
            nestedUnboundedCache = value
            return value
        }

        struct GroupState {
            var hasInnerQuantifier = false
            var hasAlternation = false
            /// Index of the opening `(`; -1 for the pseudo top-level group.
            var start = -1
        }
        // Index 0 is the pseudo top-level group; real nested groups push above.
        var stack: [GroupState] = [GroupState()]

        var i = 0
        while i < chars.count {
            // Backslash-escape: consume the next char as a literal.
            if chars[i] == "\\" {
                i += 2
                continue
            }
            // Skip character classes — tokens inside `[...]` are literal.
            if chars[i] == "[" {
                i = skipCharClass(chars, from: i)
                continue
            }

            switch chars[i] {
            case "(":
                stack.append(GroupState(start: i))

            case ")":
                // Defensive: a malformed pattern with unbalanced parens is
                // simply not flagged here — NSRegularExpression compile will
                // reject it downstream.
                let closed = stack.count > 1 ? stack.removeLast() : GroupState()
                let nextIdx = i + 1
                let unbounded: Bool
                if nextIdx < chars.count {
                    switch chars[nextIdx] {
                    case "*", "+":
                        unbounded = true
                    case "{":
                        unbounded = braceIsUnbounded(chars, startingAt: nextIdx)
                    default:
                        unbounded = false
                    }
                } else {
                    unbounded = false
                }
                if unbounded, closed.hasAlternation,
                   !isPrefixFreeLiteralAlternation(chars, from: closed.start, to: i) {
                    return true
                }
                if unbounded, closed.hasInnerQuantifier, nestedUnboundedStands() {
                    return true
                }

            case "|":
                stack[stack.count - 1].hasAlternation = true

            case "*", "+":
                stack[stack.count - 1].hasInnerQuantifier = true

            case "{":
                if braceIsUnbounded(chars, startingAt: i) {
                    stack[stack.count - 1].hasInnerQuantifier = true
                }

            default:
                break
            }
            i += 1
        }
        return false
    }

    // MARK: - Helpers

    /// True when the group `chars[from...to]` (its parentheses included) is
    /// a plain or non-capturing group whose body is an alternation of pure
    /// literal strings — escapes allowed, no classes, quantifiers, anchors,
    /// wildcards or nested groups — that are pairwise distinct and
    /// prefix-free. At any input position at most one such alternative can
    /// match, so repeating the group is a deterministic, linear walk:
    /// `(Mr\.|Mrs\.|Ms\.|Dr\.)+` qualifies; `(a|ab)+b`, `(a|aa)*b` and
    /// `(a\.|a\.)+` (a duplicate) do not.
    private static func isPrefixFreeLiteralAlternation(
        _ chars: [Character], from: Int, to: Int
    ) -> Bool {
        guard from >= 0, to > from + 1 else { return false }
        var i = from + 1
        if i < to, chars[i] == "?" {
            // Only the non-capturing form; lookarounds and atomic groups
            // stay on the conservative side.
            guard i + 1 < to, chars[i + 1] == ":" else { return false }
            i += 2
        }
        var alternatives: [[Character]] = [[]]
        while i < to {
            let c = chars[i]
            switch c {
            case "\\":
                guard i + 1 < to else { return false }
                let e = chars[i + 1]
                // Only escaped punctuation is a literal; `\d`, `\w`, `\b`,
                // `\1`, `\p{…}` and the control escapes are not.
                if e.isLetter || e.isNumber { return false }
                alternatives[alternatives.count - 1].append(e)
                i += 2
            case "|":
                alternatives.append([])
                i += 1
            case "(", ")", "[", "]", "*", "+", "?", "{", "}", ".", "^", "$":
                return false
            default:
                alternatives[alternatives.count - 1].append(c)
                i += 1
            }
        }
        guard alternatives.count >= 2, alternatives.allSatisfy({ !$0.isEmpty }) else { return false }
        for a in alternatives.indices {
            for b in alternatives.indices where a != b {
                let x = alternatives[a], y = alternatives[b]
                if x.count <= y.count, Array(y.prefix(x.count)) == x { return false }
            }
        }
        return true
    }

    private static func skipCharClass(_ chars: [Character], from: Int) -> Int {
        var i = from + 1
        // `[^` introduces a negated class; `[]` has a literal leading `]`.
        if i < chars.count, chars[i] == "^" { i += 1 }
        if i < chars.count, chars[i] == "]" { i += 1 }
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count {
                i += 2
                continue
            }
            if chars[i] == "]" { return i + 1 }
            i += 1
        }
        return chars.count  // unterminated class; consume rest
    }

    /// True iff `{...}` at `startingAt` has an empty upper bound after a
    /// comma (`{n,}`). `{n}` (exact) and `{n,m}` (bounded) return false.
    private static func braceIsUnbounded(_ chars: [Character], startingAt: Int) -> Bool {
        guard startingAt < chars.count, chars[startingAt] == "{" else { return false }
        var j = startingAt + 1
        while j < chars.count, chars[j] != "}" { j += 1 }
        guard j < chars.count else { return false }
        let content = String(chars[(startingAt + 1)..<j])
        guard let commaIdx = content.firstIndex(of: ",") else { return false }
        let afterComma = content[content.index(after: commaIdx)...]
            .trimmingCharacters(in: .whitespaces)
        return afterComma.isEmpty
    }
}
