import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

// WU-21 — multi-term chips append `(N)` count badges using
// `searchState.resultsByTerm[term]?.count ?? 0`. 0-count chips render at
// reduced opacity. The chip view reads the same `resultsByTerm`
// dictionary the rest of the results list reads; this suite pins the
// per-term count contract so the chip label stays in sync with the
// grouped sections.

@Suite("Multi-term chip count badges (WU-21)", .tags(.search))
@MainActor
struct MultiTermChipCountTests {

    @Test("resultsByTerm returns per-term counts for chip rendering")
    func resultsByTermPerTermCounts() {
        let state = SearchState()
        state.searchModeType = .multiTerm
        state.searchTerms = ["alpha", "beta", "gamma"]
        state.results = [
            makeResult(term: "alpha", page: 0),
            makeResult(term: "alpha", page: 1),
            makeResult(term: "beta", page: 0),
        ]

        #expect(state.resultsByTerm["alpha"]?.count == 2)
        #expect(state.resultsByTerm["beta"]?.count == 1)
        #expect(state.resultsByTerm["gamma"] == nil)
    }

    @Test("Zero-count term reads 0 via nil-coalesce — chip dims to 0.6 opacity")
    func zeroCountChipUsesNilCoalesce() {
        let state = SearchState()
        state.searchModeType = .multiTerm
        state.searchTerms = ["foo", "bar"]
        state.results = [makeResult(term: "foo", page: 0)]

        let fooCount = state.resultsByTerm["foo"]?.count ?? 0
        let barCount = state.resultsByTerm["bar"]?.count ?? 0

        #expect(fooCount == 1)
        #expect(barCount == 0)
    }

    private func makeResult(term: String, page: Int) -> SearchResult {
        SearchResult(
            pageIndex: page,
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05),
            matchedText: term,
            contextSnippet: "…\(term)…",
            source: .textLayer,
            term: term
        )
    }
}
