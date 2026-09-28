import Testing
import Foundation
@testable import RedactionEngine

// The applied-Scan record: a scan is one more `AppliedSearchQuery.Kind`
// (identity = the category set + the options), its run configuration
// rides the RECORD (never the identity), and a re-check request carries
// its origin and the items the user left unselected.

@Suite("Applied scan query and request")
struct AppliedSearchQueryScanTests {

    private func scan(_ categories: Set<PIICategory>, options: SearchOptions = SearchOptions()) -> AppliedSearchQuery {
        AppliedSearchQuery(kind: .piiScan(categories: categories), options: options)
    }

    @Test("Identity: the category set + options; the configuration is not part of it")
    func scanIdentity() {
        let a = scan([.ssn, .name])
        let b = scan([.name, .ssn])
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        #expect(scan([.ssn]) != a)
        var cs = SearchOptions()
        cs.caseSensitive = true
        #expect(scan([.ssn, .name], options: cs) != a)

        let balanced = ScanRunConfiguration(
            thresholdVector: PresetThresholdVector(thresholdsByWireName: ["ssn": 0.5]))
        let conservative = ScanRunConfiguration(
            thresholdVector: PresetThresholdVector(thresholdsByWireName: ["ssn": 0.9]),
            alwaysFlag: [UserTerm(pattern: "ACME", isRegex: false)])
        let first = AppliedSearchRecord(query: a, foundCount: 3, scanConfiguration: balanced)
        let second = AppliedSearchRecord(query: b, foundCount: 5, scanConfiguration: conservative)
        // Two applies of the same scan are ONE request: the app groups by
        // query, and the record (the latest apply's) carries the configuration.
        #expect(first.query == second.query)
        #expect(first != second)
        #expect(Set([first.query, second.query]).count == 1)
        #expect(second.scanConfiguration == conservative)
        #expect(first.scanConfiguration != second.scanConfiguration)
        #expect(AppliedSearchRecord(query: a, foundCount: 0).scanConfiguration == nil)
    }

    @Test("searchMode maps the scan to .piiScan with the same categories and options")
    func scanSearchMode() {
        var options = SearchOptions()
        options.includeOCR = false
        let query = scan([.email, .phone], options: options)
        guard case .piiScan(let categories, let mapped) = query.searchMode else {
            Issue.record("expected .piiScan, got \(query.searchMode)")
            return
        }
        #expect(categories == [.email, .phone])
        #expect(mapped == options)
    }

    @Test("Display forms: the label counts detectors, the text is the bare word")
    func scanDisplayForms() {
        let all = scan(Set(PIICategory.allCases))
        #expect(all.displayLabel == "Scan (\(PIICategory.allCases.count) detectors)")
        #expect(all.displayText == "Scan")
        #expect(scan([.ssn]).displayLabel == "Scan (1 detector)")
        #expect(all.optionBadges.isEmpty)
        #expect(all.isScan)
        #expect(!AppliedSearchQuery(kind: .text("x"), options: SearchOptions()).isScan)
    }

    @Test("The configuration compiles its user terms; empty inputs compile to no index")
    func configurationUserTerms() {
        let empty = ScanRunConfiguration(thresholdVector: nil)
        #expect(empty.userTermsIndex == nil)
        let terms = ScanRunConfiguration(
            thresholdVector: nil,
            alwaysFlag: [UserTerm(pattern: "ACME", isRegex: false)],
            neverFlag: [UserTerm(pattern: "public", isRegex: false)])
        let index = try? #require(terms.userTermsIndex)
        #expect(index?.isEmpty == false)
        #expect(index?.decision(for: "ACME") == .alwaysFlag(pattern: "ACME"))
    }

    @Test("A request defaults to the applied origin with nothing deselected; a sweep request carries its origin")
    func requestOriginAndDeselection() {
        let record = AppliedSearchRecord(query: scan([.ssn]), foundCount: 2)
        let applied = SearchRecheckRequest(record: record, appliedCount: 2, appliedPages: [0])
        #expect(applied.origin == .applied)
        #expect(applied.deselected.isEmpty)
        let left = SearchResult(
            pageIndex: 0, normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05),
            matchedText: "123-45-6789", contextSnippet: "", source: .textLayer,
            term: PIICategory.ssn.rawValue, piiCategory: .ssn)
        let withLeft = SearchRecheckRequest(
            record: record, appliedCount: 1, appliedPages: [0], deselected: [left])
        #expect(withLeft.deselected == [left])
        #expect(withLeft != applied)
        let sweep = SearchRecheckRequest(
            record: AppliedSearchRecord(query: scan(Set(PIICategory.allCases)), foundCount: 0),
            appliedCount: 0, appliedPages: [], origin: .sweep)
        #expect(sweep.origin == .sweep)
        #expect(Set([applied, withLeft, sweep]).count == 3)
    }
}
