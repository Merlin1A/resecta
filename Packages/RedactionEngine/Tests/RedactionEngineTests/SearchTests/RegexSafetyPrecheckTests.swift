import Testing
@testable import RedactionEngine

// L-17 — Pre-compile ReDoS heuristic. Parametric across OWASP-cited
// catastrophic patterns plus known-safe shapes.

@Suite("Regex Safety Precheck (L-17)")
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
        #expect(RegexSafetyPrecheck.isLikelyPathological("(a|b){2,}"))
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
