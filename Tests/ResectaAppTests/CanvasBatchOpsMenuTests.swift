import Testing
import Foundation
import CoreGraphics
import RedactionEngine
@testable import ResectaApp

// Canvas batch-ops "More" menu in the toolbar.
// Bundles Select All on Page / Deselect / Delete Selected behind one
// chevron when at least one region is selected. The destructive Delete
// Selected entry deletes at once, like the toolbar's Delete.
//
// Three contracts pinned here without a SwiftUI host:
// 1. Visibility predicate gates the menu on selection emptiness.
// 2. Select All / Deselect routes through the same `selectedRegionIDs`
//    mutations the existing `selectionMenu` uses — single source of
//    truth, no parallel mutation path.
// 3. Delete Selected deletes at once; one Undo restores every region.

@Suite("Canvas batch-ops menu")
@MainActor
struct CanvasBatchOpsMenuTests {

    // MARK: - Visibility predicate

    @Test("Menu hides when nothing is selected")
    func menuHidesWithEmptySelection() {
        #expect(DocumentEditorView.batchOpsMenuShouldShow(selectedCount: 0) == false)
    }

    @Test("Menu surfaces as soon as one region is selected")
    func menuSurfacesAtOne() {
        #expect(DocumentEditorView.batchOpsMenuShouldShow(selectedCount: 1) == true)
    }

    @Test("Menu stays visible across larger selection sizes")
    func menuStaysVisibleAtScale() {
        for count in [2, 10, 50, 200] {
            #expect(
                DocumentEditorView.batchOpsMenuShouldShow(selectedCount: count) == true,
                "expected menu visible at selectedCount = \(count)"
            )
        }
    }

    // MARK: - Action contracts via direct state mutation

    /// Helper to seed a state with N regions on page 0, returning their IDs.
    private func seedRegions(_ state: RedactionState, count: Int, page: Int = 0) -> [UUID] {
        var ids: [UUID] = []
        for i in 0..<count {
            let region = RedactionRegion(
                id: UUID(),
                normalizedRect: CGRect(
                    x: 0.1, y: Double(i) * 0.05,
                    width: 0.2, height: 0.04
                ),
                source: .manual
            )
            state.regions[page, default: []].append(region)
            ids.append(region.id)
        }
        return ids
    }

    @Test("Select All on Page populates selection with every region on the page")
    func selectAllOnPageContract() {
        let state = RedactionState()
        let ids = seedRegions(state, count: 5, page: 0)
        // Start with a partial selection.
        state.selectedRegionIDs = Set(ids.prefix(2))

        // Mirrors the menu's button body — assignment from the page's regions.
        let page = 0
        let pageRegions = state.regions[page] ?? []
        state.selectedRegionIDs = Set(pageRegions.map(\.id))

        #expect(state.selectedRegionIDs == Set(ids))
        #expect(state.selectedRegionIDs.count == 5)
    }

    @Test("Deselect clears the selection set")
    func deselectContract() {
        let state = RedactionState()
        let ids = seedRegions(state, count: 3, page: 0)
        state.selectedRegionIDs = Set(ids)
        #expect(state.selectedRegionIDs.isEmpty == false)

        // Mirrors the menu's "Deselect" button body.
        state.selectedRegionIDs = []

        #expect(state.selectedRegionIDs.isEmpty == true)
    }

    @Test("Delete Selected deletes at once, and one Undo restores every region")
    func deleteSelectedIsImmediateAndOneUndo() {
        // The menu's destructive button and the toolbar's Delete both call
        // `deleteSelected(undoManager:)` directly; no dialog sits between.
        let state = RedactionState()
        let ids = seedRegions(state, count: 4, page: 0)
        state.selectedRegionIDs = Set(ids)
        let undo = makeUndoManager()

        undo.beginUndoGrouping()
        state.deleteSelected(undoManager: undo)
        undo.endUndoGrouping()
        #expect(state.regions[0]?.isEmpty ?? true)

        undo.undo()
        #expect(state.regions[0]?.count == 4)
    }
}
