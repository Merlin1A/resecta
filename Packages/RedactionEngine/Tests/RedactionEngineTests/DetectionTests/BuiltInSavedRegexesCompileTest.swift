import Testing
import Foundation
@testable import RedactionEngine

@Suite("Built-in saved regexes compile")
struct BuiltInSavedRegexesCompileTest {

    @Test("Built-in saved regexes ship, all flagged isBuiltIn")
    func builtInsShip() {
        #expect(SavedRegex.allBuiltIns.count == 10)
        #expect(SavedRegex.allBuiltIns.allSatisfy { $0.isBuiltIn })
    }

    @Test("Built-in IDs are stable and unique")
    func idsUnique() {
        let ids = SavedRegex.allBuiltIns.map(\.id)
        #expect(Set(ids).count == ids.count)
        // Stable across calls.
        #expect(ids == SavedRegex.allBuiltIns.map(\.id))
    }

    @Test("Every built-in pattern passes DocumentSearcher.validateRegexPattern")
    func allCompile() {
        for regex in SavedRegex.allBuiltIns {
            let compiled = DocumentSearcher.validateRegexPattern(regex.pattern)
            #expect(compiled != nil, "\(regex.label) failed validateRegexPattern: \(regex.pattern)")
        }
    }

    @Test("Built-in patterns stay within the 200-character cap")
    func patternsWithinCap() {
        for regex in SavedRegex.allBuiltIns {
            #expect(regex.pattern.count <= SavedRegex.patternLengthCap,
                    "\(regex.label) over cap")
        }
    }

    // MARK: - Spot-check positive matches.

    @Test("IPv4 pattern matches a dotted-quad address")
    func ipv4Matches() throws {
        let re = try #require(DocumentSearcher.validateRegexPattern(SavedRegex.builtInIPv4.pattern))
        let haystack = "Connect to 10.0.0.42 for debug"
        let range = NSRange(haystack.startIndex..<haystack.endIndex, in: haystack)
        #expect(re.firstMatch(in: haystack, range: range) != nil)
    }

    @Test("UUID pattern matches a canonical UUID")
    func uuidMatches() throws {
        let re = try #require(DocumentSearcher.validateRegexPattern(SavedRegex.builtInUUID.pattern))
        let haystack = "Correlation 550e8400-e29b-41d4-a716-446655440000 logged"
        let range = NSRange(haystack.startIndex..<haystack.endIndex, in: haystack)
        #expect(re.firstMatch(in: haystack, range: range) != nil)
    }

    @Test("ISO-8601 pattern matches a timestamp")
    func isoMatches() throws {
        let re = try #require(DocumentSearcher.validateRegexPattern(SavedRegex.builtInISO8601.pattern))
        let haystack = "Logged at 2026-04-18T09:30:15Z today"
        let range = NSRange(haystack.startIndex..<haystack.endIndex, in: haystack)
        #expect(re.firstMatch(in: haystack, range: range) != nil)
    }

    @Test("SSN pattern passes validateRegexPattern")
    func ssnCompiles() throws {
        let re = try #require(DocumentSearcher.validateRegexPattern(SavedRegex.builtInSSN.pattern))
        let haystack = "SSN: 123-45-6789"
        let range = NSRange(haystack.startIndex..<haystack.endIndex, in: haystack)
        #expect(re.firstMatch(in: haystack, range: range) != nil)
    }

    @Test("EIN pattern passes validateRegexPattern")
    func einCompiles() throws {
        let re = try #require(DocumentSearcher.validateRegexPattern(SavedRegex.builtInEIN.pattern))
        let haystack = "EIN: 12-3456789"
        let range = NSRange(haystack.startIndex..<haystack.endIndex, in: haystack)
        #expect(re.firstMatch(in: haystack, range: range) != nil)
    }

    @Test("ITIN pattern passes validateRegexPattern")
    func itinCompiles() throws {
        let re = try #require(DocumentSearcher.validateRegexPattern(SavedRegex.builtInITIN.pattern))
        let haystack = "ITIN: 912-70-1234"
        let range = NSRange(haystack.startIndex..<haystack.endIndex, in: haystack)
        #expect(re.firstMatch(in: haystack, range: range) != nil)
    }

    @Test("ABA routing pattern passes validateRegexPattern")
    func abaRoutingCompiles() throws {
        let re = try #require(DocumentSearcher.validateRegexPattern(SavedRegex.builtInABARouting.pattern))
        let haystack = "Routing: 021000021"
        let range = NSRange(haystack.startIndex..<haystack.endIndex, in: haystack)
        #expect(re.firstMatch(in: haystack, range: range) != nil)
    }

    @Test("Account number pattern passes validateRegexPattern")
    func accountNumberCompiles() throws {
        let re = try #require(DocumentSearcher.validateRegexPattern(SavedRegex.builtInAccountNumber.pattern))
        let haystack = "Account: 123456789"
        let range = NSRange(haystack.startIndex..<haystack.endIndex, in: haystack)
        #expect(re.firstMatch(in: haystack, range: range) != nil)
    }
}
