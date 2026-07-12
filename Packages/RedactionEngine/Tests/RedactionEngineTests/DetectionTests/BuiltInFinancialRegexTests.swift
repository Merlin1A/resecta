import Testing
import Foundation
@testable import RedactionEngine

// Design 04 §4.2 — per-pattern positive/negative vector tests for the
// five financial-identity built-in SavedRegex patterns. Each test
// compiles the pattern via `DocumentSearcher.validateRegexPattern` and
// asserts match / no-match on the design's named example vectors.
//
// Positive vectors: the pattern should produce at least one match.
// Negative vectors: the pattern should produce no match.
//
// `NSRegularExpression` is used directly (the same engine the searcher
// uses at runtime) rather than `String.range(of:options:.regularExpression)`
// so the boundary behaviour is identical to production search.

// MARK: - Helpers

private func compiled(_ pattern: String) throws -> NSRegularExpression {
    try #require(DocumentSearcher.validateRegexPattern(pattern))
}

private func matches(_ re: NSRegularExpression, in haystack: String) -> Bool {
    let range = NSRange(haystack.startIndex..<haystack.endIndex, in: haystack)
    return re.firstMatch(in: haystack, range: range) != nil
}

// MARK: - SSN

@Suite("Built-in SSN regex vectors (design 04 §4.2)", .tags(.search))
struct BuiltInSSNRegexTests {

    @Test("SSN positive: hyphen-separated 123-45-6789")
    func ssnPositiveHyphen() throws {
        let re = try compiled(SavedRegex.builtInSSN.pattern)
        #expect(matches(re, in: "SSN: 123-45-6789"))
    }

    @Test("SSN positive: space-separated 123 45 6789")
    func ssnPositiveSpaces() throws {
        let re = try compiled(SavedRegex.builtInSSN.pattern)
        #expect(matches(re, in: "Number 123 45 6789 on file"))
    }

    @Test("SSN positive: contiguous 123456789")
    func ssnPositiveContiguous() throws {
        let re = try compiled(SavedRegex.builtInSSN.pattern)
        #expect(matches(re, in: "ref: 123456789"))
    }

    @Test("SSN negative: 000 prefix is never-issued (000-12-3456)")
    func ssnNegativeZeroPrefix() throws {
        let re = try compiled(SavedRegex.builtInSSN.pattern)
        #expect(!matches(re, in: "000-12-3456"))
    }

    @Test("SSN negative: group 00 is never-issued (123-00-6789)")
    func ssnNegativeZeroGroup() throws {
        let re = try compiled(SavedRegex.builtInSSN.pattern)
        #expect(!matches(re, in: "123-00-6789"))
    }

    @Test("SSN negative: serial 0000 is never-issued (123-45-0000)")
    func ssnNegativeZeroSerial() throws {
        let re = try compiled(SavedRegex.builtInSSN.pattern)
        #expect(!matches(re, in: "123-45-0000"))
    }
}

// MARK: - EIN

@Suite("Built-in EIN regex vectors (design 04 §4.2)", .tags(.search))
struct BuiltInEINRegexTests {

    @Test("EIN positive: hyphen-separated 12-3456789")
    func einPositiveHyphen() throws {
        let re = try compiled(SavedRegex.builtInEIN.pattern)
        #expect(matches(re, in: "EIN: 12-3456789"))
    }

    @Test("EIN positive: space-separated 12 3456789")
    func einPositiveSpaces() throws {
        let re = try compiled(SavedRegex.builtInEIN.pattern)
        #expect(matches(re, in: "Employer 12 3456789"))
    }

    @Test("EIN positive: contiguous 123456789")
    func einPositiveContiguous() throws {
        let re = try compiled(SavedRegex.builtInEIN.pattern)
        #expect(matches(re, in: "tax id 123456789"))
    }

    @Test("EIN negative: prefix 00 is never-issued (00-1234567)")
    func einNegativePrefix00() throws {
        let re = try compiled(SavedRegex.builtInEIN.pattern)
        #expect(!matches(re, in: "00-1234567"))
    }

    @Test("EIN negative: prefix 07 is never-issued (07-1234567)")
    func einNegativePrefix07() throws {
        let re = try compiled(SavedRegex.builtInEIN.pattern)
        #expect(!matches(re, in: "07-1234567"))
    }

    @Test("EIN negative: prefix 08 is never-issued (08-1234567)")
    func einNegativePrefix08() throws {
        let re = try compiled(SavedRegex.builtInEIN.pattern)
        #expect(!matches(re, in: "08-1234567"))
    }
}

// MARK: - ITIN

@Suite("Built-in ITIN regex vectors (design 04 §4.2)", .tags(.search))
struct BuiltInITINRegexTests {

    @Test("ITIN positive: 912-70-1234 (group 70 in bucket 70-88)")
    func itinPositiveGroup70() throws {
        let re = try compiled(SavedRegex.builtInITIN.pattern)
        #expect(matches(re, in: "ITIN: 912-70-1234"))
    }

    @Test("ITIN positive: space-separated 912 70 1234")
    func itinPositiveSpaces() throws {
        let re = try compiled(SavedRegex.builtInITIN.pattern)
        #expect(matches(re, in: "Tax id 912 70 1234"))
    }

