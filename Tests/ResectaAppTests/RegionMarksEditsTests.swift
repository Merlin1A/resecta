import Testing
import Foundation
import CoreGraphics
@testable import ResectaApp
@testable import RedactionEngine

// A region's two marks through the editor's own edits. "Placed from the
// page's own text" is set once, where Search or Scan places the region, and
// never changes; "anchored" goes false on a move or a resize and back to true
// only by that edit's own undo. A duplicate is drawn by hand. (The kind
// each pair of marks gives is the engine's: RunPlanKeptTests.)

@Suite("A region's two marks through the editor's edits")
@MainActor
struct RegionMarksEditsTests {

    static let rect = CGRect(x: 0.2, y: 0.5, width: 0.1, height: 0.02)

    static func placed(_ source: SearchSource = .textLayer) -> RedactionRegion {
        RedactionRegion(placing: SearchResult(pageIndex: 0, normalizedRect: rect, matchedText: "Delia",
                                              contextSnippet: "Delia Hartwell", source: source, term: "delia"))
    }

    /// One edit as the user makes it: its own undo group.
    static func step(_ undo: UndoManager, _ edit: () -> Void) {
        undo.beginUndoGrouping()
        edit()
        undo.endUndoGrouping()
    }

    @Test("Move, resize and a group move leave the first mark; each turns anchoring off, and its undo turns it back")
    func editsAndTheirUndo() throws {
        let state = RedactionState()
        let undo = makeUndoManager()
        let region = Self.placed()
        state.addRegion(region, page: 0, undoManager: nil)
        func now() throws -> RedactionRegion { try #require(state.regions[0]?.first { $0.id == region.id }) }
        #expect(try now().placedFromPageText && now().textAnchored)

        Self.step(undo) { _ = state.moveRegion(region.id, page: 0, newRect: Self.rect.offsetBy(dx: 0.05, dy: 0), undoManager: undo) }
        #expect(try now().placedFromPageText && !now().textAnchored, "after a move")
        undo.undo()
        #expect(try now().placedFromPageText && now().textAnchored && now().normalizedRect == Self.rect, "after the move's undo")

        Self.step(undo) { _ = state.resizeRegion(region.id, page: 0, newRect: Self.rect.insetBy(dx: -0.01, dy: 0), undoManager: undo) }
        #expect(try now().placedFromPageText && !now().textAnchored, "after a resize")
        undo.undo()
        #expect(try now().placedFromPageText && now().textAnchored && now().normalizedRect == Self.rect, "after the resize's undo")

        Self.step(undo) { _ = state.moveRegions([(id: region.id, newRect: Self.rect.offsetBy(dx: 0, dy: 0.03))], page: 0, undoManager: undo) }
        #expect(try now().placedFromPageText && !now().textAnchored, "after a group move")
        undo.undo()
        #expect(try now().placedFromPageText && now().textAnchored, "after the group move's undo")

        undo.redo()
        #expect(try now().placedFromPageText && !now().textAnchored, "after the group move's redo")
    }

    @Test("A duplicate of a box placed from the text is drawn by hand: neither mark")
    func duplicateIsDrawnByHand() throws {
        let state = RedactionState()
        let region = Self.placed()
        state.addRegion(region, page: 0, undoManager: nil)
        state.duplicateRegion(region.id, page: 0, undoManager: nil)
        let copy = try #require(state.regions[0]?.first { $0.id != region.id })
        #expect(copy.source == .manual && !copy.placedFromPageText && !copy.textAnchored)
    }

    @Test("A box placed from a picture-read result carries neither mark, and a move leaves it so")
    func pictureReadBox() throws {
        let state = RedactionState()
        let region = Self.placed(.ocr(confidence: 0.9))
        state.addRegion(region, page: 0, undoManager: nil)
        _ = state.moveRegion(region.id, page: 0, newRect: Self.rect.offsetBy(dx: 0.05, dy: 0), undoManager: nil, anchored: true)
        let moved = try #require(state.regions[0]?.first)
        #expect(!moved.placedFromPageText && !moved.textAnchored)
    }
}
