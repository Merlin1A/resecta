import Testing
import Foundation
import CoreGraphics
@testable import ResectaApp
@testable import RedactionEngine

// What a run that replaces the list counts for its notice: the rows that
// were ticked and had no box when the run started. Nothing ticked, or
// every ticked row already boxed, means no notice. A ticked row hidden by
// a filter counts, as the footer counts it; a match on two lines counts
// once. A run a recall started counts nothing (the recall names its own
// drop).

@Suite("Search re-run notice count")
@MainActor
struct SearchRerunNoticeTests {

    private func result(
        page: Int = 0, source: SearchSource = .textLayer, ticked: Bool = false, occurrence: UUID? = nil
    ) -> SearchResult {
        SearchResult(
            pageIndex: page,
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05),
            matchedText: "x",
            contextSnippet: "…x…",
            source: source,
            term: "x",
            isSelected: ticked,
            occurrenceID: occurrence
        )
    }

    private func clearedCount(_ state: SearchState) -> Int {
        SearchAndRedactSheet.rerunClearedCount(in: state)
    }

    @Test("Nothing ticked counts zero, so the run posts no notice")
    func nothingTickedCountsZero() {
        let state = SearchState()
        state.results = (0..<5).map { _ in result() }
        #expect(clearedCount(state) == 0)
        #expect(SearchAndRedactSheet.rerunClearedMessage(selectedCount: clearedCount(state), interface: .search) == nil)
    }

    @Test("Ticked rows that are boxed or under a box count zero")
    func tickedAndBoxedCountsZero() {
        let state = SearchState()
        let a = result(ticked: true), b = result(ticked: true), c = result()
        state.results = [a, b, c]
        state.appliedResultIDs = [a.id]
        state.coveredResultIDs = [b.id]
        #expect(clearedCount(state) == 0)
    }

    @Test("Ticked rows without a box are counted: 12, and 7 when 5 of them are boxed")
    func tickedWithoutABoxAreCounted() {
        let state = SearchState()
        let ticked = (0..<12).map { _ in result(ticked: true) }
        state.results = ticked + (0..<4).map { _ in result() }
        #expect(clearedCount(state) == 12)
        state.appliedResultIDs = Set(ticked.prefix(5).map(\.id))
        #expect(clearedCount(state) == 7)
    }

    @Test("Ticked rows hidden by a filter are counted")
    func tickedRowsHiddenByAFilterAreCounted() {
        let state = SearchState()
        state.results = [
            result(ticked: true),
            result(source: .ocr(confidence: 0.9), ticked: true),
            result(source: .ocr(confidence: 0.9), ticked: true),
        ]
        state.sourceFilter = .textOnly
        #expect(state.filteredResults.count == 1)
        #expect(clearedCount(state) == 3)
    }

    @Test("A ticked match on two lines counts once")
    func aWrappedMatchCountsOnce() {
        let state = SearchState()
        let occurrence = UUID()
        state.results = [result(ticked: true, occurrence: occurrence), result(page: 0, ticked: true, occurrence: occurrence)]
        #expect(clearedCount(state) == 1)
    }

    @Test("A recall's run counts nothing, so only the recall's own message is posted")
    func aRecallKeepsItsOwnMessage() {
        let state = SearchState()
        state.results = [result(ticked: true), result(ticked: true)]
        state.skipNextRerunNotice = true
        #expect(clearedCount(state) == 0)
        #expect(SearchAndRedactSheet.rerunClearedCount(selectedUnapplied: 2, skipNotice: true) == 0)
        #expect(SearchAndRedactSheet.rerunClearedCount(selectedUnapplied: 2, skipNotice: false) == 2)
    }
}
