import Testing
import Foundation
import CoreGraphics
import Observation
import RedactionEngine
@testable import ResectaApp

// The one Select All on Page rule and the one Deselect All, invoked as the
// surfaces invoke them: the toolbar's two menus, Command-A and Escape, and
// the long-press menu. Each surface calls the rule in
// `RedactionState+Selection`; none re-types the assignment or the gate.

@Suite("Selection rule")
@MainActor
struct SelectionRuleTests {

    /// Two regions on page 0 and two on page 1.
    private func twoPages() -> (state: RedactionState, p0: [RedactionRegion], p1: [RedactionRegion]) {
        let state = RedactionState()
        func make(_ y: Double) -> RedactionRegion {
            RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.1, y: y, width: 0.2, height: 0.05), source: .manual)
        }
        let p0 = [make(0.1), make(0.3)]
        let p1 = [make(0.1), make(0.3)]
        p0.forEach { state.addRegion($0, page: 0, undoManager: nil) }
        p1.forEach { state.addRegion($0, page: 1, undoManager: nil) }
        return (state, p0, p1)
    }

    // MARK: - The gate

    @Test("Two selected on page 0 leave Select All on Page open on page 1")
    func gateOpenOnAnotherPage() {
        let (state, p0, _) = twoPages()
        state.selectedRegionIDs = Set(p0.map(\.id))
        #expect(state.canSelectAllOnPage(1))
    }

    @Test("Every region of the page selected closes the gate; an empty page is closed")
    func gateClosed() {
        let (state, _, p1) = twoPages()
        state.selectedRegionIDs = Set(p1.map(\.id))
        #expect(state.canSelectAllOnPage(1) == false)
        #expect(state.canSelectAllOnPage(5) == false, "a page with no region")
    }

    @Test("A ghost id or a member on another page never closes the gate")
    func ghostsAndOtherPagesDoNotClose() {
        let (state, p0, p1) = twoPages()
        state.selectedRegionIDs = Set(p0.map(\.id)).union([UUID()]).union([p1[0].id])
        #expect(state.canSelectAllOnPage(1), "page 1 still holds an unselected region")
    }

    // MARK: - The actions

    @Test("Select All on Page selects exactly the page's regions")
    func selectAllOnPageSelectsThePage() {
        let (state, p0, p1) = twoPages()
        state.selectedRegionIDs = [p0[0].id]
        state.selectAllOnPage(1)
        #expect(state.selectedRegionIDs == Set(p1.map(\.id)))
        #expect(state.canSelectAllOnPage(1) == false)
        state.checkInvariants()
    }

    @Test("Deselect All empties the selection, and writes nothing when it is already empty")
    func deselectAllEmpties() {
        let (state, p0, _) = twoPages()
        state.selectedRegionIDs = Set(p0.map(\.id))
        state.deselectAllRegions()
        #expect(state.selectedRegionIDs.isEmpty)
        let changed = SelectionChangeFlag()
        withObservationTracking {
            _ = state.selectedRegionIDs
        } onChange: {
            changed.fired = true
        }
        state.deselectAllRegions()
        #expect(changed.fired == false, "an empty selection is not written")
        state.checkInvariants()
    }

    // MARK: - Every surface calls the one rule

    @Test("The toolbar's … menu, the Rectangle tool's entry and the keyboard call the one rule and re-type nothing")
    func surfacesCallTheRule() throws {
        let toolbar = try loadRepoFile("Sources/ResectaApp/Views/DocumentEditorToolbar.swift")
        let keyboard = try loadRepoFile("Sources/ResectaApp/Views/DocumentEditorKeyboard.swift")
        for source in [toolbar, keyboard] {
            #expect(!source.contains("selectedRegionIDs = Set("), "no surface re-types Select All")
            #expect(!source.contains("selectedRegionIDs = []"), "no surface re-types Deselect All")
        }
        #expect(toolbar.components(separatedBy: "selectAllOnPage(").count - 1 == 1, "the … menu's selectionMenu calls it")
        #expect(toolbar.components(separatedBy: "deselectAllRegions()").count - 1 == 2, "the … menu's selectionMenu and the Rectangle tool's entry call it")
        #expect(keyboard.contains("selectAllOnPage(") && keyboard.contains("deselectAllRegions()"), "Command-A and Escape call it")
    }

    private func loadRepoFile(_ relativePath: String, file: StaticString = #filePath) throws -> String {
        let repoRoot = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // Tests/ResectaAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
        return try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}

/// Set by an observation's change handler, which runs off the test's actor.
nonisolated private final class SelectionChangeFlag: @unchecked Sendable {
    var fired = false
}