    @Test("ITIN positive: 951-50-1234 (group 50 in bucket 50-65)")
    func itinPositiveGroup50() throws {
        let re = try compiled(SavedRegex.builtInITIN.pattern)
        #expect(matches(re, in: "ref 951-50-1234"))
    }

    @Test("ITIN negative: area does not start with 9 (123-70-1234)")
    func itinNegativeAreaNot9xx() throws {
        let re = try compiled(SavedRegex.builtInITIN.pattern)
        #expect(!matches(re, in: "123-70-1234"))
    }

    @Test("ITIN negative: group 93 is not a valid ITIN bucket (912-93-1234)")
    func itinNegativeGroup93() throws {
        let re = try compiled(SavedRegex.builtInITIN.pattern)
        #expect(!matches(re, in: "912-93-1234"))
    }

    @Test("ITIN negative: group 69 is not a valid ITIN bucket (912-69-1234)")
    func itinNegativeGroup69() throws {
        let re = try compiled(SavedRegex.builtInITIN.pattern)
        #expect(!matches(re, in: "912-69-1234"))
    }
}

// MARK: - ABA Routing Number

@Suite("Built-in ABA routing regex vectors (design 04 §4.2)", .tags(.search))
struct BuiltInABARoutingRegexTests {

    @Test("ABA positive: 021000021 (prefix 02 in 01-12 range)")
    func abaPositivePrefix02() throws {
        let re = try compiled(SavedRegex.builtInABARouting.pattern)
        #expect(matches(re, in: "Routing: 021000021"))
    }

    @Test("ABA positive: 322271627 (prefix 32 in 21-32 range)")
    func abaPositivePrefix32() throws {
        let re = try compiled(SavedRegex.builtInABARouting.pattern)
        #expect(matches(re, in: "Transit 322271627"))
    }

    @Test("ABA positive: isolated 061000104 (prefix 06 in 01-12 range)")
    func abaPositivePrefix06() throws {
        let re = try compiled(SavedRegex.builtInABARouting.pattern)
        #expect(matches(re, in: "ABA 061000104"))
    }

    @Test("ABA negative: prefix 99 not in any valid ABA range (999999999)")
    func abaNegativePrefix99() throws {
        let re = try compiled(SavedRegex.builtInABARouting.pattern)
        #expect(!matches(re, in: "999999999"))
    }

    @Test("ABA negative: 10-digit run is rejected by trailing digit lookahead (0210000210)")
    func abaNegative10DigitRun() throws {
        let re = try compiled(SavedRegex.builtInABARouting.pattern)
        // The (?!\d) lookahead fires after the 9th digit since position 9
        // is still a digit, rejecting the match.
        #expect(!matches(re, in: "0210000210"))
    }

    @Test("ABA negative: prefix 13 not in any valid ABA range (130000000)")
    func abaNegativePrefix13() throws {
        let re = try compiled(SavedRegex.builtInABARouting.pattern)
        #expect(!matches(re, in: "130000000"))
    }
}

// MARK: - Account Number (generic)

@Suite("Built-in account number regex vectors (design 04 §4.2)", .tags(.search))
struct BuiltInAccountNumberRegexTests {

    @Test("Account number positive: pure 9-digit sequence 123456789")
    func accountPositive9Digits() throws {
        let re = try compiled(SavedRegex.builtInAccountNumber.pattern)
        #expect(matches(re, in: "Account: 123456789"))
    }

    @Test("Account number positive: 3-letter prefix ACC1234567890")
    func accountPositiveLetterPrefix() throws {
        let re = try compiled(SavedRegex.builtInAccountNumber.pattern)
        #expect(matches(re, in: "Ref ACC1234567890"))
    }

    @Test("Account number positive: 16-digit 1234567890123456")
    func accountPositive16Digits() throws {
        let re = try compiled(SavedRegex.builtInAccountNumber.pattern)
        #expect(matches(re, in: "Card 1234567890123456"))
    }

    @Test("Account number negative: too short — only 5 digits (12345)")
    func accountNegativeTooShort() throws {
        let re = try compiled(SavedRegex.builtInAccountNumber.pattern)
        #expect(!matches(re, in: "ref 12345"))
    }

    @Test("Account number negative: 4-letter prefix is excluded (ABCD1234567)")
    func accountNegativeFourLetterPrefix() throws {
        let re = try compiled(SavedRegex.builtInAccountNumber.pattern)
        #expect(!matches(re, in: "ABCD1234567"))
    }

    @Test("Account number negative: a standalone 18-digit run has no internal word boundary for the 17-digit window")
    func accountNegativeNoBoundaryIn18DigitRun() throws {
        let re = try compiled(SavedRegex.builtInAccountNumber.pattern)
        // A bare 18-digit string has word boundaries only at the edges.
        // `\b\d{6,17}\b` requires the boundary after the digit run; in a
        // continuous 18-digit run the boundary after 17 digits does not
        // exist, so no sub-span of 6-17 digits satisfies both `\b` anchors.
        let isolated = "123456789012345678"
        #expect(!matches(re, in: isolated))
    }
}
