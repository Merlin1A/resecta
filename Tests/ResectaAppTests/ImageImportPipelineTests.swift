import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import ResectaApp
@testable import RedactionEngine

// Image pages through the run: the mode gate rasterizes them in a
// Searchable run and records why, OCR reads a 24 MP photographed page
// inside the render caps, and a Secure run with verification passes.

@Suite("Image import: the pipeline", .tags(.importFlow))
@MainActor
struct ImageImportPipelineTests {

    static let settings = PipelineCoordinator.RunSettings(
        pipelineMode: .searchableRedaction, autoVerify: true,
        paranoidMode: false, fillColor: .black, exportDPI: 300)

    @Test("Image pages take Secure rasterization with the no-text reason in a Searchable run")
    func modeGateRasterizesImagePages() async throws {
        let loaded = try await ImageImportLoaderTests.loadStream([
            ImageFixtures.jpeg(width: 600, height: 400, text: "DELIA 2291"), ImageFixtures.png()])
        let pages = RunInputs.pageData(
            document: loaded.document.document, regions: [:],
            textLayerStatus: loaded.facts.textLayerStatus,
            sourceHasHiddenOCG: loaded.facts.hasHiddenOCG,
            settings: Self.settings, effectiveMode: .searchableRedaction)
        #expect(pages.count == 2)
        for page in pages {
            #expect(page.pipelineMode == .secureRasterization)
            #expect(page.fallbackReason == .noExtractableText)
            #expect(page.hasText == false)
        }
    }

    @Test("A 24 MP photo of a page is read on the OCR route, never skipped as oversized")
    func ocrReadsTheWordOnTheOCRRoute() async throws {
        let loaded = try await ImageImportLoaderTests.load(
            ImageFixtures.jpeg(width: 6000, height: 4000, marker: false, text: "DELIA 2291"))
        let page = try ImageImportLoaderTests.page(loaded)
        let box = page.getBoxRect(.mediaBox)
        // The OCR render at 300 pixels per inch is the page's own pixels: inside both caps.
        #expect(box.width * 300 / 72 <= 10_000 && box.height * 300 / 72 <= 10_000)
        #expect((box.width * 300 / 72) * (box.height * 300 / 72) <= 36_000_000)

        let searcher = DocumentSearcher()
        await searcher.setTextLayerStatus(loaded.facts.textLayerStatus)
        let routes = RouteLog()
        await searcher.setPageCoverageSink { routes.add($0.route) }
        var options = SearchOptions()
        options.includeOCR = true
        var matched: [String] = []
        for await result in searcher.search(loaded.document, mode: .text("DELIA", options: options), progress: { _, _ in }) {
            matched.append(result.matchedText)
        }
        #expect(matched.contains { $0.uppercased().contains("DELIA") }, "matches: \(matched)")
        #expect(routes.routes.contains(.ocr), "routes: \(routes.routes)")
        #expect(!routes.routes.contains(.ocrSkippedOversize), "routes: \(routes.routes)")
    }

    @Test("Image → Redact (Secure) → Verify: every layer passes")
    func secureRunVerifies() async throws {
        let loaded = try await ImageImportLoaderTests.loadStream([
            ImageFixtures.jpeg(width: 1200, height: 900, text: "DELIA 2291"), ImageFixtures.png(width: 900, height: 1200)])
        let coord = makeLoadedCoordinator(document: loaded.document.document)
        coord.documentState.textLayerStatus = loaded.facts.textLayerStatus
        coord.documentState.sourceFacts = loaded.facts.summary
        coord.settingsState.autoVerify = true
        coord.redactionState.regions[0] = [RedactionRegion(
            id: UUID(), normalizedRect: CGRect(x: 0.25, y: 0.35, width: 0.5, height: 0.3), source: .manual)]

        coord.runFullPipeline(documentOverride: .secureRasterization)
        _ = await coord.documentState.activePipelineTask?.value

        guard case .verified(let report) = coord.documentState.phase else {
            Issue.record("the run ended in \(coord.documentState.phaseKind): \(coord.documentState.phase)")
            return
        }
        #expect(report.perPageModes == [.secureRasterization, .secureRasterization])
        #expect(!report.overallStatus.isFail && !report.overallStatus.isWarn, "\(report.overallStatus)")
        for layer in report.layers {
            #expect(!layer.status.isFail && !layer.status.isWarn, "\(layer.name): \(layer.status) — \(layer.shortDescription)")
        }
        #expect(report.layers.contains { $0.status == .pass }, "layers ran: \(report.layers.map(\.name))")
    }
}

/// Collects the searcher's per-page coverage routes from its sink.
nonisolated private final class RouteLog: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [PageSearchCoverage.Route] = []
    var routes: [PageSearchCoverage.Route] { lock.lock(); defer { lock.unlock() }; return collected }
    func add(_ route: PageSearchCoverage.Route) { lock.lock(); collected.append(route); lock.unlock() }
}
