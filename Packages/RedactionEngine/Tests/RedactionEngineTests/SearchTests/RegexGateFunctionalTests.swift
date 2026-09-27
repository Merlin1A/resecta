import Testing
import Foundation
@testable import RedactionEngine

// The regex gate's functional verdicts (`validateRegexPattern`): pure
// accept/reject pins with no wall clock, so the suite gates. The timing
// halves — the payload-runtime ceilings, the cancellation and timeout paths —
// stay in `ReDoSFuzzTests` and `RegexSearchHardeningTests`, which assert
// wall-clock bounds and are report-only in the batched runner.

@Suite("Regex gate — functional verdicts", .tags(.search, .security))
struct RegexGateFunctionalTests {

    // MARK: - Validation rejects catastrophic shapes

    @Test("validateRegexPattern rejects `(a+)+b`")
    func rejectsNestedPlus() {
        #expect(DocumentSearcher.validateRegexPattern("(a+)+b") == nil)
    }

    @Test("validateRegexPattern rejects `(ab|abc)*xyz`")
    func rejectsAlternationStar() {
        #expect(DocumentSearcher.validateRegexPattern("(ab|abc)*xyz") == nil)
    }

    @Test("validateRegexPattern rejects `(a|aa)*b`")
    func rejectsOverlappingAlternationStar() {
        #expect(DocumentSearcher.validateRegexPattern("(a|aa)*b") == nil)
    }

    @Test("validateRegexPattern rejects `(a|ab)+b` (overlapping alternation under +)")
    func rejectsOverlappingAlternationPlus() {
        #expect(DocumentSearcher.validateRegexPattern("(a|ab)+b") == nil)
    }

    @Test("validateRegexPattern rejects `(a+|b+)+` (alternation of quantifiers)")
    func rejectsAlternatedQuantifiers() {
        #expect(DocumentSearcher.validateRegexPattern("(a+|b+)+") == nil)
    }

    @Test("validateRegexPattern rejects `(a|ab){2,}` (overlapping alternation under an open brace)")
    func rejectsOpenBraceOverAlternation() {
        // `(a|b){2,}` — two distinct single letters — repeats
        // deterministically and is accepted since the precheck's
        // literal-alternation demotion.
        #expect(DocumentSearcher.validateRegexPattern("(a|ab){2,}") == nil)
        #expect(DocumentSearcher.validateRegexPattern("(a|b){2,}") != nil)
    }

    // MARK: - Validation still accepts safe shapes

    @Test(#"validateRegexPattern accepts `\d{3}-\d{2}-\d{4}` (SSN shape)"#)
    func acceptsSSNShape() {
        #expect(DocumentSearcher.validateRegexPattern(#"\d{3}-\d{2}-\d{4}"#) != nil)
    }

    @Test("validateRegexPattern accepts bounded `(a|b){1,10}`")
    func acceptsBoundedAlternation() {
        #expect(DocumentSearcher.validateRegexPattern("(a|b){1,10}") != nil)
    }

    @Test("validateRegexPattern accepts all built-in saved regex patterns")
    func acceptsBuiltInRegexes() {
        for regex in SavedRegex.allBuiltIns {
            #expect(
                DocumentSearcher.validateRegexPattern(regex.pattern) != nil,
                "built-in failed validation: \(regex.label) — \(regex.pattern)"
            )
        }
    }

    @Test("validateRegexPattern rejects canonical nested-quantifier shapes")
    func validateRejectsNestedQuantifiers() {
        // `validateRegexPattern` now delegates to
        // `RegexSafetyPrecheck.isLikelyPathological` in addition to the
        // original nested-quantifier heuristic. The combined check
        // covers both (group-with-quantifier)quantifier shapes and
        // unbounded group-quantifiers over alternation
        // (e.g. `(a|ab)*b`). Backreference traps and patterns whose
        // backtracking is catastrophic only inside a single match
        // attempt are still left to the per-page 5s timeout exercised
        // by `ReDoSFuzzTests`' payload-runtime test.
        let nestedQuantifiers = [
            "(a+)+b",
            "([a-z]+)*z",
            "(.*)+x",
        ]
        for pattern in nestedQuantifiers {
            #expect(
                DocumentSearcher.validateRegexPattern(pattern) == nil,
                "pattern must be rejected by validateRegexPattern: \(pattern)"
            )
        }
    }

    @Test("validateRegexPattern rejects patterns over 200 chars")
    func validateRejectsOversizePatterns() {
        let longPattern = String(repeating: "a", count: 201)
        #expect(DocumentSearcher.validateRegexPattern(longPattern) == nil)
    }


    // MARK: - Structured exponential shapes

    /// Shapes that split one input run in exponentially many ways although
    /// no unbounded quantifier sits directly inside another: a literal
    /// separator inside one iteration but none between iterations, an
    /// ambiguous alternation under a bounded or over-ceiling repetition, a
    /// variable bounded run under an over-ceiling range, three adjacent
    /// runs over one character set.
    static let structuredShapes: [String] = [
        #"(\w+ \w+)+!"#,
        #"(\d+\.\d+)+x"#,
        "(a|aa){0,1000}c",
        "(a|a){1,25}c",
        "(a{1,25}){1,40}c",
        #"\w*\w*\w*!"#,
    ]

    @Test("validateRegexPattern rejects the structured exponential shapes", arguments: structuredShapes)
    func rejectsStructuredShapes(_ pattern: String) {
        #expect(DocumentSearcher.validateRegexPattern(pattern) == nil,
                "pattern must be rejected by validateRegexPattern: \(pattern)")
    }

    @Test("validateRegexPattern keeps rejecting the unbounded controls", arguments: ["(a+)+c", "(a|aa)*c"])
    func rejectsUnboundedControls(_ pattern: String) {
        #expect(DocumentSearcher.validateRegexPattern(pattern) == nil)
    }

    /// Realistic shapes beside the structured rules: a literal separator
    /// that ends every iteration, a prefix-free literal alternation, a
    /// bounded alternation or product within the caps, disjoint adjacent
    /// runs.
    static let acceptedNeighbours: [String] = [
        #"([A-Z][a-z]+ )+[A-Z][a-z]+"#,
        #"(\w+\.)+\w+"#,
        #"Section \d+(\.\d+)*"#,
        #"\$\d{1,3}(,\d{3})*(\.\d{2})?"#,
        #"(\d{1,3},)+\d{3}"#,
        #"(\d{3}[-. ])+\d{4}"#,
        #"(Mr\.|Mrs\.|Ms\.|Dr\.)+"#,
        "(a|aa){1,5}",
        "(a{0,20}){0,20}",
        #"\d+\s*\d+"#,
        #"\w+\s*\w+"#,
        #"\S+@\S+\.\S+"#,
        #"(\d|-){9,11}"#,
        #"[A-Z]{2}\d{2}[A-Z0-9]{11,30}"#,
        #"4111(\s?\d{4}){3}"#,
    ]

    @Test("validateRegexPattern accepts the realistic neighbours of the structured rules", arguments: acceptedNeighbours)
    func acceptsNeighbours(_ pattern: String) {
        #expect(DocumentSearcher.validateRegexPattern(pattern) != nil,
                "pattern must be accepted by validateRegexPattern: \(pattern)")
    }
}
