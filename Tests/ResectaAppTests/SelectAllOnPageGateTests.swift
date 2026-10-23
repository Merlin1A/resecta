import Testing
import Foundation
import CoreGraphics
import RedactionEngine
@testable import ResectaApp

// The one Select All on Page gate: enabled while the page holds a region
// not yet selected, whatever is selected on other pages.
@Suite("Select All on Page gate", .tags(.overlay))
@MainActor
struct SelectAllOnPageGateTests {

    private func region(y: Double) -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.1, y: y, width: 0.2, height: 0.05), source: .manual)
    }

    @Test("Two selected on page 1 leave Select All on a two-region page 2 enabled")
    func otherPagesSelectionDoesNotDisable() {
        let state = RedactionState()
        let a = region(y: 0.1), b = region(y: 0.3)
        state.addRegion(a, page: 0, undoManager: nil)
        state.addRegion(b, page: 0, undoManager: nil)
        state.addRegion(region(y: 0.1), page: 1, undoManager: nil)
        state.addRegion(region(y: 0.3), page: 1, undoManager: nil)
        state.selectedRegionIDs = [a.id, b.id]
        #expect(state.canSelectAllOnPage(1))
        #expect(state.canSelectAllOnPage(0) == false, "page 1's regions are all selected")
    }

    @Test("An empty page has nothing to select")
    func emptyPageIsDisabled() {
        #expect(RedactionState().canSelectAllOnPage(0) == false)
    }
}
