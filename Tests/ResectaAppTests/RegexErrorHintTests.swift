import Testing
import Foundation
@testable import ResectaApp

// q16/UXF-18 — human hints for common NSRegularExpression failure
// shapes. The hint comes from a shape scan of the PATTERN (the NSError
// text is opaque boilerplate); the engine's original description is
// preserved after the hint. No new parsing dependency (C-9).

@Suite("Regex error hints (UXF-18)", .tags(.search))
@MainActor
struct RegexErrorHintTests {

    // MARK: - Shape → hint mapping

    @Test("Unclosed group")
    func unclosedGroup() {
        #expect(SearchAndRedactSheet.regexErrorHint(pattern: "(abc")
                == "A ( group is never closed — add the matching ).")
        #expect(SearchAndRedactSheet.regexErrorHint(pattern: "a(b(c)")
                == "A ( group is never closed — add the matching ).")
    }

    @Test("Unmatched closing parenthesis")
    func unmatchedCloseParen() {
        #expect(SearchAndRedactSheet.regexErrorHint(pattern: "abc)")
                == "A ) has no matching ( — remove it or add the opening (.")
    }

    @Test("Unclosed character class")
    func unclosedCharacterClass() {
        #expect(SearchAndRedactSheet.regexErrorHint(pattern: "[a-z")
                == "A [ character class is never closed — add the matching ].")
    }

    @Test("Dangling quantifier")
    func danglingQuantifier() {
        let hint = "A *, +, or ? needs something before it to repeat."
        #expect(SearchAndRedactSheet.regexErrorHint(pattern: "*abc") == hint)
        #expect(SearchAndRedactSheet.regexErrorHint(pattern: "(+x)") == hint)
        #expect(SearchAndRedactSheet.regexErrorHint(pattern: "a|?b") == hint)
    }

    @Test("Trailing lone backslash")
    func trailingBackslash() {
        #expect(SearchAndRedactSheet.regexErrorHint(pattern: "abc\\")
                == "The pattern ends with a lone backslash — remove it, or double it (\\\\) to match a literal backslash.")
    }

    // MARK: - Valid shapes produce no hint

    @Test("Valid patterns produce no hint (escapes, classes, quantifiers with operands)")
    func validShapesNoHint() {
        #expect(SearchAndRedactSheet.regexErrorHint(pattern: "\\d+") == nil)
        #expect(SearchAndRedactSheet.regexErrorHint(pattern: "(a|b)*c?") == nil)
        #expect(SearchAndRedactSheet.regexErrorHint(pattern: "[a-z]+@[a-z]+") == nil)
        #expect(SearchAndRedactSheet.regexErrorHint(pattern: "\\(literal\\)") == nil)
        #expect(SearchAndRedactSheet.regexErrorHint(pattern: "a+?") == nil,
                "lazy quantifier — the ? follows a quantifier that itself had an operand")
    }

    // MARK: - Display composition

    @Test("Display message leads with the hint and keeps the engine text")
    func displayMessageComposition() {
        let message = SearchAndRedactSheet.regexErrorDisplayMessage(
            pattern: "(abc",
            engineDescription: "The operation couldn't be completed."
        )
        #expect(message
                == "A ( group is never closed — add the matching ). (The operation couldn't be completed.)")
    }

    @Test("Display message falls back to the engine text when no shape matches")
    func displayMessageFallback() {
        let message = SearchAndRedactSheet.regexErrorDisplayMessage(
            pattern: "a{,2}",
            engineDescription: "engine says no"
        )
        #expect(message == "engine says no")
    }
}
