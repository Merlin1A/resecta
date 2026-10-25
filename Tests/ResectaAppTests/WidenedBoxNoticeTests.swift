import Testing
import Foundation
import CoreGraphics
@testable import ResectaApp
import RedactionEngine

// The widened-box notice: a Search box the ink fit could not fit to the
// printed word is drawn larger (`SearchResult.inkFitDegraded`). The results
// sheet names the pages holding one, and the page in view says so in the
// bottom capsule, before the apply and after it. The notice is on a page iff
// a result or a live applied region there is widened; it rides undo and redo
// with its region, stays when the region is resized, and goes when the
// region is deleted.

@MainActor
@Suite("Widened-box notice")
struct WidenedBoxNoticeTests {

    private static func result(page: Int, y: Double, widened: Bool) -> SearchResult {
        SearchResult(
            pageIndex: page,
            normalizedRect: CGRect(x: 0.1, y: y, width: 0.3, height: 0.03),
            matchedText: "Hartwell", contextSnippet: "...", source: .textLayer, term: "Hartwell",
            isSelected: true, inkFitDegraded: widened)
    }

    private static func manager() -> UndoManager {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        return undoManager
    }

    /// Page 0 holds a widened result, page 1 a clean one.
    private static func session() -> SearchState {
        let search = SearchState()
        search.results = [result(page: 0, y: 0.2, widened: true), result(page: 1, y: 0.2, widened: false)]
        return search
    }

    private static func apply(_ state: RedactionState, _ undoManager: UndoManager) async {
        undoManager.beginUndoGrouping()
        _ = await state.applyFindings(.selectedSearchResults, undoManager: undoManager)
        undoManager.endUndoGrouping()
    }

    // MARK: - The copy

    @Test("The sheet's banner names the pages, one-based, singular and plural")
    func bannerHeadline() {
        #expect(SearchResultsSection.widenedBoxBannerHeadline(pages: [2])
                == "Some boxes on page 3 were drawn wider than their words, because the text could not be fitted to the printed words. Keep them wide: shrinking one can leave part of a word readable.")
        #expect(SearchResultsSection.widenedBoxBannerHeadline(pages: [0, 4])
                == "Some boxes on pages 1 and 5 were drawn wider than their words, because the text could not be fitted to the printed words. Keep them wide: shrinking one can leave part of a word readable.")
    }

    @Test("The page capsule's words, shorter at accessibility sizes, and its one spoken sentence")
    func captionWords() {
        #expect(DocumentEditorView.widenedBoxCaption(accessibilitySize: false)
                == "Some boxes here are wider than their words. Keep them wide.")
        #expect(DocumentEditorView.widenedBoxCaption(accessibilitySize: true) == "Wide boxes: keep them wide")
        #expect(DocumentEditorView.widenedBoxAccessibilityLabel
                == "Some boxes on this page were drawn wider than their words, because the text could not be fitted to the printed words. Keep them wide: shrinking one can leave part of a word readable.")
    }

    // MARK: - Before the apply

    @Test("The session names the pages holding a widened result, and no clean page")
    func sessionPages() {
        let search = Self.session()
        #expect(search.widenedBoxPages == [0])
        let state = RedactionState()
        state.activeSearch = search
        #expect(state.pageHoldsWidenedBox(0))
        #expect(!state.pageHoldsWidenedBox(1))
        search.results = [Self.result(page: 0, y: 0.2, widened: false)]
        #expect(search.widenedBoxPages.isEmpty)
        #expect(!state.pageHoldsWidenedBox(0))
    }

    // MARK: - After the apply

    @Test("After the apply the widened page keeps its notice with no session; a clean page has none")
    func persistsAfterApply() async {
        let state = RedactionState()
        state.activeSearch = Self.session()
        await Self.apply(state, Self.manager())
        state.activeSearch = nil
        #expect(state.widenedRegionPages == [0])
        #expect(state.pageHoldsWidenedBox(0))
        #expect(!state.pageHoldsWidenedBox(1))
    }

    @Test("Undo of the apply takes the notice with its region; redo brings it back")
    func ridesUndoAndRedo() async {
        let state = RedactionState()
        let undoManager = Self.manager()
        state.activeSearch = Self.session()
        await Self.apply(state, undoManager)
        state.activeSearch = nil
        undoManager.undo()
        #expect(state.widenedRegionPages.isEmpty)
        undoManager.redo()
        #expect(state.widenedRegionPages == [0])
    }

    @Test("A resized widened region keeps its notice; a deleted one loses it, and undo of the delete restores it")
    func resizeKeepsDeleteClears() async throws {
        let state = RedactionState()
        let undoManager = Self.manager()
        state.activeSearch = Self.session()
        await Self.apply(state, undoManager)
        state.activeSearch = nil
        let region = try #require(state.regions[0]?.first)
        undoManager.beginUndoGrouping()
        state.resizeRegion(region.id, page: 0, newRect: CGRect(x: 0.1, y: 0.2, width: 0.1, height: 0.03),
                           undoManager: undoManager)
        undoManager.endUndoGrouping()
        #expect(state.widenedRegionPages == [0], "a shrunk widened box is the case to keep flagged")
        state.selectedRegionIDs = [region.id]
        undoManager.beginUndoGrouping()
        _ = state.deleteSelected(undoManager: undoManager)
        undoManager.endUndoGrouping()
        #expect(state.widenedRegionPages.isEmpty)
        undoManager.undo()
        #expect(state.widenedRegionPages == [0])
    }

    @Test("A nearby match accepted from a widened result carries the notice")
    func nudgeAcceptCarriesIt() {
        let state = RedactionState()
        let region = state.acceptManualDrawNudge(Self.result(page: 2, y: 0.4, widened: true), undoManager: nil)
        #expect(region != nil)
        #expect(state.widenedRegionPages == [2])
    }

    // MARK: - The capsule host

    @Test("The widened-box capsule shows while editing, after the drawing caption and Add to Selection")
    func capsulePrecedence() {
        #expect(DocumentEditorView.bottomCapsule(
            activeTool: nil, addToSelection: false, phaseKind: .editing, widenedOnPage: true) == .widenedBoxes)
        #expect(DocumentEditorView.bottomCapsule(
            activeTool: .rectangle, addToSelection: false, phaseKind: .editing, widenedOnPage: true) == .drawing)
        #expect(DocumentEditorView.bottomCapsule(
            activeTool: nil, addToSelection: true, phaseKind: .editing, widenedOnPage: true) == .addToSelection)
        #expect(DocumentEditorView.bottomCapsule(
            activeTool: nil, addToSelection: false, phaseKind: .verifying, widenedOnPage: true) == nil)
        #expect(DocumentEditorView.bottomCapsule(
            activeTool: nil, addToSelection: false, phaseKind: .editing, widenedOnPage: false) == nil)
    }
}
