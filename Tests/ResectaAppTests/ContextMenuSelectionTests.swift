import Testing
import Foundation
import CoreGraphics
import UIKit
import PDFKit
import RedactionEngine
@testable import ResectaApp

// The long-press menu on a region. Its rows come from one pure function
// the menu's action provider maps, so the rows are read here without
// UIKit's private menu API. On a region of a selected group the menu acts
// on the whole selection (Delete N Regions, Deselect All) and offers no
// Duplicate; on a whole-page region it offers no Duplicate either; on a
// region alone it keeps its single-region rows. Building the menu never
// changes the selection, and Delete N Regions deletes at once with one
// Undo step that brings them all back.

@Suite("Context menu on a selection")
@MainActor
struct ContextMenuSelectionTests {

    private static let size = CGSize(width: 400, height: 400)

    private static func threeRegions() -> [RedactionRegion] {
        [0.1, 0.4, 0.7].map {
            RedactionRegion(id: UUID(), normalizedRect: CGRect(x: $0, y: 0.7, width: 0.2, height: 0.1), source: .manual)
        }
    }

    private func titles(_ rows: [RedactionOverlayView.ContextMenuRow]) -> [String] { rows.map(\.title) }

    // MARK: - The rows

    @Test("On a region of a three-region selection: Delete 3 Regions and Deselect All, no Duplicate")
    func rowsOnASelection() {
        let regions = Self.threeRegions()
        let rows = RedactionOverlayView.contextMenuRows(
            for: regions[1], selectedIDs: Set(regions.map(\.id)),
            infoTitle: "Detected: Name", canSelectAllOnPage: false, showsRationale: true)
        let t = titles(rows)
        #expect(t.contains("Delete 3 Regions"))
        #expect(t.contains("Deselect All"))
        #expect(!t.contains("Duplicate Region"))
        #expect(!t.contains("Delete Region"))
        #expect(t.first == "Detected: Name", "the info row stays about the held region")
        #expect(t.contains("View Rationale"), "so does View Rationale")
    }

    @Test("On a whole-page region the menu offers no Duplicate")
    func noDuplicateForAWholePageRegion() {
        let page = RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1), source: .manual)
        let rows = RedactionOverlayView.contextMenuRows(
            for: page, selectedIDs: [page.id], infoTitle: nil, canSelectAllOnPage: false, showsRationale: false)
        #expect(!titles(rows).contains("Duplicate Region"))
        #expect(titles(rows).contains("Delete Region"))
    }

    @Test("On a region alone the menu keeps its single-region rows")
    func rowsOnARegionAlone() {
        let regions = Self.threeRegions()
        let alone = RedactionOverlayView.contextMenuRows(
            for: regions[0], selectedIDs: [regions[0].id], infoTitle: nil, canSelectAllOnPage: true, showsRationale: false)
        #expect(titles(alone) == ["Select All on Page", "Deselect", "Duplicate Region", "Delete Region"])
        let unselected = RedactionOverlayView.contextMenuRows(
            for: regions[0], selectedIDs: [], infoTitle: nil, canSelectAllOnPage: true, showsRationale: false)
        #expect(titles(unselected) == ["Select All on Page", "Duplicate Region", "Delete Region"])
    }

    // MARK: - Through the real coordinator

    private func mounted(selectedIDs: (([RedactionRegion]) -> Set<UUID>)) throws -> (
        overlay: RedactionOverlayView, coordinator: PDFViewCoordinator, state: RedactionState,
        window: UIWindow, regions: [RedactionRegion], undo: UndoManager
    ) {
        let regions = Self.threeRegions()
        let state = RedactionState()
        regions.forEach { state.addRegion($0, page: 0, undoManager: nil) }
        state.selectedRegionIDs = selectedIDs(regions)
        let coordinator = PDFViewCoordinator()
        coordinator.redactionState = state
        let window = UIWindow(frame: CGRect(origin: .zero, size: Self.size))
        let view = FitFlooredPDFView(frame: window.bounds)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: Self.size))
        view.document = PDFDocument(data: renderer.pdfData { ctx in ctx.beginPage() })
        window.addSubview(view)
        window.isHidden = false
        coordinator.pdfView = view
        let overlay = coordinator.pdfView(view, overlayViewFor: view.document!.page(at: 0)!) as! RedactionOverlayView
        overlay.frame = view.bounds
        overlay.snapZoomScaleOverride = 1
        view.addSubview(overlay)
        let undo = try #require(window.undoManager)
        return (overlay, coordinator, state, window, regions, undo)
    }

    @Test("Building the menu on a region of a selection leaves the selection as it was")
    func buildingTheMenuKeepsTheSelection() throws {
        let m = try mounted { Set($0.map(\.id)) }
        let before = m.state.selectedRegionIDs
        let interaction = UIContextMenuInteraction(delegate: m.overlay)
        _ = m.overlay.contextMenuInteraction(interaction, configurationForMenuAtLocation: CGPoint(x: 200, y: 100))
        #expect(m.state.selectedRegionIDs == before)
        m.state.checkInvariants()
    }

    @Test("Deselect All from the menu empties the selection")
    func deselectAllFromTheMenu() throws {
        let m = try mounted { Set($0.map(\.id)) }
        m.overlay.performContextMenuRow(.deselectAll, held: m.regions[1])
        #expect(m.state.selectedRegionIDs.isEmpty)
        m.state.checkInvariants()
    }

    @Test("Delete 3 Regions deletes them at once, and one Undo brings all three back")
    func deleteSelectionFromTheMenu() throws {
        let m = try mounted { Set($0.map(\.id)) }
        m.overlay.performContextMenuRow(.deleteSelection(count: 3), held: m.regions[1])
        #expect((m.state.regions[0] ?? []).isEmpty)
        m.state.checkInvariants()
        m.undo.undo()
        #expect(m.state.regions[0]?.count == 3)
        m.state.checkInvariants()
    }
}
