import Testing
import PDFKit
@testable import RedactionEngine

// W3 — end-to-end custom user keywords wired through DocumentSearcher.
//
// Confirms the UserTermMatcher installed via `setUserTerms(_:)` actually
// (a) drops detector matches whose text equals a never-flag term,
// (b) emits synthetic always-flag hits into the SearchResult stream, and
// (c) leaves `.text` / `.regex` / `.multiTerm` modes untouched.

@Suite("DocumentSearcher custom user terms (W3)", .tags(.search))
struct DocumentSearcherUserTermsTests {

    private func runPIIScan(
        text: String,
        categories: Set<PIICategory>,
        userTerms: UserTermMatcher?
    ) async -> [SearchResult] {
        let data = TestFixtures.textLayerPDF(text: text)
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return []
        }
        let searcher = DocumentSearcher()
        // W-P — `setUserTerms(_:)` takes `UserTermsIndex?`; wrap the
        // legacy `UserTermMatcher` test fixture via the wrapping init.
        await searcher.setUserTerms(userTerms.map { UserTermsIndex(matcher: $0) })
        let mode = SearchMode.piiScan(categories: categories, options: SearchOptions())
        let stream = searcher.search(
            SendablePDFDocument(doc), mode: mode, progress: { _, _ in }
        )
        var results: [SearchResult] = []
        for await result in stream { results.append(result) }
        return results
    }

    private func runTextSearch(
        text: String,
        query: String,
        userTerms: UserTermMatcher?
    ) async -> [SearchResult] {
        let data = TestFixtures.textLayerPDF(text: text)
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return []
        }
        let searcher = DocumentSearcher()
        await searcher.setUserTerms(userTerms.map { UserTermsIndex(matcher: $0) })
        let mode = SearchMode.text(query, options: SearchOptions())
        let stream = searcher.search(
            SendablePDFDocument(doc), mode: mode, progress: { _, _ in }
        )
        var results: [SearchResult] = []
        for await result in stream { results.append(result) }
        return results
    }

    // MARK: - Always-flag emission

    @Test("Always-flag literal emits a synthetic SearchResult")
    func alwaysFlagLiteralEmits() async {
        let matcher = UserTermMatcher.compile(
            alwaysFlag: [UserTerm(pattern: "Acme Corp", isRegex: false)],
            neverFlag: []
        )
        let results = await runPIIScan(
            text: "Invoice from Acme Corp dated 2025-01-01",
            categories: [.ssn],
            userTerms: matcher
        )
        let acme = results.first { $0.matchedText.lowercased() == "acme corp" }
        #expect(acme != nil, "always-flag literal should emit a synthetic hit")
        #expect(acme?.piiCategory == nil, "synthetic hits have no PII category")
        #expect(acme?.term == "Custom", "synthetic hits are tagged Custom")
    }

    @Test("Always-flag literal matches case-insensitively")
    func alwaysFlagLiteralCaseInsensitive() async {
        let matcher = UserTermMatcher.compile(
            alwaysFlag: [UserTerm(pattern: "acme corp", isRegex: false)],
            neverFlag: []
        )
        let results = await runPIIScan(
            text: "Invoice from ACME CORP dated 2025-01-01",
            categories: [.ssn],
            userTerms: matcher
        )
        #expect(results.contains(where: { $0.term == "Custom" }),
                "literal matching should be case-insensitive")
    }

    @Test("Always-flag regex emits a synthetic hit")
    func alwaysFlagRegexEmits() async {
        // Matches a project-code pattern like "PROJ-1234".
        let matcher = UserTermMatcher.compile(
            alwaysFlag: [UserTerm(pattern: "PROJ-[0-9]{4}", isRegex: true)],
            neverFlag: []
        )
        let results = await runPIIScan(
            text: "Reference number PROJ-4821 in discussion",
            categories: [.ssn],
            userTerms: matcher
        )
        let proj = results.first { $0.matchedText == "PROJ-4821" }
        #expect(proj != nil, "regex always-flag should emit a synthetic hit")
        #expect(proj?.term == "Custom")
    }

    // MARK: - Never-flag suppression

    @Test("Never-flag literal drops a detector match with equal text")
    func neverFlagLiteralDropsDetectorHit() async {
        // Baseline: SSN detector finds this string without a matcher.
        let baseline = await runPIIScan(
            text: "SSN: 123-45-6789 on record",
            categories: [.ssn],
            userTerms: nil
        )
        #expect(baseline.contains(where: { $0.piiCategory == .ssn }),
                "baseline must surface SSN hit before we test suppression")

        let matcher = UserTermMatcher.compile(
            alwaysFlag: [],
            neverFlag: [UserTerm(pattern: "123-45-6789", isRegex: false)]
        )
        let suppressed = await runPIIScan(
            text: "SSN: 123-45-6789 on record",
            categories: [.ssn],
            userTerms: matcher
        )
        #expect(!suppressed.contains(where: { $0.piiCategory == .ssn }),
                "never-flag literal equal to matchedText must drop the hit")
    }

    @Test("Never-flag regex drops matching detector hits")
    func neverFlagRegexDropsDetectorHit() async {
        let matcher = UserTermMatcher.compile(
            alwaysFlag: [],
            // Anchored SSN shape — matches the full matchedText "123-45-6789".
            neverFlag: [UserTerm(pattern: "^\\d{3}-\\d{2}-\\d{4}$", isRegex: true)]
        )
        let results = await runPIIScan(
            text: "SSN: 123-45-6789 on record",
            categories: [.ssn],
            userTerms: matcher
        )
        #expect(!results.contains(where: { $0.piiCategory == .ssn }),
                "never-flag regex matching full matchedText must drop the hit")
    }

    @Test("Never-flag regex must span the full matchedText to suppress")
    func neverFlagRegexRequiresFullMatch() async {
        // Pattern matches a single digit — should NOT suppress a 9-digit SSN.
        let matcher = UserTermMatcher.compile(
            alwaysFlag: [],
            neverFlag: [UserTerm(pattern: "\\d", isRegex: true)]
        )
        let results = await runPIIScan(
            text: "SSN: 123-45-6789 on record",
            categories: [.ssn],
            userTerms: matcher
        )
        #expect(results.contains(where: { $0.piiCategory == .ssn }),
                "partial regex match must not suppress the detector hit")
    }

    // MARK: - Mode isolation

    @Test("Text search ignores user terms entirely")
    func textSearchIgnoresUserTerms() async {
        let matcher = UserTermMatcher.compile(
            alwaysFlag: [UserTerm(pattern: "Acme Corp", isRegex: false)],
            neverFlag: [UserTerm(pattern: "banana", isRegex: false)]
        )
        let results = await runTextSearch(
            text: "banana smoothie recipe",
            query: "banana",
            userTerms: matcher
        )
        #expect(results.count >= 1,
                "never-flag must not affect .text mode — user's direct query is intent")
        #expect(!results.contains(where: { $0.term == "Custom" }),
                "always-flag must not emit in .text mode")
    }
}
