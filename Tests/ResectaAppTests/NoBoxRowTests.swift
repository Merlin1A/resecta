import Testing
import Foundation
import CoreGraphics
import RedactionEngine
@testable import ResectaApp

/// K-03 in the app: a match with no box is listed, never selected, never
/// applied, and not counted by Select All; its row carries BR-06's words.
@Suite("A hit with no box: the app's side", .tags(.search))
@MainActor
struct NoBoxRowTests {

    static func boxed(page: Int = 0, selected: Bool = false, occurrence: UUID? = nil) -> SearchResult {
        SearchResult(pageIndex: page, normalizedRect: CGRect(x: 0.1, y: 0.5, width: 0.3, height: 0.02),
                     matchedText: "QUARTZ7", contextSnippet: "ref QUARTZ7 filed", source: .textLayer,
                     term: "QUARTZ7", isSelected: selected, occurrenceID: occurrence)
    }

    static func unboxed(page: Int = 0, selected: Bool = false, occurrence: UUID? = nil, offPage: Bool = false) -> SearchResult {
        SearchResult(pageIndex: page, normalizedRect: .zero, matchedText: "QUARTZ7", contextSnippet: "ref QUARTZ7 filed",
                     source: .textLayer, term: "QUARTZ7", isSelected: selected, occurrenceID: occurrence,
                     hasBox: false, liesOffVisiblePage: offPage)
    }

    @Test("K3-05 Apply with one ordinary and one unboxed result makes one box; the unboxed row stays listed")
    func applyMakesOneBox() {
        let ordinary = Self.boxed(selected: true)
        let noBox = Self.unboxed(selected: true)
        let prepared = prepareApply(selected: [ordinary, noBox], existingRectsByPage: [:], existingStripRectsByPage: [:],
                                    appliedAt: Date(), searchRecord: nil)
        #expect(prepared.createdRegions[0]?.count == 1, "one box, for the ordinary result")
        #expect(prepared.createdRegions[0]?.first?.normalizedRect == ordinary.normalizedRect)
    }

    @Test("No predicate selects a result with no box")
    func neverSelected() {
        let state = SearchState()
        state.results = [Self.boxed(), Self.unboxed()]
        state.setSelection { _ in true }
        #expect(state.results.map(\.isSelected) == [true, false])
        state.toggleSelection(for: state.results[1].id)
        #expect(state.results[1].isSelected == false, "its row has no tick box to toggle")
    }

    @Test("Select All neither counts nor blocks on a result with no box")
    func selectAllSkipsIt() {
        let state = SearchState()
        state.results = [Self.boxed(), Self.unboxed()]
        state.toggleSelectAll()
        #expect(state.results.map(\.isSelected) == [true, false], "Select All ticks the boxed result")
        state.toggleSelectAll()
        #expect(state.results.map(\.isSelected) == [false, false], "a second press is Deselect All")
    }

    @Test("A result with no box is not a deselection, and it counts as found")
    func counts() {
        let state = SearchState()
        state.results = [Self.boxed(), Self.unboxed()]
        #expect(state.deselectedCount == 1, "only the boxed result was left un-ticked")
        #expect(state.totalCount == 2, "both are found matches")
    }

    @Test("A match across a page break whose first part has no box is selected by its boxed part")
    func seamOccurrence() {
        let occurrence = UUID()
        let state = SearchState()
        state.results = [Self.unboxed(page: 0, occurrence: occurrence), Self.boxed(page: 1, occurrence: occurrence)]
        state.toggleSelectAll()
        #expect(state.results.map(\.isSelected) == [false, true])
    }

    @Test("The row's words are BR-06, word for word; off the visible page, its first sentence alone")
    func words() {
        #expect(NoBoxRowCopy.sentence(pageIndex: 20, liesOffVisiblePage: false)
                == "Found on page 21, but Resecta can't place a box on it. If you can see it there, draw a box by hand.")
        #expect(NoBoxRowCopy.sentence(pageIndex: 20, liesOffVisiblePage: true)
                == "Found on page 21, but Resecta can't place a box on it.")
        let label = SearchResultRow.accessibilityLabel(for: Self.unboxed(page: 2), tier: .high, showsTier: false)
        #expect(label.hasSuffix("Found on page 3, but Resecta can't place a box on it. If you can see it there, draw a box by hand."))
    }
}
