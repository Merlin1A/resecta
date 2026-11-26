import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import ResectaApp
@testable import RedactionEngine

/// The run's entry records, for each page, the quality the editor last
/// drew it at, kept apart from the plans and whatever the page's version,
/// so a page changed while off screen still holds what the person saw; a
/// page never drawn records none. Through the run's own entry
/// (`PipelineRunner.captureRunEntry`), so the one line that wires it is read.
@Suite("The shown quality at the run's entry")
@MainActor
struct ShownQualityAtRunEntryTests {

    static func region(top: CGFloat) -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.1, y: 1 - top - 0.05, width: 0.3, height: 0.05),
                        source: .manual)
    }

    /// Keeps a plan of `page` as the editor draws it, at `dpi`, and the
    /// quality it was shown at.
    static func keep(_ coord: PipelineCoordinator, page: Int, dpi: Int) throws {
        let state = coord.redactionState
        let pdfPage = try #require(coord.documentState.sourceDocument?.page(at: page))
        let regions = state.regions[page] ?? []
        state.drawnPlans[page] = DrawnPlan(
            pageIndex: page, regions: regions, cropBox: pdfPage.bounds(for: .cropBox).size,
            rotation: pdfPage.rotation, switchOn: false, exportDPI: dpi, fillColor: .black)
            .stamped(pageVersion: state.pageVersion(page), fromStoredRegions: true)
        state.shownDPIs[page] = dpi
    }

    @Test("A page with a current kept plan, a page shown and then changed while off screen, and a page never drawn")
    func shownQualityComesFromWhatWasDrawn() async throws {
        let coord = makeLoadedCoordinator(document: makeMultiPagePDFDocument(pages: 3))
        let state = coord.redactionState
        for page in 0..<3 { state.addRegion(Self.region(top: 0.1), page: page, undoManager: nil) }
        try Self.keep(coord, page: 0, dpi: 300)
        try Self.keep(coord, page: 1, dpi: 300)
        // Page 1 changes after it was drawn: a box added while it is off screen.
        state.addRegion(Self.region(top: 0.5), page: 1, undoManager: nil)
        #expect(state.drawnPlans[1]?.pageVersion != state.pageVersion(1), "precondition: page 1's kept plan is older")
        // Page 2 is never drawn.
        #expect(state.drawnPlans[2] == nil)

        let entry = try await PipelineRunner.captureRunEntry(
            coordinator: coord, effectiveMode: .secureRasterization,
            runSettings: .snapshot(from: coord.settingsState), capture: { .empty })
        func shown(_ page: Int) throws -> Int? {
            let data = try #require(entry.pages.first { $0.pageIndex == page }, "page \(page) is built")
            let confirmed = try #require(data.confirmedPage, "page \(page) carries its record")
            return confirmed.shownDPI
        }
        #expect(try shown(0) == 300, "a page with a current kept plan")
        #expect(try shown(1) == 300, "a page shown at 300 and changed while off screen keeps what it showed")
        #expect(try shown(2) == nil, "a page never drawn records no shown quality")
    }

    @Test("A page whose kept plan was made again at 150 while it was last shown at 300: the run's entry records 300")
    func shownQualityIsNotThePlans() async throws {
        let coord = makeLoadedCoordinator(document: makeMultiPagePDFDocument(pages: 1))
        let state = coord.redactionState
        state.addRegion(Self.region(top: 0.1), page: 0, undoManager: nil)
        // A change of the cap made the plan again at 150; the page was last drawn at 300.
        try Self.keep(coord, page: 0, dpi: 150)
        state.shownDPIs[0] = 300
        let entry = try await PipelineRunner.captureRunEntry(
            coordinator: coord, effectiveMode: .secureRasterization,
            runSettings: .snapshot(from: coord.settingsState), capture: { .empty })
        let data = try #require(entry.pages.first { $0.pageIndex == 0 }, "page 0 is built")
        let confirmed = try #require(data.confirmedPage, "page 0 carries its record")
        #expect(confirmed.shownDPI == 300, "the plan's 150 is not what was shown")
    }
}
