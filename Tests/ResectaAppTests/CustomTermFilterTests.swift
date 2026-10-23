import Testing
import Foundation
import CoreGraphics
import RedactionEngine
@testable import ResectaApp

// Custom-term matches carry no detector category. With a category filter
// active they are listed only while the Scan's "Custom" chip is on; with no
// filter everything is listed.
@Suite("Custom-term matches and the category filter", .tags(.search))
@MainActor
struct CustomTermFilterTests {

    private func session() -> (SearchState, ssn: SearchResult, custom: SearchResult) {
        let state = SearchState(defaults: makeScratchDefaults().0)
        let ssn = SearchResult(
            pageIndex: 0, normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.03),
            matchedText: "123-45-6789", contextSnippet: "…", source: .textLayer, term: "SSN",
            piiCategory: .ssn, piiConfidence: 0.9)
        let custom = SearchResult(
            pageIndex: 0, normalizedRect: CGRect(x: 0.1, y: 0.4, width: 0.2, height: 0.03),
            matchedText: "ACME-4471", contextSnippet: "…", source: .textLayer, term: "ACME-4471")
        state.results = [ssn, custom]
        return (state, ssn, custom)
    }

    @Test("A category filter excludes custom-term matches")
    func categoryFilterExcludesCustom() {
        let (state, ssn, _) = session()
        state.piiCategoryFilter = [.ssn]
        #expect(state.filteredResults.map(\.id) == [ssn.id])
    }

    @Test("The Custom chip alone lists only custom-term matches, and clearing the filter clears it")
    func customChipListsCustom() {
        let (state, _, custom) = session()
        state.piiCategoryFilter = []
        state.customTermMatchesInFilter = true
        #expect(state.filteredResults.map(\.id) == [custom.id])
        #expect(state.customTermMatchCount == 1)
        state.piiCategoryFilter = nil
        #expect(state.customTermMatchesInFilter == false)
        #expect(state.filteredResults.count == 2)
    }
}
