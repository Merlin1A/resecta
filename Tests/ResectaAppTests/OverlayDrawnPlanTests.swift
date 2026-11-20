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
        overlay.configure(with: regions, selectedIDs: [])
        #expect(state.drawnPlans[0] == nil)

        _ = UIGraphicsImageRenderer(size: overlay.bounds.size).image { overlay.drawCommittedRegions(ctx: $0.cgContext, in: overlay.bounds) }

        let kept = try #require(state.drawnPlans[0])
        let page = try #require(pdf.page(at: 0))
        // The engine's DrawnPlanTests pin this maker's plan to the run entry's.
        let expected = DrawnPlan(pageIndex: 0, regions: regions, cropBox: page.bounds(for: .cropBox).size,
                                 rotation: page.rotation, switchOn: false, exportDPI: 150, fillColor: .white)
        #expect(page.rotation == 90)
        #expect(kept == expected)
        #expect(kept != DrawnPlan(pageIndex: 0, regions: regions, cropBox: page.bounds(for: .cropBox).size,
                                  rotation: 0, switchOn: false, exportDPI: 150, fillColor: .white))
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
        #expect(state.drawnPlans[0]?.exportDPI == 150, "a page off screen is kept until it is drawn again")
    }

    @Test("Source pin: the editor's view hands the coordinator the run's cap")
    func theViewHandsOnTheCap() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ResectaApp/Views/PDFDocumentView.swift"), encoding: .utf8)
        #expect(source.contains("coordinator.qualityCap = pipelineCoordinator.dpiCap"))
    }
}
