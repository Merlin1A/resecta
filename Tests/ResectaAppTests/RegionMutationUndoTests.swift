import Testing
import Foundation
import CoreGraphics
import RedactionEngine
@testable import ResectaApp

// The undoable region mutations read through a real undo manager: the one
// name a step carries on both its undo and redo legs, the selection an
// undo leaves behind, a move or resize to the stored rect that changes
// nothing, and Duplicate selecting its copy.

@Suite("Region mutation undo")
@MainActor
struct RegionMutationUndoTests {

    private static func region(y: CGFloat = 0.10) -> RedactionRegion {
        RedactionRegion.mock(rect: CGRect(x: 0.10, y: y, width: 0.30, height: 0.05))
    }

    private static func searchResult(y: CGFloat) -> SearchResult {
        SearchResult(
            pageIndex: 0,
            normalizedRect: CGRect(x: 0.1, y: y, width: 0.3, height: 0.04),
            matchedText: "alpha",
            contextSnippet: "…alpha…",
            source: .textLayer,
            term: "alpha",
            isSelected: true
        )
    }

    // MARK: - One name on both legs

    @Test("Add names its step and the redo of its undo the same: Add Region")
    func addNamesBothLegs() {
        let state = RedactionState()
        let mgr = makeUndoManager()
        withUndoGroup(mgr) {
            state.addRegion(Self.region(), page: 0, undoManager: mgr)
        }
        #expect(mgr.undoActionName == "Add Region")
        mgr.undo()
        #expect(mgr.redoActionName == "Add Region", "Redo names the action it repeats")
    }

    @Test("Duplicate names its step and the redo of its undo the same: Duplicate Region")
    func duplicateNamesBothLegs() {
        let state = RedactionState()
        let source = Self.region()
        state.addRegion(source, page: 0, undoManager: nil)
        let mgr = makeUndoManager()
        withUndoGroup(mgr) {
            state.duplicateRegion(source.id, page: 0, undoManager: mgr)
        }
        #expect(mgr.undoActionName == "Duplicate Region")
        mgr.undo()
        #expect(mgr.redoActionName == "Duplicate Region", "Redo names the action it repeats")
    }

    @Test("A delete of three regions over two pages is one step named Delete Regions on both legs")
    func multiPageDeleteNamesBothLegs() {
        let state = RedactionState()
        let first = Self.region(y: 0.10)
        let second = Self.region(y: 0.30)
        let third = Self.region(y: 0.50)
        state.addRegion(first, page: 0, undoManager: nil)
        state.addRegion(second, page: 0, undoManager: nil)
        state.addRegion(third, page: 2, undoManager: nil)
        state.selectedRegionIDs = [first.id, second.id, third.id]
        let mgr = makeUndoManager()
        withUndoGroup(mgr) {
            _ = state.deleteSelected(undoManager: mgr)
        }
        #expect(mgr.undoActionName == "Delete Regions")
        mgr.undo()
        #expect(mgr.redoActionName == "Delete Regions", "Redo names the action it repeats")
    }

    @Test("A search apply of five selected results, two already covered, is named by the three it marks")
    func searchApplyIsNamedByWhatItCreates() async {
        let state = RedactionState()
        let results = (0..<5).map { Self.searchResult(y: 0.10 + 0.15 * CGFloat($0)) }
        // Two of the results already sit under a region.
        state.addRegion(RedactionRegion.mock(rect: results[0].normalizedRect), page: 0, undoManager: nil)
        state.addRegion(RedactionRegion.mock(rect: results[1].normalizedRect), page: 0, undoManager: nil)
        let (defaults, suiteName) = makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let search = SearchState(defaults: defaults)
        search.results = results
        state.activeSearch = search
        let mgr = makeUndoManager()

        mgr.beginUndoGrouping()
        let outcome = await state.applyFindings(.selectedSearchResults, undoManager: mgr)
        mgr.endUndoGrouping()

        #expect(outcome?.applied == 3)
        #expect(outcome?.skippedOverlaps == 2)
        #expect(mgr.undoActionName == "Mark 3 Instances")
    }

    // MARK: - The selection an undo leaves behind

    @Test("Undo of a drawn region leaves no ghost in the selection")
    func undoOfAnAddClearsItsSelection() {
        let state = RedactionState()
        let drawn = Self.region()
        let mgr = makeUndoManager()
        withUndoGroup(mgr) {
            state.addRegion(drawn, page: 0, undoManager: mgr)
        }
        state.selectedRegionIDs = [drawn.id]
        mgr.undo()
        #expect(state.regions[0]?.isEmpty ?? true)
        #expect(state.selectedRegionIDs.isEmpty)
    }

