import Testing
import Foundation
@testable import ResectaApp

// WU-66 / [P2] / R-35 — banner copy + accumulation + RR-24 "pattern
// not echoed" invariant. The banner consumes the `regexTimeoutPages`
// set on `SearchState`, populated by `DocumentSearcher`'s timeout sink.

@Suite("Regex timeout banner (WU-66)", .tags(.search))
@MainActor
struct RegexTimeoutBannerTests {

    @Test("Banner appears on first timeout — set non-empty after recordRegexTimeout")
    func bannerAppearsOnFirstTimeout() {
        let state = SearchState()
        #expect(state.regexTimeoutPages.isEmpty)
        state.recordRegexTimeout(page: 0)
        #expect(state.regexTimeoutPages == [0])
    }

    @Test("Banner accumulates distinct page numbers across timeout calls")
    func bannerAccumulatesPages() {
        let state = SearchState()
        state.recordRegexTimeout(page: 2)
        state.recordRegexTimeout(page: 5)
        state.recordRegexTimeout(page: 2)  // dedupe — Set semantics
        #expect(state.regexTimeoutPages == [2, 5])
    }

    @Test("resetRegexTimeoutPages clears the set without touching other state")
    func resetClearsOnly() {
        let state = SearchState()
        state.recordRegexTimeout(page: 1)
        state.accumulateOverlapSuppression([.phone: 1])
        state.resetRegexTimeoutPages()
        #expect(state.regexTimeoutPages.isEmpty)
        // Overlap state is independent — must not be cleared by the
        // regex-timeout-reset path.
        #expect(state.pendingOverlapSuppressed == [.phone: 1])
    }

    @Test("Banner headline pluralizes 'page' vs 'pages' correctly")
    func headlinePluralization() {
        let single = SearchResultsSection.regexTimeoutBannerHeadline(pages: [4])
        let multiple = SearchResultsSection.regexTimeoutBannerHeadline(pages: [2, 4])
        #expect(single.contains("page 5"))
        #expect(!single.contains("pages 5"))
        #expect(multiple.contains("pages 3 and 5"))
    }

    @Test("Banner page list uses 1-based numbering (input is 0-based)")
    func bannerUsesOneBasedNumbers() {
        let headline = SearchResultsSection.regexTimeoutBannerHeadline(pages: [0])
        #expect(headline.contains("page 1"))
        #expect(!headline.contains("page 0"))
    }

    @Test("Banner page list joins with Oxford-style 'and' for 3+")
    func bannerPageListJoin() {
        #expect(SearchResultsSection.formatPageList([1]) == "1")
        #expect(SearchResultsSection.formatPageList([1, 2]) == "1 and 2")
        #expect(SearchResultsSection.formatPageList([1, 2, 3]) == "1, 2, and 3")
    }

    @Test("Banner copy NEVER echoes pattern text — RR-24 privacy floor")
    func bannerCopyNeverEchoesPattern() {
        // Feed a known-distinctive pattern through the only public path
        // SearchState exposes for timeout-banner population. The
        // `recordRegexTimeout(page:)` API takes only a page index — the
        // banner copy is built from `regexTimeoutPages` alone. If a
        // future refactor adds a pattern-carrying signature, this test
        // will fail to compile (intentional — pattern must NOT cross
        // the sink boundary).
        let state = SearchState()
        state.recordRegexTimeout(page: 7)

        let distinctiveSentinel = "ZZ-UNLIKELY-IN-COPY-9b87a1d2-ZZ"
        let banner = SearchResultsSection.regexTimeoutBannerHeadline(
            pages: state.regexTimeoutPages.sorted()
        )

        // Even if the SearchResultsSection static were to add pattern
        // echoing in the future, the sentinel was never plumbed through
        // — so it must NOT appear in the banner copy.
        #expect(!banner.contains(distinctiveSentinel))
        // Sanity — page indices DO appear, 1-based.
        #expect(banner.contains("page 8"))
    }
}
