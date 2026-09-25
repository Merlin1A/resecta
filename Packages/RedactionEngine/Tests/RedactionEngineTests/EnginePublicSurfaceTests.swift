import CoreGraphics
import Foundation
import PDFKit
import Testing
import RedactionEngine

// The document-runner surface (ENGINEERING.md §9) pinned at compile time.
//
// This file imports the engine WITHOUT `@testable`, so it sees only `public`
// declarations: making any symbol named here `internal` stops the test target
// from compiling. Everything else in the package is reachable by the other
// suites through `@testable import`. The pin covers presence only — it does
// not stop a new declaration from being made public.

@Suite("Engine public surface")
struct EnginePublicSurfaceTests {

    @Test("The document-runner surface resolves through a plain import")
    func documentRunnerSurfaceIsPublic() {
        let types: [Any.Type] = [
            PDFPageData.self,
            PageRasterizer.self,
            PDFStreamReconstructor.self,
            DetectionOrchestrator.self,
            DocumentSearcher.self,
            VerificationEngine.self,
            VerificationOrchestrator.self,
            TempExportDirectory.self,
            TempFileHardening.self,
            ExportMetadata.self,
            MatchAuditExporter.self,
            AppliedSearchQuery.self,
            AppliedSearchRecord.self,
            SearchRecheckRequest.self,
            VerificationReport.self,
            LayerResult.self,
            VerificationLayer.self,
            SearchMode.self,
            SearchOptions.self,
            SearchResult.self,
            SearchPreviewResult.self,
        ]
        #expect(types.count == 21)
        #expect(DocumentSearcher.maxResults > 0)
        #expect(DocumentSearcher.validateRegexPattern("[a-z]+") != nil)
    }

    /// Never called: it type-checks only while every member it names is public.
    private func runnerMembers(
        rasterizer: PageRasterizer,
        page: PDFPageData,
        orchestrator: DetectionOrchestrator,
        image: CGImage,
        priors: PerCategoryPriors,
        surfaceForms: SurfaceFormDictionary,
        searcher: DocumentSearcher,
        document: SendablePDFDocument,
        pdfPage: PDFPage,
        mode: SearchMode,
        engine: VerificationEngine,
        layers: [LayerResult]
    ) async throws {
        _ = try await rasterizer.rasterize(page)
        _ = try await orchestrator.detectPage(
            image: image, pageIndex: 0, priors: priors,
            surfaceForms: surfaceForms, doctypeContext: nil
        )
        _ = searcher.search(document, mode: mode, progress: { _, _ in })
        _ = await searcher.previewMatches(
            mode: mode, scope: .wholeDocument, currentPageIndex: 0,
            totalPageCount: 1, pageTextProvider: { _ in nil }
        )
        _ = searcher.boundingRect(for: NSRange(location: 0, length: 1), page: pdfPage)
        await searcher.setThresholdVector(nil)
        await searcher.setUserTerms(nil)
        await searcher.setOverlapSink(nil)
        await searcher.setBelowThresholdSink(nil)
        await searcher.setRegexTimeoutSink(nil)
        await searcher.setRegexRejectionSink(nil)
        await searcher.setOCRSkipSink(nil)
        await searcher.setUserTermsTimeoutSink(nil)
        await searcher.setTextLayerStatus([:])
        await searcher.setScannedRegionNotAnalyzedSink(nil)
        _ = try DocumentSearcher.validateRegexPatternWithError("x")
        _ = DocumentSearcher.sharedLoadDiagnostics
        _ = engine.layers(for: .searchableRedaction)
        _ = engine.aggregateStatus(layers)
        _ = await engine.runLayer(
            0, outputDocument: document, sourcePageCount: 1, regions: [:],
            sensitiveTerms: [], pipelineMode: .searchableRedaction,
            filterDigests: [], perPageModes: []
        )
        _ = await engine.runLayer(
            .textExtraction, outputDocument: document, sourcePageCount: 1, regions: [:],
            sensitiveTerms: [], pipelineMode: .searchableRedaction,
            filterDigests: [], perPageModes: []
        )
    }
}
