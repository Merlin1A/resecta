import Testing
import Foundation
import CoreGraphics
import RedactionEngine
@testable import ResectaApp

// The apply-commit deselection snapshot carries the scan results the user
// left un-checked as VALUES — page, category, rect and text — not just
// their count. The output re-run subtracts them so an item the user
// consciously left is reported as their choice, not as a leak. The
// session's `results` are cleared when the sheet dismisses, so the copy
// must be taken at the commit.

@Suite("Deselection items on the apply-commit snapshot", .tags(.search))
@MainActor
struct DeselectionItemsTests {

    private func scanResult(
        _ index: Int, page: Int, category: PIICategory, selected: Bool
    ) -> SearchResult {
        SearchResult(
            pageIndex: page,
            normalizedRect: CGRect(x: 0.1 * CGFloat(index), y: 0.2, width: 0.1, height: 0.03),
            matchedText: "match-\(index)", contextSnippet: "…match-\(index)…",
            source: .textLayer, term: "Name", isSelected: selected,
            piiCategory: category, piiConfidence: 0.9)
    }

    /// A `.piiScan` session with a stored scan report — the state the
    /// coverage panel mounts under — over `results`.
    private func scanSession(_ results: [SearchResult]) -> SearchState {
        let state = SearchState()
        state.searchModeType = .piiScan
        state.results = results
        state.setCoverageReport(CoverageReport(
            scannedPageCount: 2,
            enabledCategories: [.ssn, .name],
            candidateCountByCategory: [.name: results.count],
            appliedCount: 0,
            deselectedCount: 0,
            belowThresholdSuppressedCount: 0,
            overlapSuppressedCountByCategory: [:],
            startedAt: Date(timeIntervalSince1970: 0),
            completedAt: Date(timeIntervalSince1970: 1)))
        return state
    }

    @Test("Apply commit captures the un-checked results as values — page, category, rect and text")
    func applyCommitCapturesItems() async {
        let results = [
            scanResult(0, page: 0, category: .name, selected: true),
            scanResult(1, page: 0, category: .ssn, selected: false),
            scanResult(2, page: 1, category: .name, selected: true),
            scanResult(3, page: 1, category: .account, selected: false),
            scanResult(4, page: 1, category: .name, selected: true),
        ]
        let redaction = RedactionState()
        redaction.activeSearch = scanSession(results)

        _ = await redaction.applyFindings(.selectedSearchResults, undoManager: nil)

        let snapshot = redaction.pendingRunDeselection
        #expect(snapshot?.items == results.filter { !$0.isSelected })
        #expect(snapshot?.deselectedCount == 2)
        #expect(snapshot?.totalCount == 5)
        #expect(snapshot?.items.map(\.pageIndex) == [0, 1])
        #expect(snapshot?.items.map(\.piiCategory) == [.ssn, .account])
        #expect(snapshot?.items.map(\.matchedText) == ["match-1", "match-3"])
        #expect(snapshot?.items.map(\.normalizedRect) == [results[1].normalizedRect, results[3].normalizedRect])
    }

    @Test("A typed session records no snapshot — deselection is a scan concept")
    func typedSessionRecordsNone() async {
        let redaction = RedactionState()
        let search = SearchState()
        search.searchModeType = .text
        search.queryText = "match"
        search.results = [
            SearchResult(
                pageIndex: 0, normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.1, height: 0.03),
                matchedText: "match", contextSnippet: "…match…", source: .textLayer,
                term: "match", isSelected: true),
            SearchResult(
                pageIndex: 0, normalizedRect: CGRect(x: 0.4, y: 0.2, width: 0.1, height: 0.03),
                matchedText: "match", contextSnippet: "…match…", source: .textLayer,
                term: "match", isSelected: false),
        ]
        redaction.activeSearch = search

        let outcome = await redaction.applyFindings(.selectedSearchResults, undoManager: nil)

        #expect(outcome?.applied == 1)
        #expect(redaction.pendingRunDeselection == nil)
        #expect(redaction.runEntryDeselectionSnapshot() == nil)
    }

    @Test("The captured items are copies — clearing the session's results after the commit leaves them intact")
    func itemsAreValueCopies() async {
        let results = [
            scanResult(0, page: 0, category: .name, selected: true),
            scanResult(1, page: 0, category: .ssn, selected: false),
            scanResult(2, page: 1, category: .name, selected: false),
        ]
        let redaction = RedactionState()
        let session = scanSession(results)
        redaction.activeSearch = session

        _ = await redaction.applyFindings(.selectedSearchResults, undoManager: nil)
        // The sheet clears the session on dismiss.
        session.results = []
        redaction.activeSearch = nil

        #expect(redaction.pendingRunDeselection?.items.count == 2)
        #expect(redaction.pendingRunDeselection?.items.map(\.matchedText) == ["match-1", "match-2"])
        #expect(redaction.runEntryDeselectionSnapshot()?.items.count == 2)
    }

    @Test("deselectedCount is derived from the items; totalCount is the session's")
    func countsDerivedFromItems() {
        let items = [
            scanResult(0, page: 0, category: .ssn, selected: false),
            scanResult(1, page: 1, category: .name, selected: false),
        ]
        let snapshot = RedactionState.DeselectionSnapshot(items: items, totalCount: 7)
        #expect(snapshot.deselectedCount == 2)
        #expect(snapshot.totalCount == 7)
        let none = RedactionState.DeselectionSnapshot(items: [], totalCount: 4)
        #expect(none.deselectedCount == 0)
    }
}
