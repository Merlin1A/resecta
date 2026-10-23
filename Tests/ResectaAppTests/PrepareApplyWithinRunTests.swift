import Testing
import Foundation
import CoreGraphics
import RedactionEngine
@testable import ResectaApp

// What one apply leaves behind, read through the real apply seam: two
// results over the same text make one region, an apply that creates
// nothing records nothing, a Scan region keeps the detector's confidence
// on a text page, and the deselection facts a run will disclose survive a
// later apply — merged with it, and given back whole when that later
// apply is undone.

@Suite("Prepare and apply within one run", .tags(.search))
@MainActor
struct PrepareApplyWithinRunTests {

    private func scanResult(y: CGFloat, selected: Bool, confidence: Double = 0.9) -> SearchResult {
        SearchResult(
            pageIndex: 0,
            normalizedRect: CGRect(x: 0.1, y: y, width: 0.3, height: 0.04),
            matchedText: "123-45-6789",
            contextSnippet: "…123-45-6789…",
            source: .textLayer,
            term: "SSN",
            isSelected: selected,
            piiCategory: .ssn,
            piiConfidence: confidence
        )
    }

    private func textResult(y: CGFloat, term: String = "alpha") -> SearchResult {
        SearchResult(
            pageIndex: 0,
            normalizedRect: CGRect(x: 0.1, y: y, width: 0.3, height: 0.04),
            matchedText: term,
            contextSnippet: "…\(term)…",
            source: .textLayer,
            term: term,
            isSelected: true
        )
    }

    /// A `.piiScan` session with a stored scan report — the state the
    /// deselection facts are captured under — over `results`.
    private func scanSession(_ results: [SearchResult], defaults: UserDefaults) -> SearchState {
        let session = SearchState(defaults: defaults)
        session.searchModeType = .piiScan
        session.results = results
        session.setCoverageReport(CoverageReport(
            scannedPageCount: 1,
            enabledCategories: [.ssn],
            candidateCountByCategory: [.ssn: results.count],
            appliedCount: 0,
            deselectedCount: 0,
            belowThresholdSuppressedCount: 0,
            overlapSuppressedCountByCategory: [:],
            startedAt: Date(timeIntervalSince1970: 0),
            completedAt: Date(timeIntervalSince1970: 1)))
        return session
    }

    private func textSession(_ results: [SearchResult], defaults: UserDefaults) -> SearchState {
        let session = SearchState(defaults: defaults)
        session.searchModeType = .text
        session.queryText = "alpha"
        session.results = results
        return session
    }

    // MARK: - One region per spot

    @Test("Two results over the same text in one apply create one region; the second reads as covered")
    func twoResultsOverTheSameTextCreateOneRegion() async {
        let (defaults, suiteName) = makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = RedactionState()
        let first = textResult(y: 0.2, term: "alpha")
        let second = textResult(y: 0.2, term: "alpha beta")
        let search = textSession([first, second], defaults: defaults)
        state.activeSearch = search

        let outcome = await state.applyFindings(.selectedSearchResults, undoManager: nil)

        #expect(state.regions[0]?.count == 1)
        #expect(outcome?.applied == 1)
        #expect(outcome?.skippedOverlaps == 1)
        #expect(outcome.map { $0.appliedResultIDs.union($0.coveredResultIDs) } == [first.id, second.id])
    }

    @Test("An apply whose every result is already covered records no undo step")
    func anAllCoveredApplyRecordsNothing() async {
        let (defaults, suiteName) = makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = RedactionState()
        let result = textResult(y: 0.2)
        state.addRegion(RedactionRegion.mock(rect: result.normalizedRect), page: 0, undoManager: nil)
        state.activeSearch = textSession([result], defaults: defaults)
        let version = state.regionVersion
        let mgr = makeUndoManager()

        mgr.beginUndoGrouping()
        let outcome = await state.applyFindings(.selectedSearchResults, undoManager: mgr)
        mgr.endUndoGrouping()

        #expect(outcome?.applied == 0)
        #expect(outcome?.skippedOverlaps == 1)
        #expect(mgr.canUndo == false, "no empty undo step")
        #expect(state.regionVersion == version, "no region-version bump")
    }

