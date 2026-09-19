import Testing
@testable import RedactionEngine

// Pre-compile ReDoS heuristic. Parametric across OWASP-cited
// catastrophic patterns plus known-safe shapes.

@Suite("Regex Safety Precheck")
struct RegexSafetyPrecheckTests {

    // MARK: - Pathological (must flag)

    @Test("Nested-plus quantifier `(a+)+b` flagged")
    func nestedPlusFlagged() {
        #expect(RegexSafetyPrecheck.isLikelyPathological("(a+)+b"))
    }

    @Test("Nested-star `(.*)*` flagged")
    func nestedStarFlagged() {
        #expect(RegexSafetyPrecheck.isLikelyPathological("(.*)*"))
    }

    @Test("Overlapping alternation `(a|ab)+b` flagged")
    func overlappingAlternationFlagged() {
        #expect(RegexSafetyPrecheck.isLikelyPathological("(a|ab)+b"))
    }

    @Test("Alternation of quantifiers `(a+|b+)+` flagged")
    func alternatedQuantifiersFlagged() {
        #expect(RegexSafetyPrecheck.isLikelyPathological("(a+|b+)+"))
    }

    @Test("Open-upper-bound inside group `(a{1,})+` flagged")
    func nestedOpenUpperBoundFlagged() {
        #expect(RegexSafetyPrecheck.isLikelyPathological("(a{1,})+"))
    }

    @Test("Group followed by `{n,}` open upper bound flagged")
    func groupFollowedByOpenBraceFlagged() {
        // `(a|ab)`: "a" is a prefix of "ab", so the repeated choice is
        // ambiguous. (`(a|b){2,}` — two distinct single letters — repeats
        // deterministically and is accepted; see the alternation suite.)
        #expect(RegexSafetyPrecheck.isLikelyPathological("(a|ab){2,}"))
    }

    @Test("Simple nested star `(a*)*` flagged")
    func simpleNestedStarFlagged() {
        #expect(RegexSafetyPrecheck.isLikelyPathological("(a*)*"))
    }

    // MARK: - Safe (must NOT flag)

