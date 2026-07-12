import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

// WU-22 — Sort migrated from `SearchFooterSection` to a chip-row
// consumer in `SearchToolbarSection.chipRowSubstrate`. The Sort
// `Menu` itself is gone from the footer; the chip's binding writes
// `searchState.sortOrder` directly via the existing didSet path.
// This suite pins the chip's two pure-function contracts
// (`sortChipLabel`, `sortChipAccessibilityLabel`) and the SearchState
// binding behavior post-relocation.

@Suite("Sort chip (WU-22)", .tags(.search))
@MainActor
struct SortChipTests {

    @Test("sortChipLabel reads 'Sort' for the default discovery order")
    func labelDefault() {
        #expect(SearchToolbarSection.sortChipLabel(active: .discoveryOrder) == "Sort")
    }

    @Test("sortChipLabel surfaces the active sort rawValue for non-default orders")
    func labelNonDefault() {
        #expect(SearchToolbarSection.sortChipLabel(active: .confidenceDescending) == "Confidence")
        #expect(SearchToolbarSection.sortChipLabel(active: .pageAscending) == "Page")
    }

    @Test("sortChipAccessibilityLabel surfaces the active sort verbatim")
    func a11yLabel() {
        #expect(
            SearchToolbarSection.sortChipAccessibilityLabel(active: .discoveryOrder)
                == "Sort order, currently Default"
        )
        #expect(
            SearchToolbarSection.sortChipAccessibilityLabel(active: .confidenceDescending)
                == "Sort order, currently Confidence"
        )
        #expect(
            SearchToolbarSection.sortChipAccessibilityLabel(active: .pageAscending)
                == "Sort order, currently Page"
        )
    }

    @Test("Setting searchState.sortOrder invalidates the filter cache")
    func sortOrderInvalidatesCache() {
        let state = SearchState()
        let r1 = makeResult(piiConfidence: 0.7)
        let r2 = makeResult(piiConfidence: 0.95)
        state.results = [r1, r2]

        // Default order: discovery → r1 then r2.
        let discovery = state.filteredResults
        #expect(discovery.map(\.id) == [r1.id, r2.id])

        // Flip to confidence-descending; cache should re-key + reorder.
        state.sortOrder = .confidenceDescending
        let confSorted = state.filteredResults
        #expect(confSorted.map(\.id) == [r2.id, r1.id])
    }

    @Test("ResultSortOrder rawValues stay locked — case renames are migration events per RR-05")
    func rawValueContract() {
        // Pinning prevents accidental rename — `SavedSearchStore`
        // (post-WU-26) decodes against these strings.
        #expect(ResultSortOrder.discoveryOrder.rawValue == "Default")
        #expect(ResultSortOrder.confidenceDescending.rawValue == "Confidence")
        #expect(ResultSortOrder.pageAscending.rawValue == "Page")
    }

    // MARK: - Helpers

    private func makeResult(piiConfidence: Double? = nil) -> SearchResult {
        SearchResult(
            pageIndex: 0,
            normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.04),
            matchedText: "x",
            contextSnippet: "…",
            source: .textLayer,
            term: "x",
            isSelected: false,
            piiCategory: piiConfidence == nil ? nil : .ssn,
            piiConfidence: piiConfidence
        )
    }
}
