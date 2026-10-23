import Testing
import Foundation
import CoreGraphics
@testable import ResectaApp
import RedactionEngine

// The sheet's ✓ markers are derived from the live document, never stored
// apart from it: a result is applied while its applied region is live, and
// covered while a live region covers it. An unrelated edit cannot wipe a
// marker, an undo removes it, and a redo brings it back.
@Suite("Applied markers derived from the live regions", .tags(.search))
@MainActor
struct AppliedMarkerDerivationTests {

    private func session() -> SearchState {
        let state = SearchState(defaults: makeScratchDefaults().0)
        state.results = (0..<3).map { index in
            SearchResult(
                pageIndex: 0,
                normalizedRect: CGRect(x: 0.1, y: 0.1 + 0.2 * CGFloat(index), width: 0.2, height: 0.03),
                matchedText: "alpha", contextSnippet: "…alpha…", source: .textLayer, term: "alpha")
        }
        return state
    }

    @Test("A strip-applied result stays marked through an unrelated edit")
    func unrelatedEditKeepsTheMarker() async throws {
        let redaction = RedactionState()
        let search = session()
        redaction.activeSearch = search
        let third = try #require(search.results.last)

        _ = await redaction.applyFindings(.searchResult(id: third.id), undoManager: nil)
        redaction.addRegion(RedactionRegion(
            id: UUID(), normalizedRect: CGRect(x: 0.6, y: 0.8, width: 0.2, height: 0.1), source: .manual),
            page: 0, undoManager: nil)

        #expect(redaction.derivedSearchMarkers(for: search.results).applied == [third.id])
    }

    @Test("Undo unmarks an applied result and redo marks it again")
    func undoAndRedoFollowTheRegion() async throws {
        let redaction = RedactionState()
        let search = session()
        redaction.activeSearch = search
        let first = try #require(search.results.first)
        let undo = makeUndoManager()

        undo.beginUndoGrouping()
        _ = await redaction.applyFindings(.searchResult(id: first.id), undoManager: undo)
        undo.endUndoGrouping()
        #expect(redaction.derivedSearchMarkers(for: search.results).applied == [first.id])

        undo.undo()
        #expect(redaction.derivedSearchMarkers(for: search.results).applied.isEmpty)
        undo.redo()
        #expect(redaction.derivedSearchMarkers(for: search.results).applied == [first.id])
    }

    @Test("A result a live region covers reads covered, and one it does not reads neither")
    func coveredFollowsTheLiveRegions() throws {
        let redaction = RedactionState()
        let search = session()
        let first = try #require(search.results.first)
        redaction.addRegion(RedactionRegion(
            id: UUID(), normalizedRect: first.normalizedRect.insetBy(dx: -0.01, dy: -0.01), source: .manual),
            page: 0, undoManager: nil)

        let markers = redaction.derivedSearchMarkers(for: search.results)
        #expect(markers.covered == [first.id])
        #expect(markers.applied.isEmpty)
    }
}