    @Test(#"SSN-shape \d{3}-\d{4} accepted"#)
    func ssnShapeAccepted() {
        #expect(!RegexSafetyPrecheck.isLikelyPathological(#"\d{3}-\d{4}"#))
    }

    @Test(#"Alphanumeric `[a-z]+\d+` accepted (quantifiers outside groups)"#)
    func simpleAlnumAccepted() {
        #expect(!RegexSafetyPrecheck.isLikelyPathological(#"[a-z]+\d+"#))
    }

    @Test(#"Escaped literal parens `\(\d+\)` accepted"#)
    func escapedLiteralParensAccepted() {
        #expect(!RegexSafetyPrecheck.isLikelyPathological(#"\(\d+\)"#))
    }

    @Test("Bounded alternation `(a|b){1,10}` accepted")
    func boundedAlternationAccepted() {
        #expect(!RegexSafetyPrecheck.isLikelyPathological("(a|b){1,10}"))
    }

    @Test("Exact-count quantifier `(a|b){5}` accepted")
    func exactCountAlternationAccepted() {
        #expect(!RegexSafetyPrecheck.isLikelyPathological("(a|b){5}"))
    }

    @Test("Character class with `*` `+` treats them as literals")
    func quantifierInCharClassAccepted() {
        #expect(!RegexSafetyPrecheck.isLikelyPathological("[*+]abc"))
    }

    @Test("Simple group with no quantifier `(foo)bar` accepted")
    func simpleGroupAccepted() {
        #expect(!RegexSafetyPrecheck.isLikelyPathological("(foo)bar"))
    }

    @Test("Plain literal `hello world` accepted")
    func plainLiteralAccepted() {
        #expect(!RegexSafetyPrecheck.isLikelyPathological("hello world"))
    }

    @Test("Negated character class `[^0-9]+` accepted")
    func negatedCharClassAccepted() {
        #expect(!RegexSafetyPrecheck.isLikelyPathological("[^0-9]+"))
    }

    @Test("Nested groups without quantifiers `((foo)bar)` accepted")
    func nestedGroupsWithoutQuantifierAccepted() {
        #expect(!RegexSafetyPrecheck.isLikelyPathological("((foo)bar)"))
    }

    @Test("Empty pattern accepted")
    func emptyPatternAccepted() {
        #expect(!RegexSafetyPrecheck.isLikelyPathological(""))
    }
}

// MARK: - Literal separators demote the nested-unbounded shape

/// A group repeated without bound whose inner unbounded run is delimited
/// INSIDE the group by a literal character the run cannot match —
/// `\.` beside `\d+`, a space after `[a-z]+`, `\.` after `\w+` — cannot
/// re-split the input between iterations: the literal fixes every
/// iteration boundary. That is the polynomial class the 200 ms sentinel
/// probe backstops, not the exponential nested-quantifier class this
/// precheck exists for. The demotion never touches the alternation rule.
@Suite("Regex Safety Precheck — literal separators")
struct RegexSafetyPrecheckSeparatorTests {

    @Test(#"Dotted section numbers `Section \d+(\.\d+)*` accepted"#)
    func dottedSectionNumbersAccepted() {
        #expect(!RegexSafetyPrecheck.isLikelyPathological(#"Section \d+(\.\d+)*"#))
    }

    @Test("Space-separated capitalised words `([A-Z][a-z]+ )+[A-Z][a-z]+` accepted")
    func spaceSeparatedWordsAccepted() {
        #expect(!RegexSafetyPrecheck.isLikelyPathological("([A-Z][a-z]+ )+[A-Z][a-z]+"))
    }

    @Test(#"Dotted name chain `(\w+\.)+\w+` accepted"#)
    func dottedNameChainAccepted() {
        #expect(!RegexSafetyPrecheck.isLikelyPathological(#"(\w+\.)+\w+"#))
    }

    @Test(#"Digit runs with optional whitespace `(\d+\s*)+` stay flagged (no literal delimits the run)"#)
    func digitRunsStayFlagged() {
        #expect(RegexSafetyPrecheck.isLikelyPathological(#"(\d+\s*)+"#))
    }

    @Test("A separator the run CAN match does not demote: `(\\w+_)+` stays flagged")
    func matchableSeparatorStaysFlagged() {
        // `_` is a word character, so `\w+` can absorb the separator and
        // the iteration boundary is ambiguous again.
        #expect(RegexSafetyPrecheck.isLikelyPathological(#"(\w+_)+"#))
    }

    @Test("A quantified separator does not demote: `(\\d+\\.?)+` stays flagged")
    func quantifiedSeparatorStaysFlagged() {
        #expect(RegexSafetyPrecheck.isLikelyPathological(#"(\d+\.?)+"#))
    }
}

// MARK: - Prefix-free literal alternation under repetition

/// A repeated alternation of literal strings none of which is a prefix of
/// another matches at most one alternative at any position: repeating it is
/// a deterministic walk. Only that exact shape is demoted; an alternative
/// with a class, quantifier, wildcard, anchor or nested group — or two
/// alternatives that overlap — keeps the conservative verdict.
@Suite("Regex Safety Precheck — literal alternation")
struct RegexSafetyPrecheckAlternationTests {

    @Test(#"Quantified title alternation `(Mr\.|Mrs\.|Ms\.|Dr\.)+` accepted"#)
    func titleAlternationAccepted() {
        #expect(!RegexSafetyPrecheck.isLikelyPathological(#"(Mr\.|Mrs\.|Ms\.|Dr\.)+"#))
        #expect(DocumentSearcher.validateRegexPattern(#"(Mr\.|Mrs\.|Ms\.|Dr\.)+"#) != nil)
    }

    @Test("Distinct single letters `(a|b){2,}` and `(?:ab|cd)+` accepted")
    func prefixFreeLiteralsAccepted() {
        #expect(!RegexSafetyPrecheck.isLikelyPathological("(a|b){2,}"))
        #expect(!RegexSafetyPrecheck.isLikelyPathological("(?:ab|cd)+"))
    }

    @Test("A prefix overlap `(a|ab)+b`, a duplicate `(a\\.|a\\.)+` and a class inside `(a|[bc])+` stay flagged")
    func overlappingOrNonLiteralAlternationStaysFlagged() {
        #expect(RegexSafetyPrecheck.isLikelyPathological("(a|ab)+b"))
        #expect(RegexSafetyPrecheck.isLikelyPathological(#"(a\.|a\.)+"#))
        #expect(RegexSafetyPrecheck.isLikelyPathological("(a|[bc])+"))
        #expect(RegexSafetyPrecheck.isLikelyPathological("(a|b+)+"))
        #expect(RegexSafetyPrecheck.isLikelyPathological("(?=a|b)+"))
    }
}
