import Testing
import Foundation
@testable import ResectaApp

// Pkg G.3 — multi-term TextField submission validator.
//
// TRUST-multiterm-no-length-cap + UX-multiterm-length-cap-banner:
// the validator runs the length cap BEFORE the duplicate check so an
// over-cap dup-of-existing entry surfaces the more specific length-cap
// copy from S2 §L.6 rather than the duplicate copy.
//
// Banner copy (S2 §L.6) is pinned verbatim — UI surfaces the same
// `duplicateTermMessage` channel for both length-cap and duplicate
// rejections.

@Suite("SearchAndRedactSheet — multi-term submission (Pkg G.3)", .tags(.search))
struct SearchAndRedactSheetMultiTermTests {

    // MARK: - Length cap

    @Test("Over 200-char submission rejected with exact S2 §L.6 copy")
    func testOver200CharSubmissionRejected() {
        let raw = String(repeating: "a", count: 201)
        let outcome = SearchAndRedactSheet.validateMultiTermSubmission(
            rawText: raw,
            existingTerms: []
        )
        switch outcome {
        case .rejectedTooLong(let message):
            #expect(message == "Search term is too long. Trim to 200 characters or fewer.")
        default:
            Issue.record("Expected .rejectedTooLong for a 201-char submission, got \(outcome)")
        }
    }

    @Test("Exactly 200-char submission accepted (boundary)")
    func testExactly200CharSubmissionAccepted() {
        let raw = String(repeating: "a", count: 200)
        let outcome = SearchAndRedactSheet.validateMultiTermSubmission(
            rawText: raw,
            existingTerms: []
        )
        switch outcome {
        case .accepted(let trimmed):
            #expect(trimmed.count == 200)
        default:
            Issue.record("Expected .accepted at the 200-char boundary, got \(outcome)")
        }
    }

    @Test("Length cap is mirrored from DocumentSearcher.maxRegexPatternLength (200)")
    func testLengthCapMirrorsEngine() {
        #expect(SearchAndRedactSheet.multiTermMaxLength == 200)
    }

    @Test("Whitespace is trimmed before the length check (201-char-after-trim still rejected)")
    func testTrimmingHappensBeforeLengthCheck() {
        let raw = "  " + String(repeating: "a", count: 201) + "  "
        let outcome = SearchAndRedactSheet.validateMultiTermSubmission(
            rawText: raw,
            existingTerms: []
        )
        switch outcome {
        case .rejectedTooLong:
            break
        default:
            Issue.record("Whitespace-padded 201-char string should reject as too long, got \(outcome)")
        }
    }

    @Test("Whitespace-only 199-char trims to empty and rejects as empty")
    func testWhitespaceOnlyRejectsEmpty() {
        let raw = String(repeating: " ", count: 199)
        let outcome = SearchAndRedactSheet.validateMultiTermSubmission(
            rawText: raw,
            existingTerms: []
        )
        #expect(outcome == .rejectedEmpty)
    }

    // MARK: - Duplicate regression

    @Test("Duplicate-rejection behavior preserved (existing U5 contract)")
    func testDuplicateRejectionStillWorks() {
        let outcome = SearchAndRedactSheet.validateMultiTermSubmission(
            rawText: "Smith",
            existingTerms: ["smith"]
        )
        switch outcome {
        case .rejectedDuplicate(let message):
            #expect(message == "Already searching for \"Smith\"")
        default:
            Issue.record("Expected .rejectedDuplicate for case-insensitive duplicate, got \(outcome)")
        }
    }

    @Test("Length check fires BEFORE duplicate check (over-cap dup gets length copy)")
    func testLengthCheckOrderedBeforeDuplicate() {
        let over = String(repeating: "x", count: 250)
        let outcome = SearchAndRedactSheet.validateMultiTermSubmission(
            rawText: over,
            existingTerms: [over]
        )
        // Even though `over` is also a duplicate of `existingTerms`,
        // the length-cap reject must win because it is the more
        // specific failure mode.
        switch outcome {
        case .rejectedTooLong(let message):
            #expect(message == "Search term is too long. Trim to 200 characters or fewer.")
        default:
            Issue.record("Length check must precede duplicate check, got \(outcome)")
        }
    }

    @Test("Non-duplicate accepted submission carries the trimmed string")
    func testAcceptedReturnsTrimmedString() {
        let outcome = SearchAndRedactSheet.validateMultiTermSubmission(
            rawText: "  Smith  ",
            existingTerms: ["Jones"]
        )
        #expect(outcome == .accepted(trimmed: "Smith"))
    }
}
