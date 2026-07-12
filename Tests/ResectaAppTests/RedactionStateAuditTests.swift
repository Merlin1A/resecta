import Testing
import Foundation
import RedactionEngine
@testable import ResectaApp

// W5 — verify applySearchResults populates the audit dict, undo removes
// entries in lockstep with the regions, redo restores them, and clearAll
// wipes everything on document close.

@Suite("RedactionState appliedMatchAudit (W5)")
@MainActor
struct RedactionStateAuditTests {

    // MARK: - Helpers

    private func makeResult(
        pageIndex: Int = 0,
        term: String = "PII Scan",
        matchedText: String = "Jane Doe",
        piiCategory: PIICategory? = .name,
        rationale: MatchRationale? = MatchRationale(
            ruleID: "name.nltagger",
            signals: [.bloomSurnameHit, .presetThresholdPass(raw: 0.91, cutoff: 0.7)],
            preThresholdScore: 0.91,
            finalScore: 0.91,
            appliedThreshold: 0.7
        )
    ) -> SearchResult {
        SearchResult(
            pageIndex: pageIndex,
            normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.04),
            matchedText: matchedText,
            contextSnippet: "…\(matchedText) on record…",
            source: .textLayer,
            term: term,
            isSelected: true,
            piiCategory: piiCategory,
            piiConfidence: 0.91,
            rationale: rationale
        )
    }

    // MARK: - Baseline

    @Test("Fresh state has empty audit dict")
    func emptyByDefault() {
        let state = RedactionState()
        #expect(state.appliedMatchAudit.isEmpty)
        #expect(state.appliedMatchAuditSnapshots.isEmpty)
    }

    // MARK: - Apply populates

    @Test("applySearchResults populates audit keyed by region id")
    func applyPopulatesAudit() async {
        let state = RedactionState()
        let search = SearchState()
        let result = makeResult()
        search.results = [result]
        state.activeSearch = search

        await state.applySearchResults(undoManager: nil)

        #expect(state.appliedMatchAudit.count == 1)
        guard let region = state.regions[0]?.first else {
            Issue.record("No region created")
            return
        }
        let snapshot = state.appliedMatchAudit[region.id]
        #expect(snapshot != nil)
        #expect(snapshot?.resultID == result.id)
        #expect(snapshot?.matchedText == "Jane Doe")
        #expect(snapshot?.piiCategory == .name)
        #expect(snapshot?.rationale?.ruleID == "name.nltagger")
    }

    @Test("Audit snapshot preserves SearchSource variant and confidence")
    func snapshotPreservesSource() async {
        let state = RedactionState()
        let search = SearchState()
        search.results = [
            SearchResult(
                pageIndex: 0,
                normalizedRect: CGRect(x: 0, y: 0, width: 0.1, height: 0.1),
                matchedText: "ocr text",
                contextSnippet: "...",
                source: .ocr(confidence: 0.87),
                term: "PII Scan",
                isSelected: true,
                piiCategory: .ssn,
                piiConfidence: 0.95,
                rationale: nil
            )
        ]
        state.activeSearch = search

        await state.applySearchResults(undoManager: nil)

        let snap = state.appliedMatchAuditSnapshots.first
        if case .ocr(let c) = snap?.source {
            #expect(c == 0.87)
        } else {
            Issue.record("Expected .ocr source variant preserved")
        }
    }

    // MARK: - Undo / Redo

    @Test("Undo removes audit entries added by apply")
    func undoRemovesAudit() async {
        let state = RedactionState()
        let undo = UndoManager()
        undo.groupsByEvent = false
        let search = SearchState()
        search.results = [makeResult(pageIndex: 0), makeResult(pageIndex: 1)]
        state.activeSearch = search

        undo.beginUndoGrouping()
        await state.applySearchResults(undoManager: undo)
        undo.endUndoGrouping()
        #expect(state.appliedMatchAudit.count == 2)

        undo.undo()
        #expect(state.appliedMatchAudit.isEmpty)
    }

    @Test("Redo restores audit entries removed by undo")
    func redoRestoresAudit() async {
        let state = RedactionState()
        let undo = UndoManager()
        undo.groupsByEvent = false
        let search = SearchState()
        search.results = [makeResult()]
        state.activeSearch = search

        undo.beginUndoGrouping()
        await state.applySearchResults(undoManager: undo)
        undo.endUndoGrouping()
        let regionID = state.regions[0]?.first?.id
        #expect(regionID != nil)

        undo.undo()
        #expect(state.appliedMatchAudit.isEmpty)

        undo.redo()
        #expect(state.appliedMatchAudit.count == 1)
        if let regionID {
            #expect(state.appliedMatchAudit[regionID] != nil)
        }
    }

    // MARK: - Accumulation

    @Test("Multiple apply calls accumulate audit entries")
    func multipleAppliesAccumulate() async {
        let state = RedactionState()
        let search = SearchState()
        search.results = [makeResult(pageIndex: 0)]
        state.activeSearch = search
        await state.applySearchResults(undoManager: nil)

        // Simulate sheet re-open with fresh results.
        let search2 = SearchState()
        search2.results = [makeResult(pageIndex: 2, matchedText: "John Doe")]
        state.activeSearch = search2
        await state.applySearchResults(undoManager: nil)

        #expect(state.appliedMatchAudit.count == 2)
        let texts = state.appliedMatchAuditSnapshots.map(\.matchedText)
        #expect(texts.contains("Jane Doe"))
        #expect(texts.contains("John Doe"))
    }

    // MARK: - Ordering

    @Test("appliedMatchAuditSnapshots sort by pageIndex then appliedAt")
    func snapshotsSortedByPageThenTime() async {
        let state = RedactionState()
        let search = SearchState()
        search.results = [
            makeResult(pageIndex: 2, matchedText: "z"),
            makeResult(pageIndex: 0, matchedText: "a"),
            makeResult(pageIndex: 1, matchedText: "m"),
        ]
        state.activeSearch = search

        await state.applySearchResults(undoManager: nil)

        let pages = state.appliedMatchAuditSnapshots.map(\.pageIndex)
        #expect(pages == [0, 1, 2])
    }

    // MARK: - clearAll

    @Test("clearAll empties the audit dict")
    func clearAllWipesAudit() async {
        let state = RedactionState()
        let search = SearchState()
        search.results = [makeResult()]
        state.activeSearch = search
        await state.applySearchResults(undoManager: nil)
        #expect(!state.appliedMatchAudit.isEmpty)

        state.clearAll()
        #expect(state.appliedMatchAudit.isEmpty)
    }
}