    @Test("Undo of a one-region delete restores that region's selection")
    func undoOfASingleDeleteRestoresTheSelection() {
        let state = RedactionState()
        let kept = Self.region(y: 0.10)
        let deleted = Self.region(y: 0.30)
        state.addRegion(kept, page: 0, undoManager: nil)
        state.addRegion(deleted, page: 0, undoManager: nil)
        state.selectedRegionIDs = [deleted.id]
        let mgr = makeUndoManager()
        withUndoGroup(mgr) {
            _ = state.deleteSelected(undoManager: mgr)
        }
        #expect(state.selectedRegionIDs.isEmpty)
        mgr.undo()
        #expect(state.regions[0]?.contains(where: { $0.id == deleted.id }) == true)
        #expect(state.selectedRegionIDs == [deleted.id])
    }

    @Test("Undo of a search apply leaves none of its regions in the selection")
    func undoOfASearchApplyClearsItsSelection() async {
        let state = RedactionState()
        let (defaults, suiteName) = makeScratchDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let search = SearchState(defaults: defaults)
        search.results = (0..<3).map { Self.searchResult(y: 0.10 + 0.20 * CGFloat($0)) }
        state.activeSearch = search
        let mgr = makeUndoManager()

        mgr.beginUndoGrouping()
        _ = await state.applyFindings(.selectedSearchResults, undoManager: mgr)
        mgr.endUndoGrouping()
        guard let created = state.regions[0]?.first else {
            Issue.record("the apply created no region")
            return
        }
        #expect(state.regions[0]?.count == 3)
        state.selectedRegionIDs = [created.id]

        mgr.undo()
        #expect(state.regions[0]?.isEmpty ?? true)
        #expect(state.selectedRegionIDs.isEmpty)
    }

    // MARK: - A move or resize to the stored rect changes nothing

    @Test("Move, group move and resize to the stored rect record no step, bump nothing and keep the output")
    func mutationsToTheStoredRectAreInert() throws {
        let state = RedactionState()
        let first = Self.region(y: 0.10)
        let second = Self.region(y: 0.30)
        state.addRegion(first, page: 0, undoManager: nil)
        state.addRegion(second, page: 0, undoManager: nil)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("inert-mutation-\(UUID().uuidString).pdf")
        try Data("output".utf8).write(to: output)
        defer { try? FileManager.default.removeItem(at: output) }
        state.outputURL = output
        let version = state.regionVersion
        let undoManager = UndoManager()

        state.moveRegion(first.id, page: 0, newRect: first.normalizedRect, undoManager: undoManager)
        state.moveRegions(
            [(id: first.id, newRect: first.normalizedRect), (id: second.id, newRect: second.normalizedRect)],
            page: 0, undoManager: undoManager
        )
        state.resizeRegion(second.id, page: 0, newRect: second.normalizedRect, undoManager: undoManager)

        #expect(undoManager.canUndo == false, "no undo step")
        #expect(state.regionVersion == version, "no region-version bump")
        #expect(state.outputURL == output, "the output still matches the regions")
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    @Test("Each mutator reports whether it changed the stored rect")
    func mutatorsReportAChange() {
        let state = RedactionState()
        let region = Self.region()
        state.addRegion(region, page: 0, undoManager: nil)
        let moved = region.normalizedRect.offsetBy(dx: 0.05, dy: 0)

        #expect(state.moveRegion(region.id, page: 0, newRect: region.normalizedRect, undoManager: nil) == false)
        #expect(state.moveRegions([(id: region.id, newRect: region.normalizedRect)], page: 0, undoManager: nil) == false)
        #expect(state.resizeRegion(region.id, page: 0, newRect: region.normalizedRect, undoManager: nil) == false)
        #expect(state.moveRegion(region.id, page: 0, newRect: moved, undoManager: nil) == true)
        #expect(state.regions[0]?.first?.normalizedRect == moved)
    }

    // MARK: - Duplicate

    @Test("Duplicate selects the copy")
    func duplicateSelectsTheCopy() {
        let state = RedactionState()
        let source = Self.region()
        state.addRegion(source, page: 0, undoManager: nil)
        state.selectedRegionIDs = [source.id]

        state.duplicateRegion(source.id, page: 0, undoManager: nil)

        guard let copy = state.regions[0]?.first(where: { $0.id != source.id }) else {
            Issue.record("Duplicate created no copy")
            return
        }
        #expect(state.selectedRegionIDs == [copy.id])
    }
}
