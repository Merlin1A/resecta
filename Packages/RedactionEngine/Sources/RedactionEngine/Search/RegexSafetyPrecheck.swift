import Foundation

/// Lightweight pre-compile heuristic for catastrophic-backtracking shapes (L-17).
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
public enum RegexSafetyPrecheck {

    /// Returns true if the pattern contains a group followed by an unbounded
    /// quantifier (`*`, `+`, `{n,}`) and that group either contains another
    /// unbounded quantifier (nested case) or a top-level alternation `|`
    /// (overlapping-alternation proxy).
    public static func isLikelyPathological(_ pattern: String) -> Bool {
        let chars = Array(pattern)

        struct GroupState {
            var hasInnerQuantifier = false
            var hasAlternation = false
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
                stack.append(GroupState())

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
                if unbounded, closed.hasInnerQuantifier || closed.hasAlternation {
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
