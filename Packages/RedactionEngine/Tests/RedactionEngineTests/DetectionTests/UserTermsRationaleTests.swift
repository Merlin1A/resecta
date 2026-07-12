import Testing
import PDFKit
@testable import RedactionEngine

// W3 — synthetic always-flag hits must carry a MatchRationale that
// identifies them as user-authored. The rationale drives the
// `MatchRationaleSheet` disclosure (which already renders
// `userAlwaysFlag` / `userNeverFlag` cases) and will flow into the W5
// audit export.

@Suite("MatchRationale emission for W3 always-flag hits")
struct UserTermsRationaleTests {

    private func scan(
        text: String,
        matcher: UserTermMatcher
    ) async -> [SearchResult] {
        let data = TestFixtures.textLayerPDF(text: text)
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return []
        }
        let searcher = DocumentSearcher()
        // W-P — wrap legacy UserTermMatcher fixture in UserTermsIndex.
        await searcher.setUserTerms(UserTermsIndex(matcher: matcher))
        let mode = SearchMode.piiScan(
            categories: Set(PIICategory.allCases), options: SearchOptions()
        )
        let stream = searcher.search(
            SendablePDFDocument(doc), mode: mode, progress: { _, _ in }
        )
        var out: [SearchResult] = []
        for await r in stream { out.append(r) }
        return out
    }

    @Test("Always-flag literal hit carries userAlwaysFlag signal with pattern")
    func alwaysFlagLiteralCarriesSignal() async {
        let matcher = UserTermMatcher.compile(
            alwaysFlag: [UserTerm(pattern: "Acme Corp", isRegex: false)],
            neverFlag: []
        )
        let results = await scan(
            text: "Invoice from Acme Corp dated 2025-01-01",
            matcher: matcher
        )
        let acme = results.first { $0.term == "Custom" }
        let rationale = try! #require(acme?.rationale)
        #expect(rationale.ruleID == "user.alwaysFlag")
        #expect(rationale.signals.contains(.userAlwaysFlag(pattern: "Acme Corp")))
        #expect(rationale.preThresholdScore == 1.0)
        #expect(rationale.finalScore == 1.0)
        #expect(rationale.appliedThreshold == nil)
    }

    @Test("Always-flag regex hit carries userAlwaysFlag signal with source pattern")
    func alwaysFlagRegexCarriesSignal() async {
        let pattern = "PROJ-[0-9]{4}"
        let matcher = UserTermMatcher.compile(
            alwaysFlag: [UserTerm(pattern: pattern, isRegex: true)],
            neverFlag: []
        )
        let results = await scan(
            text: "Reference PROJ-4821 is relevant",
            matcher: matcher
        )
        // W10: PROJ-4821 now also matches the Bates labeled pattern, so
        // filter by term == "Custom" to reach the synthetic always-flag
        // hit. Downstream `applySearchResults` 80 %-overlap dedup collapses
        // the duplicate in the UI layer; here we assert the rationale the
        // always-flag path emits.
        let proj = results.first { $0.term == "Custom" && $0.matchedText == "PROJ-4821" }
        let rationale = try! #require(proj?.rationale)
        #expect(rationale.signals.contains(.userAlwaysFlag(pattern: pattern)),
                "signal pattern must echo the user-authored regex, not the matched text")
    }
}
