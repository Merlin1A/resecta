import Testing
import Foundation
import PDFKit
@testable import ResectaApp
@testable import RedactionEngine

// The run's inputs as pure functions: the page-data bridge driven with
// plain values, no coordinator or state object in scope.

@Suite("Run inputs")
@MainActor
struct RunInputsTests {

    /// A run-settings snapshot from a scratch defaults suite.
    private func settings() -> PipelineCoordinator.RunSettings {
        let name = "run-inputs-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let snapshot = PipelineCoordinator.RunSettings.snapshot(from: SettingsState(defaults: defaults))
        defaults.removePersistentDomain(forName: name)
        return snapshot
    }

    @Test("Secure mode: every page is secure, carries its regions filtered and clamped, no fallback reason")
    func secureModePages() {
        let doc = makeMultiPagePDFDocument(pages: 2)
        let tiny = RedactionRegion(
            id: UUID(), normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.0005, height: 0.3), source: .manual)
        let spill = RedactionRegion(
            id: UUID(), normalizedRect: CGRect(x: 0.8, y: 0.8, width: 0.5, height: 0.5), source: .manual)
        let snapshot = settings()

        let pages = RunInputs.pageData(
            document: doc, regions: [0: [tiny, spill]],
            textLayerStatus: [0: .rich, 1: .rich], sourceHasHiddenOCG: true,
            settings: snapshot, effectiveMode: .secureRasterization)

        #expect(pages.map(\.pageIndex) == [0, 1])
        #expect(pages.map(\.pipelineMode) == [.secureRasterization, .secureRasterization])
        #expect(pages[0].regions.count == 1, "the sub-threshold region is dropped")
        #expect(pages[0].regions[0].normalizedRect.maxX <= 1.0)
        #expect(pages[0].regions[0].normalizedRect.maxY <= 1.0)
        #expect(pages[1].regions.isEmpty)
        #expect(pages.allSatisfy { $0.fallbackReason == nil })
        #expect(pages.allSatisfy { $0.hasHiddenOCG })
        #expect(pages.allSatisfy { $0.targetDPI == snapshot.exportDPI })
        #expect(pages.allSatisfy { !$0.hasText }, "secure pages skip the text read")
    }

    @Test("A box past the page edge keeps its on-page part; a sliver or a box wholly off the page is dropped")
    func boxesAtThePageEdge() throws {
        let doc = makeMultiPagePDFDocument(pages: 1)
        let partlyOff = RedactionRegion(
            id: UUID(), normalizedRect: CGRect(x: 0.95, y: 0.2, width: 0.1, height: 0.1), source: .manual)
        let sliver = RedactionRegion(
            id: UUID(), normalizedRect: CGRect(x: 0.9995, y: 0.4, width: 0.01, height: 0.1), source: .manual)
        let whollyOff = RedactionRegion(
            id: UUID(), normalizedRect: CGRect(x: 1.2, y: 0.6, width: 0.1, height: 0.1), source: .manual)

        let pages = RunInputs.pageData(
            document: doc, regions: [0: [partlyOff, sliver, whollyOff]],
            textLayerStatus: [0: .rich], sourceHasHiddenOCG: false,
            settings: settings(), effectiveMode: .secureRasterization)

        let rects = pages[0].regions.map(\.normalizedRect)
        #expect(rects.count == 1, "the sliver and the wholly off-page box are dropped: \(rects)")
        let kept = try #require(rects.first)
        let expected = CGRect(x: 0.95, y: 0.2, width: 0.05, height: 0.1)
        #expect(abs(kept.minX - expected.minX) < 1e-9 && abs(kept.minY - expected.minY) < 1e-9
                && abs(kept.width - expected.width) < 1e-9 && abs(kept.height - expected.height) < 1e-9,
                "the box past the edge keeps its on-page part: \(kept)")
        #expect(rects.allSatisfy { $0.width > 0.001 && $0.height > 0.001 },
                "no region reaches the pipeline below the floor after the clamp")
    }

    @Test("Searchable mode: a rich page is searchable with text; a sparse page falls back for want of text")
    func searchableModeFallsBackPerPage() {
        let snapshot = settings()

        let rich = RunInputs.pageData(
            document: makeTextPDFDocument(text: "Hello run inputs"), regions: [:],
            textLayerStatus: [0: .rich], sourceHasHiddenOCG: false,
            settings: snapshot, effectiveMode: .searchableRedaction)
        #expect(rich.count == 1)
        #expect(rich[0].pipelineMode == .searchableRedaction)
        #expect(rich[0].fallbackReason == nil)
        #expect(rich[0].hasText)
        #expect(!rich[0].hasHiddenOCG)

        let sparse = RunInputs.pageData(
            document: makeMultiPagePDFDocument(pages: 1), regions: [:],
            textLayerStatus: [0: .sparse], sourceHasHiddenOCG: false,
            settings: snapshot, effectiveMode: .searchableRedaction)
        #expect(sparse.count == 1)
        #expect(sparse[0].pipelineMode == .secureRasterization)
        #expect(sparse[0].fallbackReason == .noExtractableText)
    }
}
