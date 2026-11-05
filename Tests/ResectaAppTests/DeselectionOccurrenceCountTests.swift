import Testing
import Foundation
import CoreGraphics
import RedactionEngine
@testable import ResectaApp

// A match wrapped onto two lines is two result rows sharing one occurrence
// id. The sheet counts matches by occurrence (`SearchState.occurrenceCount`):
// the total and the selected count already do. The count of matches left
// unselected, on the sheet and in the run's snapshot, counts the same way, so
// "You left N of T detected items unredacted." has one unit on both sides.
// The snapshot's items stay one per line: the output re-check pairs each
// line's box.

@Suite("Deselected matches are counted by occurrence", .tags(.search))
@MainActor
struct DeselectionOccurrenceCountTests {

    private static let wrappedID = UUID()

    /// One line of the wrapped name: two lines on page 0, one shared id.
    private func wrappedLine(_ line: Int, selected: Bool) -> SearchResult {
        SearchResult(
            pageIndex: 0,
            normalizedRect: CGRect(x: 0.6, y: 0.70 - 0.04 * CGFloat(line), width: 0.3, height: 0.03),
            matchedText: "Marisol Vance-Oduya", contextSnippet: "…Marisol Vance-Oduya…",
            source: .ocr(confidence: 0.9), term: "Name", isSelected: selected,
            piiCategory: .name, piiConfidence: 0.9, occurrenceID: Self.wrappedID)
    }

    /// A single-line SSN on its own row.
    private func ssn(_ index: Int, page: Int = 0, selected: Bool) -> SearchResult {
        SearchResult(
            pageIndex: page,
            normalizedRect: CGRect(x: 0.1, y: 0.3 + 0.05 * CGFloat(index), width: 0.2, height: 0.03),
            matchedText: "487-63-22\(10 + index)", contextSnippet: "…487-63-22\(10 + index)…",
            source: .ocr(confidence: 0.9), term: "SSN", isSelected: selected,
            piiCategory: .ssn, piiConfidence: 0.9)
    }

    /// A `.piiScan` session with a stored scan report over `results`.
    private func scanSession(_ results: [SearchResult]) -> SearchState {
        let state = SearchState()
        state.searchModeType = .piiScan
        state.results = results
        state.setCoverageReport(CoverageReport(
            scannedPageCount: 1,
            enabledCategories: [.ssn, .name],
            candidateCountByCategory: [.name: 1, .ssn: 1],
            appliedCount: 0,
            deselectedCount: 0,
            belowThresholdSuppressedCount: 0,
            overlapSuppressedCountByCategory: [:],
            startedAt: Date(timeIntervalSince1970: 0),
            completedAt: Date(timeIntervalSince1970: 1)))
        return state
    }

    @Test("A wrapped match left unselected counts once, and the selected and unselected counts add up to the total")
    func sheetCountsTheWrappedMatchOnce() {
        let search = scanSession([wrappedLine(0, selected: false), wrappedLine(1, selected: false), ssn(0, selected: true)])
        #expect(search.totalCount == 2)
        #expect(search.selectedCount == 1)
        #expect(search.deselectedCount == 1, "the wrapped match is one match, not two")
        #expect(search.selectedCount + search.deselectedCount == search.totalCount)
    }

    @Test("The run's snapshot counts the wrapped match once and keeps both of its lines as items")
    func snapshotCountsOnceKeepsBothLines() throws {
        let search = scanSession([wrappedLine(0, selected: false), wrappedLine(1, selected: false), ssn(0, selected: true)])
        let snapshot = try #require(search.deselectionSnapshotForRun())
        #expect(snapshot.deselectedCount == 1)
        #expect(snapshot.items.count == 2, "both lines still ride to the output re-check")
        #expect(snapshot.totalCount == 2)
    }

    @Test("After the apply commit, the results line reads one of two")
    func applyCommitLineReadsOneOfTwo() async throws {
        let redaction = RedactionState()
        redaction.activeSearch = scanSession([wrappedLine(0, selected: false), wrappedLine(1, selected: false), ssn(0, selected: true)])

        _ = await redaction.applyFindings(.selectedSearchResults, undoManager: nil)

        let pending = try #require(redaction.pendingRunDeselection)
        #expect(pending.deselectedCount == 1)
        let atRun = try #require(redaction.runEntryDeselectionSnapshot())
        #expect(atRun.deselectedCount == 1)
        #expect(atRun.items.count == 2)
        #expect(VerificationResultsView.deselectionRowText(deselected: atRun.deselectedCount, total: atRun.totalCount)
                == "You left 1 of 2 detected items unredacted.")
    }

    @Test("A strip apply of the wrapped match leaves one unselected; Undo puts it back as one, not two")
    func stripApplyThenUndoCountsTheWrappedMatchOnce() async throws {
        let redaction = RedactionState()
        let search = scanSession([wrappedLine(0, selected: false), wrappedLine(1, selected: false), ssn(0, selected: false)])
        redaction.activeSearch = search
        let undo = makeUndoManager()
        let lead = try #require(search.results.first)

        undo.beginUndoGrouping()
        let outcome = await redaction.applyFindings(.searchResult(id: lead.id), undoManager: undo)
        undo.endUndoGrouping()
        try #require((outcome?.applied ?? 0) >= 1, "precondition: the strip applied the wrapped match")
        #expect(redaction.runEntryDeselectionSnapshot()?.deselectedCount == 1, "the SSN alone is left")

        undo.undo()
        #expect(redaction.runEntryDeselectionSnapshot()?.deselectedCount == 2,
                "the wrapped match is back as one match beside the SSN")
    }

    @Test("Merged snapshots of two sessions sum their counts by occurrence")
    func mergedSnapshotsCountByOccurrence() throws {
        func pair() -> [SearchResult] {
            let id = UUID()
            return (0..<2).map { line in
                SearchResult(
                    pageIndex: 0,
                    normalizedRect: CGRect(x: 0.6, y: 0.7 - 0.04 * CGFloat(line), width: 0.3, height: 0.03),
                    matchedText: "Delia Hartwell", contextSnippet: "…Delia Hartwell…",
                    source: .ocr(confidence: 0.9), term: "Name", isSelected: false,
                    piiCategory: .name, piiConfidence: 0.9, occurrenceID: id)
            }
        }
        let parts = [
            RedactionState.DeselectionSnapshot(items: pair(), totalCount: 3),
            RedactionState.DeselectionSnapshot(items: pair(), totalCount: 3),
        ]
        let merged = try #require(RedactionState.DeselectionSnapshot(merging: parts))
        #expect(merged.deselectedCount == 2)
        #expect(merged.totalCount == 6)
        #expect(merged.items.count == 4)
    }
}