    // MARK: - The detector's confidence

    @Test("A Scan result on a text page stores the detector's confidence, not 1.0")
    func scanConfidenceIsStoredOnATextPage() async {
        let (defaults, suiteName) = makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = RedactionState()
        let search = scanSession([scanResult(y: 0.2, selected: true, confidence: 0.62)], defaults: defaults)
        state.activeSearch = search

        _ = await state.applyFindings(.selectedSearchResults, undoManager: nil)

        guard let region = state.regions[0]?.first else {
            Issue.record("the apply created no region")
            return
        }
        #expect(state.regionMetadata[region.id]?.confidence == 0.62)
    }

    @Test("A typed result on a text page still stores 1.0")
    func typedResultKeepsTheTextLayerConfidence() async {
        let (defaults, suiteName) = makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = RedactionState()
        state.activeSearch = textSession([textResult(y: 0.2)], defaults: defaults)

        _ = await state.applyFindings(.selectedSearchResults, undoManager: nil)

        guard let region = state.regions[0]?.first else {
            Issue.record("the apply created no region")
            return
        }
        #expect(state.regionMetadata[region.id]?.confidence == 1.0)
    }

    // MARK: - The deselection facts across applies

    @Test("Undo of the later of two applies gives back the earlier apply's deselection facts")
    func undoOfALaterApplyRestoresTheEarlierDeselection() async {
        let (defaults, suiteName) = makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = RedactionState()
        let mgr = makeUndoManager()

        state.activeSearch = scanSession(
            [scanResult(y: 0.10, selected: true), scanResult(y: 0.20, selected: false)],
            defaults: defaults)
        mgr.beginUndoGrouping()
        _ = await state.applyFindings(.selectedSearchResults, undoManager: mgr)
        mgr.endUndoGrouping()
        guard let earlier = state.runEntryDeselectionSnapshot() else {
            Issue.record("the first Scan apply captured no deselection facts")
            return
        }

        state.activeSearch = scanSession(
            [scanResult(y: 0.50, selected: true), scanResult(y: 0.60, selected: false),
             scanResult(y: 0.70, selected: false)],
            defaults: defaults)
        mgr.beginUndoGrouping()
        _ = await state.applyFindings(.selectedSearchResults, undoManager: mgr)
        mgr.endUndoGrouping()

        mgr.undo()
        #expect(state.runEntryDeselectionSnapshot() == earlier)
    }

    @Test("A later typed-search apply keeps an earlier Scan's unchecked results")
    func aLaterApplyKeepsAnEarlierScansUncheckedSet() async {
        let (defaults, suiteName) = makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = RedactionState()
        let unchecked = scanResult(y: 0.20, selected: false)
        state.activeSearch = scanSession([scanResult(y: 0.10, selected: true), unchecked], defaults: defaults)
        _ = await state.applyFindings(.selectedSearchResults, undoManager: nil)

        state.activeSearch = textSession([textResult(y: 0.60)], defaults: defaults)
        _ = await state.applyFindings(.selectedSearchResults, undoManager: nil)

        let ids = state.runEntryDeselectionSnapshot().map { Set($0.items.map(\.id)) }
        #expect(ids == [unchecked.id])
    }

    @Test("Two Scan applies disclose the union of their unchecked results")
    func twoScanAppliesUnionTheirUncheckedSets() async {
        let (defaults, suiteName) = makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = RedactionState()
        let firstUnchecked = scanResult(y: 0.20, selected: false)
        state.activeSearch = scanSession(
            [scanResult(y: 0.10, selected: true), firstUnchecked], defaults: defaults)
        _ = await state.applyFindings(.selectedSearchResults, undoManager: nil)

        let laterUnchecked = [scanResult(y: 0.60, selected: false), scanResult(y: 0.70, selected: false)]
        state.activeSearch = scanSession(
            [scanResult(y: 0.50, selected: true)] + laterUnchecked, defaults: defaults)
        _ = await state.applyFindings(.selectedSearchResults, undoManager: nil)

        let ids = state.runEntryDeselectionSnapshot().map { Set($0.items.map(\.id)) }
        #expect(ids == Set([firstUnchecked.id] + laterUnchecked.map(\.id)))
    }
}
