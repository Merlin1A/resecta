import Testing
import PDFKit
@testable import RedactionEngine

// End-to-end custom user keywords wired through DocumentSearcher.
//
// Confirms the UserTermMatcher installed via `setUserTerms(_:)` actually
// (a) drops detector matches whose text equals a never-flag term,
// (b) emits synthetic always-flag hits into the SearchResult stream, and
// (c) leaves `.text` / `.regex` / `.multiTerm` modes untouched.

@Suite("DocumentSearcher custom user terms", .tags(.search))
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
        // `setUserTerms(_:)` takes `UserTermsIndex?`; wrap the
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
        // Matches a project-code-shaped pattern (letters, a hyphen, digits).
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

    @Test("Always-flag literal matches a compatibility spelling on the search-normalized text")
    func alwaysFlagLiteralMatchesCompatibilitySpelling() {
        // `shouldSuppress` compares the search-normalized forms (ligature
        // expansion + NFKC + case fold); the always-flag literal search
        // must read the same form, or a term typed as "financial" never
        // sees a page's fullwidth "Ｆinancial" (Foundation's own
        // non-literal search folds Latin ligatures but not the NFKC
        // compatibility forms). The hit range is expressed on the raw text
        // so PDFKit selection bounds resolve on the page's own characters.
        let matcher = UserTermMatcher.compile(
            alwaysFlag: [UserTerm(pattern: "financial", isRegex: false)],
            neverFlag: []
        )
        let fullwidth = matcher.alwaysFlagHits(in: "Quarterly \u{FF26}inancial report")
        #expect(fullwidth.hits.count == 1, "expected one hit on the fullwidth spelling; got \(fullwidth.hits.count)")
        #expect(fullwidth.hits.first?.range == NSRange(location: 10, length: 9),
                "hit range must cover the raw run; got \(String(describing: fullwidth.hits.first?.range))")
        // The ligature spelling (one UTF-16 unit for the two letters) maps
        // back to its raw one-unit range.
        let ligature = matcher.alwaysFlagHits(in: "Quarterly \u{FB01}nancial report")
        #expect(ligature.hits.count == 1)
        #expect(ligature.hits.first?.range == NSRange(location: 10, length: 8))
        // Symmetry with the never-flag comparison on the same input.
        let suppressor = UserTermMatcher.compile(
            alwaysFlag: [], neverFlag: [UserTerm(pattern: "financial", isRegex: false)])
        #expect(suppressor.shouldSuppress("\u{FF26}inancial") != nil)
        #expect(fullwidth.timedOutPatterns.isEmpty)
    }

    @Test("Always-flag literal on a compatibility-spelled page emits a synthetic hit with a resolved rect")
    func alwaysFlagLiteralCompatibilityPageEmits() async {
        let matcher = UserTermMatcher.compile(
            alwaysFlag: [UserTerm(pattern: "financial", isRegex: false)],
            neverFlag: []
        )
        let results = await runPIIScan(
            text: "Quarterly \u{FF26}inancial report",
            categories: [.ssn],
            userTerms: matcher
        )
        let custom = results.filter { $0.term == "Custom" }
        #expect(custom.count == 1, "expected one synthetic hit; got \(custom.count)")
        let rect = custom.first?.normalizedRect ?? .zero
        #expect(rect.width > 0 && rect.height > 0, "the hit must carry a resolved rect")
        #expect(TextNormalizer.normalizeForSearch(custom.first?.matchedText ?? "", caseSensitive: false)
                == "financial")
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
