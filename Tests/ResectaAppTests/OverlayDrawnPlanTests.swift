import PDFKit
import Testing
import UIKit
@testable import ResectaApp
@testable import RedactionEngine

// G-06a in the app: drawing a page's regions keeps the plan the page is drawn
// from, made by the one maker the run's entry uses, from the same regions and
// the source document's crop box and rotation, with the settings it was drawn
// under. What the overlay paints is unchanged (its look is U-B14's).

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
}
