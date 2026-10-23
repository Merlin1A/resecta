import Testing
import Foundation
import CoreGraphics
import UIKit
import PDFKit
import RedactionEngine
@testable import ResectaApp

// The canvas Delete. The long-press menu's Delete and the
// VoiceOver custom action both call `PDFViewCoordinator.deleteRegion`,
// which takes no undo manager: the coordinator resolves the one the
// canvas gestures already register on — the window's — so the delete is
// its own undoable step, and an earlier apply's redo leg cannot bring the
// deleted region back. The delete removes only that region from the
// selection; the rest of a multi-selection stays selected.

@Suite("Canvas delete — undo and selection")
@MainActor
struct CanvasDeleteUndoTests {

    /// The coordinator mounted as the editor mounts it
    /// (`CoordinatorCommitGuardTests.twoPageView`): a PDF view inside a
    /// window, wired through `setupObservers(for:)`, so
    /// `pdfView.window?.undoManager` is the manager the overlay's gestures
    /// pass (`window?.undoManager`). Grouping is explicit, as everywhere
    /// in this target (no run loop).
    private func mounted() throws -> (
        coordinator: PDFViewCoordinator,
        state: RedactionState,
        window: UIWindow,
        undo: UndoManager
    ) {
        let state = RedactionState()
        let coordinator = PDFViewCoordinator()
        coordinator.redactionState = state
        coordinator.documentState = DocumentState()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 684))
        let view = FitFlooredPDFView(frame: window.bounds)
        view.displayMode = .singlePage
        view.document = makeTestPDFDocument()
        window.addSubview(view)
        window.isHidden = false
        view.layoutIfNeeded()
        coordinator.setupObservers(for: view)
        let undo = try #require(window.undoManager, "a window vends its undo manager")
        undo.groupsByEvent = false
        return (coordinator, state, window, undo)
    }

    private func nameResult(y: Double) -> SearchResult {
        SearchResult(
            pageIndex: 0,
            normalizedRect: CGRect(x: 0.1, y: y, width: 0.3, height: 0.04),
            matchedText: "Jane Roe",
            contextSnippet: "…Jane Roe…",
            source: .textLayer,
            term: "Jane Roe",
            isSelected: true,
            piiCategory: nil,
            piiConfidence: nil,
            rationale: nil
        )
    }

    private func manualRegion(y: Double) -> RedactionRegion {
        RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.10, y: y, width: 0.30, height: 0.05),
            source: .manual
        )
    }

    @Test("A region deleted after a 5-result apply stays deleted through Undo ×2 and Redo ×2")
    func deleteAfterApplyRedoesToFour() async throws {
        let (coordinator, state, window, undo) = try mounted()
        let search = SearchState()
        search.searchModeType = .text
        search.queryText = "Jane Roe"
        search.results = [0.10, 0.20, 0.30, 0.40, 0.50].map(nameResult(y:))
        state.activeSearch = search

        undo.beginUndoGrouping()
        _ = await state.applyFindings(.selectedSearchResults, undoManager: undo)
        undo.endUndoGrouping()
        let applied = try #require(state.regions[0])
        try #require(applied.count == 5, "precondition: five regions applied")
        let deleted = applied[2].id

        // The menu's Delete: the caller hands no manager over.
        undo.beginUndoGrouping()
        coordinator.deleteRegion(deleted, page: 0)
        undo.endUndoGrouping()
        #expect(state.regions[0]?.count == 4)
        #expect(undo.undoActionName == "Delete Redaction",
                "the delete is its own step (today the top step is still the apply)")

        undo.undo()   // the delete
        undo.undo()   // the apply
        #expect(state.regions[0]?.isEmpty ?? true)
        undo.redo()   // the apply
        undo.redo()   // the delete
        #expect(state.regions[0]?.count == 4,
                "today 5: the apply's redo leg re-inserts the deleted region")
        #expect(state.regions[0]?.contains { $0.id == deleted } == false)
        _ = window
    }

    @Test("Deleting one region of a two-region selection keeps the other selected")
    func deleteKeepsTheRestOfTheSelection() throws {
        let (coordinator, state, window, undo) = try mounted()
        let a = manualRegion(y: 0.10)
        let b = manualRegion(y: 0.30)
        state.addRegion(a, page: 0, undoManager: nil)
        state.addRegion(b, page: 0, undoManager: nil)
        state.selectedRegionIDs = [a.id, b.id]

        undo.beginUndoGrouping()
        coordinator.deleteRegion(a.id, page: 0)
        undo.endUndoGrouping()

        #expect(state.regions[0]?.map(\.id) == [b.id])
        #expect(state.selectedRegionIDs == [b.id],
                "today empty: `selectedRegionID = nil` clears the whole set")

        // The prune lives in `removeRegion`, so the undo leg inherits it:
        // Undo restores A (unselected), Redo removes it again, B stays.
        undo.undo()
        #expect(state.regions[0]?.count == 2)
        undo.redo()
        #expect(state.selectedRegionIDs == [b.id])
        _ = window
    }

    @Test("Removing a region that is not on the page is not a region mutation")
    func removeMissingRegionDoesNotBumpTheVersion() {
        let state = RedactionState()
        state.addRegion(manualRegion(y: 0.10), page: 0, undoManager: nil)
        let version = state.regionVersion
        state.removeRegion(UUID(), page: 0, undoManager: nil)
        #expect(state.regionVersion == version, "today the bump runs before the guard")
    }
}
