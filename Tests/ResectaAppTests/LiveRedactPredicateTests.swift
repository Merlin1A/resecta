import Testing
import Foundation
import CoreGraphics
@testable import ResectaApp
@testable import RedactionEngine

// The one predicate Redact, the Home dialog and the search sheet's Dismiss
// read — "selections not yet applied" — is computed from the rows: a
// selected result that no live region covers, or an auto-selected set
// never reviewed. Not a gesture tracker: Deselect All leaves nothing to
// apply, so nothing holds; an undone apply uncovers the rows again, so the
// gate closes again.

@Suite("The live Redact predicate", .tags(.search))
@MainActor
struct LiveRedactPredicateTests {

    private func makeResult(y: CGFloat) -> SearchResult {
        SearchResult(
            pageIndex: 0,
            normalizedRect: CGRect(x: 0.1, y: y, width: 0.2, height: 0.03),
            matchedText: "alpha",
            contextSnippet: "…alpha…",
            source: .textLayer,
            term: "alpha",
            isSelected: true
        )
    }

    private func states() -> (DocumentState, RedactionState) {
        let documentState = DocumentState()
        documentState.phase = .editing
        let redactionState = RedactionState()
        redactionState.regions[0] = [RedactionRegion(
            id: UUID(), normalizedRect: CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.05), source: .manual)]
        return (documentState, redactionState)
    }

    @Test("Deselect All: nothing is left to apply, so Home asks nothing and Redact is not refused")
    func deselectAllHoldsNothing() {
        let (documentState, redactionState) = states()
        let search = SearchState(defaults: makeScratchDefaults().0)
        search.results = [makeResult(y: 0.1), makeResult(y: 0.2)]
        redactionState.activeSearch = search
        #expect(DocumentState.hasUnappliedSelections(redactionState), "two selected rows, none applied")
        #expect(documentState.redactRefusal(with: redactionState) == .selectedMatches)

        search.toggleSelectAll()
        search.userModifiedSelections = true   // the footer's gesture arms the tracker
        #expect(search.results.allSatisfy { !$0.isSelected }, "Deselect All")

        #expect(!DocumentState.hasUnappliedSelections(redactionState))
        #expect(!DocumentEditorView.homeNeedsCloseConfirm(
            hasDrawnRegions: false, hasUnappliedSelections: DocumentState.hasUnappliedSelections(redactionState)))
        #expect(documentState.redactRefusal(with: redactionState) == nil)
    }

    @Test("Apply all: Redact is enabled; Undo of the apply: Redact is gated again")
    func applyAllThenUndo() async {
        let (documentState, redactionState) = states()
        let undoManager = UndoManager()
        let search = SearchState(defaults: makeScratchDefaults().0)
        search.results = [makeResult(y: 0.1), makeResult(y: 0.2)]
        redactionState.activeSearch = search
        #expect(documentState.redactRefusal(with: redactionState) == .selectedMatches)

        await redactionState.applyFindings(.selectedSearchResults, undoManager: undoManager)
        #expect(redactionState.appliedMatchAudit.count == 2, "both rows applied")
        #expect(redactionState.activeSearch === search, "the session is still live")
        #expect(documentState.redactRefusal(with: redactionState) == nil, "every selected row is covered")
        #expect(!DocumentState.hasUnappliedSelections(redactionState))

        undoManager.undo()
        #expect(redactionState.appliedMatchAudit.isEmpty, "the apply is undone")
        #expect(search.results.allSatisfy { $0.isSelected }, "the rows are still selected")
        #expect(DocumentState.hasUnappliedSelections(redactionState), "selected and no longer covered")
        #expect(documentState.redactRefusal(with: redactionState) == .selectedMatches)
    }

    @Test("A programmatic run entry (the resume banner's Restart) over selected, unapplied matches keeps the session and starts no run",
          .timeLimit(.minutes(1)))
    func programmaticEntryKeepsPendingSelections() async throws {
        let coord = makeLoadedCoordinator()
        let region = RedactionRegion(
            id: UUID(), normalizedRect: CGRect(x: 0.1, y: 0.8, width: 0.8, height: 0.05), source: .manual)
        coord.redactionState.addRegion(region, page: 0, undoManager: nil)
        let search = SearchState(defaults: makeScratchDefaults().0)
        search.results = [makeResult(y: 0.1)]
        search.userModifiedSelections = true
        coord.redactionState.activeSearch = search

        coord.runFullPipeline(documentOverride: .secureRasterization)
        try await Task.sleep(for: .milliseconds(200))

        #expect(coord.redactionState.activeSearch === search, "the session is not torn down")
        #expect(coord.documentState.activePipelineTask == nil, "no run started over the pending selections")
        #expect(coord.documentState.phaseKind == .editing)
    }
}
