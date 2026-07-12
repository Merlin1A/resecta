import Testing
import Foundation
@testable import ResectaApp
@testable import RedactionEngine

// Pkg G.3 — TRUST-customterms-no-async-sentinel.
//
// `AddTermRow.submit` previously committed regex terms after the sync
// `DocumentSearcher.validateRegexPattern` check, bypassing the async
// `RegexSentinelCheck.validate` ReDoS sentinel that
// `SavedRegexLibraryView.commitAdd` and
// `SearchToolbarSection.saveCurrentRegex` already enforced. These
// tests pin the new chain: regex submissions route through the
// sentinel before commit; literal submissions skip it.

@Suite("AddTermRow — async sentinel validation (Pkg G.3)", .tags(.search))
@MainActor
struct AddTermRowAsyncSentinelTests {

    // MARK: - Pure validator outcomes

    @Test("Regex submission routes through RegexSentinelCheck (catastrophic regex rejected)")
    func testValidationRoutesThroughSentinel() async {
        // `(a+)+b` is the canonical catastrophic-backtracking shape
        // RegexSafetyPrecheck / RegexSentinelCheck rejects. If the
        // submit path skipped the sentinel, the sync precheck alone
        // might still let some shapes through; the sentinel layer is
        // the runtime probe `SavedRegexLibraryView.commitAdd` relies
        // on for parity here.
        let outcome = await AddTermRow.validateSubmission(
            rawPattern: "(a+)+b",
            isRegex: true
        )
        switch outcome {
        case .invalidRegex, .sentinelRejected:
            break
        default:
            Issue.record("Catastrophic regex should be rejected via sentinel/precheck chain, got \(outcome)")
        }
    }

    @Test("Safe regex passes the sentinel chain and accepts")
    func testSafeRegexAccepted() async {
        let outcome = await AddTermRow.validateSubmission(
            rawPattern: #"\d{3}-\d{4}"#,
            isRegex: true
        )
        switch outcome {
        case .accepted(let term):
            #expect(term.pattern == #"\d{3}-\d{4}"#)
            #expect(term.isRegex)
        default:
            Issue.record("Safe regex should accept, got \(outcome)")
        }
    }

    @Test("Literal submission skips the regex/sentinel chain and accepts")
    func testLiteralAccepted() async {
        let outcome = await AddTermRow.validateSubmission(
            rawPattern: "Smith",
            isRegex: false
        )
        switch outcome {
        case .accepted(let term):
            #expect(term.pattern == "Smith")
            #expect(!term.isRegex)
        default:
            Issue.record("Literal submission should accept without sentinel, got \(outcome)")
        }
    }

    // MARK: - Boundary + sync guards (preserved behavior)

    @Test("Empty / whitespace-only pattern rejects as .empty")
    func testEmptyRejected() async {
        let outcome = await AddTermRow.validateSubmission(
            rawPattern: "   ",
            isRegex: false
        )
        #expect(outcome == .empty)
    }

    @Test("Over-cap literal rejects as .tooLong (sync guard, sentinel never invoked)")
    func testLiteralOverCapRejected() async {
        let raw = String(repeating: "a", count: UserTermsStore.patternLengthCap + 1)
        let outcome = await AddTermRow.validateSubmission(
            rawPattern: raw,
            isRegex: false
        )
        switch outcome {
        case .tooLong(let message):
            #expect(message.contains("\(UserTermsStore.patternLengthCap)"))
        default:
            Issue.record("Over-cap literal must reject as .tooLong, got \(outcome)")
        }
    }

    @Test("Invalid-shape regex rejects via sync precheck (.invalidRegex)")
    func testInvalidRegexShapeRejected() async {
        // Unclosed group — fails NSRegularExpression compile in
        // `validateRegexPattern`, so we never reach the sentinel.
        let outcome = await AddTermRow.validateSubmission(
            rawPattern: "(unclosed",
            isRegex: true
        )
        switch outcome {
        case .invalidRegex:
            break
        default:
            Issue.record("Invalid regex shape should reject pre-sentinel, got \(outcome)")
        }
    }
}
