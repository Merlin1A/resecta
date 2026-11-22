import Testing
import Foundation
import CoreGraphics
import RedactionEngine
@testable import ResectaApp

// The small Search card's Apply reads the walk's current match. The walk
// stops once per match, at its lead line, and the apply for one result
// takes every line of its match; so the card's "Applied" is read over every
// line too. A match wrapped onto two lines whose first line an earlier box
// covers ("John", then a search for "John Smith" that wraps after "John") is
// not applied until its second line is.

@Suite("The card's Apply reads every line of a wrapped match", .tags(.search))
@MainActor
struct CompactApplyWrappedMatchTests {

    private static let johnRect = CGRect(x: 0.62, y: 0.70, width: 0.10, height: 0.03)
    private static let smithRect = CGRect(x: 0.08, y: 0.66, width: 0.11, height: 0.03)

    /// "John Smith" wrapped after "John": two lines on page 0, one occurrence.
    private static func wrapped() -> (john: SearchResult, smith: SearchResult) {
        let occurrence = UUID()
        func line(_ rect: CGRect) -> SearchResult {
            SearchResult(pageIndex: 0, normalizedRect: rect, matchedText: "John Smith",
                         contextSnippet: "…John Smith…", source: .textLayer, term: "John Smith",
                         isSelected: true, occurrenceID: occurrence)
        }
        return (line(johnRect), line(smithRect))
    }

    /// An earlier box over "John", and the search for "John Smith" with its
    /// markers derived from the live regions, stepped to its first stop.
    private static func session() -> (RedactionState, SearchState, john: SearchResult, smith: SearchResult) {
        let redaction = RedactionState()
        redaction.regions[0] = [RedactionRegion(id: UUID(), normalizedRect: johnRect, source: .manual)]
        let (john, smith) = wrapped()
        let search = SearchState()
        search.results = [john, smith]
        redaction.activeSearch = search
        redaction.refreshSearchMarkers(on: search)
        search.navigateToNext(currentPageIndex: 0)
        return (redaction, search, john, smith)
    }

    @Test("With the first line covered and the second not, the current match is not applied")
    func firstLineCoveredIsNotApplied() throws {
        let (_, search, john, smith) = Self.session()
        let current = try #require(search.currentResult)
        #expect(current.id == john.id, "the walk stops at the match's lead line")
        #expect(search.coveredResultIDs == [john.id], "the earlier box covers \"John\" only")
        #expect(!search.isAppliedOrCovered(smith.id))
        #expect(!search.currentMatchAppliedOrCovered, "\"Smith\" has no box yet")
        #expect(!search.selectionFullyApplied, "the header's Apply agrees")
    }

    @Test("The card's apply boxes the second line, and then the match reads applied")
    func applyThenApplied() async throws {
        let (redaction, search, john, smith) = Self.session()
        let current = try #require(search.currentResult)
        let outcome = try #require(await redaction.applyFindings(.searchResult(id: current.id), undoManager: nil))
        #expect(outcome.appliedResultIDs == [smith.id])
        #expect(outcome.coveredResultIDs == [john.id])
        redaction.refreshSearchMarkers(on: search)
        #expect(search.currentMatchAppliedOrCovered)
        #expect(search.selectionFullyApplied)
    }

    @Test("The card reads the match, not the one result, for both its applied and disabled states")
    func cardReadsTheMatch() throws {
        let root = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/ResectaApp/Views/Search/SearchAndRedactSheet+CompactApply.swift"),
            encoding: .utf8)
        #expect(source.components(separatedBy: "searchState.currentMatchAppliedOrCovered").count - 1 == 2)
        #expect(!source.contains("isAppliedOrCovered(current.id)"))
    }
}
