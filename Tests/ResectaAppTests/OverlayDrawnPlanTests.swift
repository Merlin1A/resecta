import PDFKit
import Testing
import UIKit
@testable import ResectaApp
@testable import RedactionEngine

// In the app: drawing a page's regions keeps the plan the page is drawn
// from, made by the one maker the run's entry uses, from the same regions and
// the source document's crop box and rotation, with the settings it was drawn
// under. What the overlay paints is unchanged.

@MainActor
@Suite("The overlay keeps the plan a page is drawn from")
struct OverlayDrawnPlanTests {

    /// A one-page document of A4's sides, turned a quarter.
    static func document() throws -> PDFDocument {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595.2756, height: 841.8898))
            .pdfData { $0.beginPage() }
        let pdf = try #require(PDFDocument(data: data))
        try #require(pdf.page(at: 0)).rotation = 90
        return pdf
    }

    @Test("Drawing a page keeps its plan as the run's entry makes it, with the quality and the fill")
    func drawingKeepsThePlan() throws {
        let pdf = try Self.document()
        let regions = [RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.04), source: .manual),
                       RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.5, y: 0.6, width: 0.2, height: 0.03), source: .manual)]
        let documentState = DocumentState()
        documentState.sourceDocument = pdf
        let state = RedactionState()
        // The page's stored regions, as the editor holds them: two changes to
        // page 0, so the page is at version 2.
        for region in regions { state.addRegion(region, page: 0, undoManager: nil) }
        let defaults = try #require(UserDefaults(suiteName: "OverlayDrawnPlanTests.drawingKeepsThePlan"))
        defaults.removePersistentDomain(forName: "OverlayDrawnPlanTests.drawingKeepsThePlan")
        let settings = SettingsState(defaults: defaults)
        settings.exportDPI = 150
        settings.fillColor = .white
        let coordinator = PDFViewCoordinator()
        coordinator.documentState = documentState
        coordinator.redactionState = state
        coordinator.settingsState = settings
        let overlay = RedactionOverlayView(frame: CGRect(x: 0, y: 0, width: 300, height: 420))
        overlay.coordinator = coordinator
        overlay.pageIndex = 0
        overlay.geometry = RunRecord.PageGeometry(page: try #require(pdf.page(at: 0)), box: .cropBox)
        overlay.configure(with: regions, selectedIDs: [])
        #expect(state.drawnPlans[0] == nil)

        _ = UIGraphicsImageRenderer(size: overlay.bounds.size).image { overlay.drawCommittedRegions(ctx: $0.cgContext, in: overlay.bounds) }

        let kept = try #require(state.drawnPlans[0])
        let page = try #require(pdf.page(at: 0))
        // The engine's DrawnPlanTests pin this maker's plan to the run entry's.
        // Kept at the page's version (2: its two stored regions) and drawn
        // from the stored regions.
        let expected = DrawnPlan(pageIndex: 0, regions: regions, cropBox: page.bounds(for: .cropBox).size,
                                 rotation: page.rotation, switchOn: false, exportDPI: 150, fillColor: .white)
            .stamped(pageVersion: 2, fromStoredRegions: true)
        #expect(page.rotation == 90)
        #expect(kept == expected)
        #expect(kept != DrawnPlan(pageIndex: 0, regions: regions, cropBox: page.bounds(for: .cropBox).size,
                                  rotation: 0, switchOn: false, exportDPI: 150, fillColor: .white)
            .stamped(pageVersion: 2, fromStoredRegions: true))
        #expect(kept.boxes.map(\.regionIDs) == regions.map { [$0.id] })
        #expect(kept.exportDPI == 150 && kept.fillColor == .white && kept.switchOn == false)

        // A changed setting is kept at the next drawing.
        settings.fillColor = .black
        _ = UIGraphicsImageRenderer(size: overlay.bounds.size).image { overlay.drawCommittedRegions(ctx: $0.cgContext, in: overlay.bounds) }
        #expect(state.drawnPlans[0]?.fillColor == .black)
    }

    /// A coordinator wired to `pdf` and `state`, with the chosen quality 300.
    static func coordinator(_ pdf: PDFDocument, _ state: RedactionState, suite: String) throws -> PDFViewCoordinator {
        let documentState = DocumentState()
        documentState.sourceDocument = pdf
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsState(defaults: defaults)
        settings.exportDPI = 300
        let coordinator = PDFViewCoordinator()
        coordinator.documentState = documentState
        coordinator.redactionState = state
        coordinator.settingsState = settings
        return coordinator
    }

    @Test("Under the cap of 150 a drawn page keeps its plan at 150, the quality the run uses")
    func keptPlanReadsTheCap() throws {
        let pdf = try Self.document()
        let state = RedactionState()
        let coordinator = try Self.coordinator(pdf, state, suite: "OverlayDrawnPlanTests.keptPlanReadsTheCap")
        #expect(coordinator.qualityCap == 300)
        let regions = [RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.04), source: .manual)]
        coordinator.noteDrawn(pageIndex: 0, regions: regions)
        #expect(state.drawnPlans[0]?.exportDPI == 300)
        coordinator.qualityCap = 150
        coordinator.noteDrawn(pageIndex: 0, regions: regions)
        let page = try #require(pdf.page(at: 0))
        let kept = try #require(state.drawnPlans[0])
        #expect(kept.exportDPI == 150)
        #expect(kept.exportDPI == runQuality(chosenDPI: 300, dpiCap: 150, cropBox: page.bounds(for: .cropBox).size,
                                             rotation: page.rotation))
        #expect(kept.filledPixels == DrawnPlan(pageIndex: 0, regions: regions, cropBox: page.bounds(for: .cropBox).size,
                                               rotation: page.rotation, switchOn: false, exportDPI: 150,
                                               fillColor: kept.fillColor).filledPixels)
    }

    @Test("A cap that changes while a page is on screen keeps that page's plan at the new quality")
    func aCapChangeRedrawsThePagesOnScreen() throws {
        let pdf = try Self.document()
        let state = RedactionState()
        let region = RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.5, y: 0.6, width: 0.2, height: 0.03), source: .manual)
        state.regions[0] = [region]
        let coordinator = try Self.coordinator(pdf, state, suite: "OverlayDrawnPlanTests.aCapChangeRedraws")
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 300, height: 420))
        view.document = pdf
        let page = try #require(pdf.page(at: 0))
        let overlay = try #require(coordinator.pdfView(view, overlayViewFor: page))
        #expect(overlay is RedactionOverlayView)
        coordinator.noteDrawn(pageIndex: 0, regions: [region])
        #expect(state.drawnPlans[0]?.exportDPI == 300)
        coordinator.qualityCap = 150
        #expect(state.drawnPlans[0]?.exportDPI == 150, "the page on screen keeps its plan at the cap")
        coordinator.pdfView(view, willEndDisplayingOverlayView: overlay, for: page)
        coordinator.qualityCap = 300
        #expect(state.drawnPlans[0]?.exportDPI == 300, "a page off screen is kept at the new quality too")
        #expect(state.drawnPlans[0]?.pageVersion == state.pageVersion(0))
    }

    @Test("A page's version moves with its own stored regions only, Undo included")
    func pageVersionsMoveByPage() {
        let state = RedactionState()
        let undo = UndoManager()
        undo.groupsByEvent = false
        let a = RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.03), source: .manual)
        let b = RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.4, y: 0.5, width: 0.2, height: 0.03), source: .manual)
        #expect(state.pageVersion(0) == 0 && state.pageVersion(4) == 0)
        state.addRegion(a, page: 0, undoManager: nil)
        #expect(state.pageVersion(0) == 1 && state.pageVersion(4) == 0)
        undo.beginUndoGrouping()
        state.addRegion(b, page: 4, undoManager: undo)
        undo.endUndoGrouping()
        #expect(state.pageVersion(0) == 1 && state.pageVersion(4) == 1, "a change on page 5 leaves page 1's version")
        undo.undo()
        #expect(state.regions[4] ?? [] == [])
        #expect(state.pageVersion(4) == 2, "an Undo is a change of the page")
        #expect(state.pageVersion(0) == 1)
        undo.redo()
        #expect(state.pageVersion(4) == 3)
    }

    @Test("A kept plan carries the page's version and whether it was drawn from the stored regions")
    func keptPlanIsStamped() throws {
        let pdf = try Self.document()
        let state = RedactionState()
        let region = RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.5, y: 0.6, width: 0.2, height: 0.03), source: .manual)
        state.addRegion(region, page: 0, undoManager: nil)
        let coordinator = try Self.coordinator(pdf, state, suite: "OverlayDrawnPlanTests.keptPlanIsStamped")
        coordinator.noteDrawn(pageIndex: 0, regions: [region])
        #expect(state.drawnPlans[0]?.pageVersion == 1)
        #expect(state.drawnPlans[0]?.fromStoredRegions == true)
        // A drag draws a working copy.
        var moved = region
        moved.normalizedRect = region.normalizedRect.offsetBy(dx: 0.05, dy: 0)
        coordinator.noteDrawn(pageIndex: 0, regions: [moved])
        #expect(state.drawnPlans[0]?.pageVersion == 1)
        #expect(state.drawnPlans[0]?.fromStoredRegions == false)
        // A change off screen leaves the kept plan at the version it was made at.
        state.removeRegion(region.id, page: 0, undoManager: nil)
        #expect(state.pageVersion(0) == 2)
        #expect(state.drawnPlans[0]?.pageVersion == 1)
    }

    @Test("A cap change during a drag, then the lift: the kept plan is at the new quality")
    func aCapChangeMidDragThenLift() throws {
        let pdf = try Self.document()
        let state = RedactionState()
        let region = RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.5, y: 0.6, width: 0.2, height: 0.03), source: .manual)
        state.addRegion(region, page: 0, undoManager: nil)
        let coordinator = try Self.coordinator(pdf, state, suite: "OverlayDrawnPlanTests.aCapChangeMidDragThenLift")
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 300, height: 420))
        view.document = pdf
        let page = try #require(pdf.page(at: 0))
        let overlay = try #require(coordinator.pdfView(view, overlayViewFor: page) as? RedactionOverlayView)
        overlay.frame = CGRect(x: 0, y: 0, width: 300, height: 420)
        func draw() {
            _ = UIGraphicsImageRenderer(size: overlay.bounds.size).image {
                overlay.drawCommittedRegions(ctx: $0.cgContext, in: overlay.bounds)
            }
        }
        // The drag draws a working copy.
        var moved = region
        moved.normalizedRect = region.normalizedRect.offsetBy(dx: 0.05, dy: 0)
        overlay.configure(with: [moved], selectedIDs: [])
        draw()
        #expect(state.drawnPlans[0]?.fromStoredRegions == false && state.drawnPlans[0]?.exportDPI == 300)
        // The cap falls mid-drag; the page on screen redraws its working copy.
        coordinator.qualityCap = 150
        draw()
        #expect(state.drawnPlans[0]?.fromStoredRegions == false && state.drawnPlans[0]?.exportDPI == 150)
        // The lift stores the move; the page draws the stored regions.
        #expect(state.moveRegion(region.id, page: 0, newRect: moved.normalizedRect, undoManager: nil))
        coordinator.refreshOverlay(for: 0)
        draw()
        let kept = try #require(state.drawnPlans[0])
        #expect(kept.exportDPI == 150, "no plan from before the cap change survives the lift")
        #expect(kept.fromStoredRegions == true)
        #expect(kept.pageVersion == state.pageVersion(0))
    }

    @Test("A cap change keeps no plan of regions a page was not drawn with")
    func aCapChangeKeepsOnlyWhatWasDrawn() throws {
        let pdf = try Self.document()
        let state = RedactionState()
        let region = RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.5, y: 0.6, width: 0.2, height: 0.03), source: .manual)
        state.addRegion(region, page: 0, undoManager: nil)
        let coordinator = try Self.coordinator(pdf, state, suite: "OverlayDrawnPlanTests.aCapChangeKeepsOnlyWhatWasDrawn")
        coordinator.noteDrawn(pageIndex: 0, regions: [region])
        let other = RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.03), source: .manual)
        state.addRegion(other, page: 0, undoManager: nil)
        coordinator.qualityCap = 150
        let kept = try #require(state.drawnPlans[0])
        #expect(kept.exportDPI == 300, "a plan of an older version is left as it was")
        #expect(kept.pageVersion == 1)
        #expect(kept.boxes.count == 1)
    }

    @Test("Source pin: the editor's view hands the coordinator the run's cap")
    func theViewHandsOnTheCap() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ResectaApp/Views/PDFDocumentView.swift"), encoding: .utf8)
        #expect(source.contains("coordinator.qualityCap = pipelineCoordinator.dpiCap"))
    }

    @Test("Source pin: the editor's view hands the coordinator the settings, when it makes it and on each update")
    func theViewHandsOnTheSettings() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ResectaApp/Views/PDFDocumentView.swift"), encoding: .utf8)
        // Without the settings the coordinator keeps no plan (noteDrawn).
        #expect(source.components(separatedBy: "coordinator.settingsState = settingsState").count - 1 == 2)
    }

    @Test("A new document, or clearing all, drops the plans kept for the last one")
    func aNewDocumentDropsTheKeptPlans() {
        let region = RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.04),
                                     source: .manual)
        let plan = DrawnPlan(pageIndex: 0, regions: [region], cropBox: CGSize(width: 612, height: 792), rotation: 0,
                             switchOn: false, exportDPI: 300, fillColor: .black)
        let state = RedactionState()
        state.drawnPlans[0] = plan
        state.clearForNewDocument()
        #expect(state.drawnPlans.isEmpty)
        state.drawnPlans[0] = plan
        state.clearAll()
        #expect(state.drawnPlans.isEmpty)
    }
}
