import Testing
import Foundation
@testable import RedactionEngine

// One custom term that runs out the page's time budget must not silence the
// custom terms after it: literal terms are checked before any regex term,
// every regex term gets its own share of the page budget (the page budget
// stays the cap), and a term the page had no time left for is reported
// with the timed-out ones rather than skipped without a word.

@Suite("Custom terms: per-term budget", .tags(.search))
struct UserTermMatcherBudgetTests {

    /// A regex compiled directly — the gate would refuse it — so it runs
    /// out any budget on a long run of `a`.
    private static func slowRegexTerm() throws -> CompiledUserTerm {
        let pattern = "(a|aa)*c"
        return CompiledUserTerm(
            pattern: pattern, regex: try NSRegularExpression(pattern: pattern), normalizedLiteral: nil)
    }

    private static func literalTerm(_ text: String) -> CompiledUserTerm {
        CompiledUserTerm(
            pattern: text, regex: nil,
            normalizedLiteral: TextNormalizer.normalizeForSearch(text, caseSensitive: false))
    }

    private static func regexTerm(_ pattern: String) throws -> CompiledUserTerm {
        CompiledUserTerm(
            pattern: pattern, regex: try NSRegularExpression(pattern: pattern), normalizedLiteral: nil)
    }

    private static let page = "ACCT-4111 " + String(repeating: "a", count: 4_000) + " REF-2024"

    @Test("A literal term after a slow regex term is still checked")
    func literalAfterSlowRegexHits() throws {
        let matcher = UserTermMatcher(
            alwaysFlag: [try Self.slowRegexTerm(), Self.literalTerm("ACCT-4111")], neverFlag: [])
        let result = matcher.alwaysFlagHits(in: Self.page, timeoutOverride: .milliseconds(300))
        #expect(result.hits.contains { $0.pattern == "ACCT-4111" },
                "the literal must hit; hits \(result.hits.map(\.pattern)), timed out \(result.timedOutPatterns)")
        #expect(result.timedOutPatterns == ["(a|aa)*c"])
    }

    @Test("A regex term after a slow regex term gets its own share of the budget")
    func regexAfterSlowRegexHits() throws {
        let matcher = UserTermMatcher(
            alwaysFlag: [try Self.slowRegexTerm(), try Self.regexTerm(#"REF-\d{4}"#)], neverFlag: [])
        let result = matcher.alwaysFlagHits(in: Self.page, timeoutOverride: .milliseconds(300))
        let checked = result.hits.contains { $0.pattern == #"REF-\d{4}"# }
            || result.timedOutPatterns.contains(#"REF-\d{4}"#)
        #expect(checked, "the second regex must hit or be reported; hits \(result.hits.map(\.pattern)), timed out \(result.timedOutPatterns)")
        #expect(result.hits.contains { $0.pattern == #"REF-\d{4}"# },
                "a fast regex finishes inside its share; timed out \(result.timedOutPatterns)")
        #expect(result.timedOutPatterns == ["(a|aa)*c"])
    }

    @Test("Hits keep the custom terms' order whatever order the terms run in")
    func hitsKeepTermOrder() throws {
        let matcher = UserTermMatcher(
            alwaysFlag: [try Self.regexTerm(#"REF-\d{4}"#), Self.literalTerm("ACCT-4111")], neverFlag: [])
        let result = matcher.alwaysFlagHits(in: Self.page)
        #expect(result.hits.map(\.pattern) == [#"REF-\d{4}"#, "ACCT-4111"])
        #expect(result.timedOutPatterns.isEmpty)
    }
}
