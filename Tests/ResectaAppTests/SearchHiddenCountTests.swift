import CoreGraphics
import Foundation
import Testing
@testable import ResectaApp
import RedactionEngine

// K2-05 and K2-06 on the session: the statement's hidden count is every
// match a filter hides, ticked or not, and a wrapped match counts once.

@Suite("Search statement: the hidden count", .tags(.search))
@MainActor
struct SearchHiddenCountTests {

    static func result(page: Int, source: SearchSource, occurrence: UUID? = nil) -> SearchResult {
        SearchResult(pageIndex: page, normalizedRect: CGRect(x: 0.1, y: 0.1 + 0.05 * Double(page), width: 0.2, height: 0.03),
                     matchedText: "Delia", contextSnippet: "…Delia…", source: source, term: "Delia",
                     occurrenceID: occurrence)
    }

    /// Two typed matches, and three read by recognition, one of them wrapped over two lines.
    static func session() -> SearchState {
        let state = SearchState(defaults: makeScratchDefaults().0)
        let wrapped = UUID()
        let results = [
            result(page: 0, source: .textLayer), result(page: 1, source: .textLayer),
            result(page: 2, source: .ocr(confidence: 0.9)), result(page: 3, source: .ocr(confidence: 0.9)),
            result(page: 4, source: .ocr(confidence: 0.9), occurrence: wrapped),
            result(page: 4, source: .ocr(confidence: 0.9), occurrence: wrapped),
        ]
        for result in results { state.appendResult(result) }
        state.flushPendingResults()
        return state
    }

    @Test("No filter: none hidden")
    func noFilter() {
        #expect(Self.session().hiddenByFilterCount == 0)
    }

    @Test("K2-05: the typed-only filter hides the three recognised matches, none of them ticked")
    func untickedHidden() {
        let state = Self.session()
        state.sourceFilter = .textOnly
        #expect(state.hiddenByFilterCount == 3)
    }

    @Test("K2-06: the same, every match ticked: still three")
    func tickedHidden() {
        let state = Self.session()
        state.toggleSelectAll()
        state.sourceFilter = .textOnly
        #expect(state.hiddenByFilterCount == 3)
    }
}
