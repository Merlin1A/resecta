import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import RedactionEngine

// L-18 / L-19 — PageRasterizer memory-safety guards.

@Suite("PageRasterizer Memory Safety")
struct PageRasterizerTests {

    // MARK: - L-19: Pre-flight size rejection

    @Test("renderPageWithTimeout rejects 50,000-pt-wide pages before drawPDFPage")
    func rejectsPageTooLarge() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pagetoolarge_\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try synthesizeOversizedPDF(at: url, width: 50_000, height: 500)

        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else {
            Issue.record("Failed to load synthesized oversized PDF")
            return
        }

        let rasterizer = PageRasterizer()
        do {
            _ = try await rasterizer.renderPageWithTimeout(page, pageIndex: 0, dpi: 150)
            Issue.record("Expected pageTooLarge error, got success")
        } catch let error as PipelineError {
            guard case .redactionError(.pageTooLarge(let p)) = error else {
                Issue.record("Expected .pageTooLarge, got \(error)")
                return
            }
            #expect(p == 0)
        }
    }

    @Test("renderPageWithTimeout accepts in-range page dimensions")
    func acceptsNormalPageDimensions() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pagenormal_\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try synthesizeOversizedPDF(at: url, width: 612, height: 792)

        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else {
            Issue.record("Failed to load synthesized PDF")
            return
        }

        let rasterizer = PageRasterizer()
        // Should succeed without throwing .pageTooLarge.
        let image = try await rasterizer.renderPageWithTimeout(
            page, pageIndex: 0, dpi: 150
        )
        #expect(image.width > 0)
        #expect(image.height > 0)
    }

    // MARK: - L-18: dpiCap ceiling

    @Test("rasterize(dpiCap: 150) produces 150-DPI bitmap even when targetDPI is 300")
    func rasterizeRespectsDPICap() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pagecap_\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try synthesizeOversizedPDF(at: url, width: 612, height: 792)
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else {
            Issue.record("Failed to load synthesized PDF")
            return
        }

        let pageData = PDFPageData(
            page: page, pageIndex: 0, regions: [],
            fillColor: .black, targetDPI: 300,
            pipelineMode: .secureRasterization, rotation: 0,
            // CAT-127: rasterize() now reads the pre-extracted geometry + CG page.
            cropBoxBounds: page.bounds(for: .cropBox),
            cgPage: page.pageRef,
            hasText: false
        )

        let rasterizer = PageRasterizer()
        let result = try await rasterizer.rasterize(pageData, dpiCap: 150)

        // At 150 DPI, a 612 × 792 pt page yields 612 × 150/72 = 1275 px wide,
        // 792 × 150/72 = 1650 px tall. 300 DPI would produce 2550 × 3300.
        // ceil() in the rasterizer permits +/-1 pixel rounding.
        #expect(result.pageOutput.image.width <= 1276,
                "cap should prevent 300 DPI bitmap (got \(result.pageOutput.image.width) wide)")
        #expect(result.pageOutput.image.height <= 1651,
                "cap should prevent 300 DPI bitmap (got \(result.pageOutput.image.height) tall)")
    }

    // MARK: - CAT-127: CG-only concurrent render path guards

    @Test("rasterize follows the pre-extracted cropBox geometry, not the live PDFPage (decoy)")
    func rasterizeUsesPreExtractedGeometryNotLivePDFPage() async throws {
        // G2 (decoy). `page` is a deliberately larger decoy; `cropBoxBounds`/
        // `cgPage` come from the smaller target. Pre-rewiring the rasterizer reads
        // `page.page.bounds`/renders `page.page` → output follows the DECOY (red).
        // Post-rewiring it uses `cropBoxBounds`/`cgPage` → output follows the
        // TARGET (green). `.secureRasterization` so `extractCharacters` (which
        // legitimately still reads `page.page`) never runs.
        let targetURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cf-g2-target-\(UUID().uuidString).pdf")
        let decoyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cf-g2-decoy-\(UUID().uuidString).pdf")
        defer {
            try? FileManager.default.removeItem(at: targetURL)
            try? FileManager.default.removeItem(at: decoyURL)
        }
        try synthesizeOversizedPDF(at: targetURL, width: 612, height: 792)
        try synthesizeOversizedPDF(at: decoyURL, width: 1224, height: 1584)

        guard let targetDoc = PDFDocument(url: targetURL), let targetPage = targetDoc.page(at: 0),
              let decoyDoc = PDFDocument(url: decoyURL), let decoyPage = decoyDoc.page(at: 0) else {
            Issue.record("Failed to load G2 fixtures"); return
        }
        let targetBounds = targetPage.bounds(for: .cropBox)
        let decoyBounds = decoyPage.bounds(for: .cropBox)
        // L3-13: the delta must be unambiguous at the selected DPI.
        #expect(targetBounds.size != decoyBounds.size,
                "decoy and target must differ in size for this guard to discriminate")

        let pageData = PDFPageData(
            page: decoyPage, pageIndex: 0, regions: [],
            fillColor: .black, targetDPI: 300,
            pipelineMode: .secureRasterization, rotation: 0,
            cropBoxBounds: targetBounds,
            cgPage: targetPage.pageRef,
            hasText: false
        )

        let rasterizer = PageRasterizer()
        let result = try await rasterizer.rasterize(pageData, dpiCap: 150)

        // selectDPI honours the 150 cap for this size (see rasterizeRespectsDPICap):
        // the TARGET (612×792 pt) renders to 1275×1650 px, the DECOY (1224×1584)
        // would render to 2550×3300 — the output must follow the target geometry.
        let expectedW = Int((targetBounds.width * 150 / 72).rounded(.up))
        let expectedH = Int((targetBounds.height * 150 / 72).rounded(.up))
        #expect(abs(result.pageOutput.image.width - expectedW) <= 1,
                "width must follow pre-extracted target geometry (got \(result.pageOutput.image.width), expected \(expectedW) from target, decoy would give \(Int((decoyBounds.width * 150 / 72).rounded(.up))))")
        #expect(abs(result.pageOutput.image.height - expectedH) <= 1,
                "height must follow pre-extracted target geometry (got \(result.pageOutput.image.height), expected \(expectedH))")
    }

    @Test("rasterize throws bitmapCreationFailed when the pre-extracted cgPage is nil")
    func rasterizeThrowsBitmapFailedForNilCGPage() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cf-g3-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try synthesizeOversizedPDF(at: url, width: 612, height: 792)
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else {
            Issue.record("Failed to load G3 fixture"); return
        }

        let pageData = PDFPageData(
            page: page, pageIndex: 7, regions: [],
            fillColor: .black, targetDPI: 150,
            pipelineMode: .secureRasterization, rotation: 0,
            cropBoxBounds: page.bounds(for: .cropBox),
            cgPage: nil,  // explicit: the concurrent path has no CG page to draw
            hasText: false
        )

        let rasterizer = PageRasterizer()
        do {
            _ = try await rasterizer.rasterize(pageData, dpiCap: 150)
            Issue.record("Expected .bitmapCreationFailed, got success (cgPage nil was ignored)")
        } catch let error as PipelineError { // LegalPhrases:safe (Swift keyword)
            guard case .redactionError(.bitmapCreationFailed(let p)) = error else {
                Issue.record("Expected .bitmapCreationFailed, got \(error)"); return
            }
            #expect(p == 7)
        }
    }

    @Test("Parallel rasterize matches the serial reference per page (dimensions)")
    func rasterizeParallelMatchesSerialReference() async throws {
        let url = try synthesizeMultiPagePDF(pageCount: 4, width: 612, height: 792)
        defer { try? FileManager.default.removeItem(at: url) }
        guard let doc = PDFDocument(url: url) else {
            Issue.record("Failed to load parity fixture"); return
        }
        func buildPageData() -> [PDFPageData] {
            (0..<doc.pageCount).compactMap { i in
                guard let page = doc.page(at: i) else { return nil }
                return PDFPageData(
                    page: page, pageIndex: i, regions: [],
                    fillColor: .black, targetDPI: 150,
                    pipelineMode: .secureRasterization, rotation: 0,
                    cropBoxBounds: page.bounds(for: .cropBox),
                    cgPage: page.pageRef, hasText: false
                )
            }
        }

        // Serial reference.
        let serialRasterizer = PageRasterizer()
        var serialDims: [(Int, Int)] = []
        for pd in buildPageData() {
            let r = try await serialRasterizer.rasterize(pd, dpiCap: 150)
            serialDims.append((r.pageOutput.image.width, r.pageOutput.image.height))
        }

        // Parallel.
        let parallelRasterizer = PageRasterizer()
        let pages = buildPageData()
        let parallelDims = try await withThrowingTaskGroup(of: (Int, Int, Int).self) { group in
            for pd in pages {
                group.addTask {
                    let r = try await parallelRasterizer.rasterize(pd, dpiCap: 150)
                    return (pd.pageIndex, r.pageOutput.image.width, r.pageOutput.image.height)
                }
            }
            var out: [Int: (Int, Int)] = [:]
            for try await (idx, w, h) in group { out[idx] = (w, h) }
            return out
        }

        for i in 0..<serialDims.count {
            let (sw, sh) = serialDims[i]
            guard let (pw, ph) = parallelDims[i] else {
                Issue.record("Parallel run missing page \(i)"); continue
            }
            #expect(abs(pw - sw) <= 1 && abs(ph - sh) <= 1,
                    "page \(i): parallel (\(pw)×\(ph)) must match serial (\(sw)×\(sh)) ±1px")
        }
    }

    // MARK: - Helpers

    /// Synthesize a single-page PDF at the given point dimensions. Used to
    /// drive pre-flight tests with pathological sizes.
    private func synthesizeOversizedPDF(
        at url: URL, width: CGFloat, height: CGFloat
    ) throws {
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw TestError.pdfContextFailed
        }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.endPDFPage()
        ctx.closePDF()
    }

    /// Synthesize a multi-page PDF at uniform point dimensions (parity fixture).
    private func synthesizeMultiPagePDF(
        pageCount: Int, width: CGFloat, height: CGFloat
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cf-multipage-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw TestError.pdfContextFailed
        }
        for _ in 0..<pageCount {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    private enum TestError: Error {
        case pdfContextFailed
    }
}

// MARK: - PD-5: effective per-page fallback reason (RC-5)

@Suite("PageRasterizer Fallback Reason")
struct PageRasterizerFallbackReasonTests {

    /// PDFPageData over the first page of `data` with the given mode/flags.
    private func makePageData(
        from data: Data, pipelineMode: PipelineMode,
        hasHiddenOCG: Bool = false, hasText: Bool,
        fallbackReason: TextLayerDetector.FallbackReason? = nil
    ) throws -> PDFPageData {
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        return PDFPageData(
            page: page, pageIndex: 0, regions: [],
            fillColor: .black, targetDPI: 150,
            pipelineMode: pipelineMode, rotation: 0,
            hasHiddenOCG: hasHiddenOCG,
            cropBoxBounds: page.bounds(for: .cropBox),
            cgPage: page.pageRef,
            hasText: hasText,
            fallbackReason: fallbackReason
        )
    }

    @Test("Runtime extraction throw records .extractionFailed and still rasterizes")
    func runtimeThrowRecordsExtractionFailed() async throws {
        // The OCG defense makes extractCharacters throw (AD-2-1 fixture); the
        // page must complete as Secure Rasterization AND the result must say
        // why — the reason used to be dropped at this exact point (RC-5).
        let data = TestFixtures.ocgHiddenLayerPDF(hiddenText: "CONFIDENTIAL")
        let pageData = try makePageData(
            from: data, pipelineMode: .searchableRedaction,
            hasHiddenOCG: true, hasText: true
        )

        let rasterizer = PageRasterizer()
        let result = try await rasterizer.rasterize(pageData, dpiCap: 150)
        #expect(result.fallbackReason == .extractionFailed)
        #expect(result.filterDigest == nil)
        #expect(result.pageOutput.textLayerEntries == nil)
        #expect(result.pageOutput.image.width > 0)
    }

    @Test("Pre-flight reason carries through to the RasterizeResult")
    func preflightReasonCarriesThrough() async throws {
        // buildPDFPageData records the trigger and routes the page to secure
        // rasterization; rasterize() must surface that same reason.
        let data = TestFixtures.textLayerPDF(text: "plain fixture page text")
        let pageData = try makePageData(
            from: data, pipelineMode: .secureRasterization,
            hasText: false, fallbackReason: .rtlText
        )

        let rasterizer = PageRasterizer()
        let result = try await rasterizer.rasterize(pageData, dpiCap: 150)
        #expect(result.fallbackReason == .rtlText)
        #expect(result.filterDigest == nil)
    }

    @Test("Page that keeps searchable mode carries no reason")
    func searchableSuccessCarriesNoReason() async throws {
        let data = TestFixtures.textLayerPDF(
            text: "Sufficient plain English fixture text for a searchable page."
        )
        let pageData = try makePageData(
            from: data, pipelineMode: .searchableRedaction, hasText: true
        )

        let rasterizer = PageRasterizer()
        let result = try await rasterizer.rasterize(pageData, dpiCap: 150)
        #expect(result.fallbackReason == nil)
        #expect(result.filterDigest != nil)
    }

    @Test("Secure-raster-mode page carries no reason (rasterized by choice)")
    func secureModePageCarriesNoReason() async throws {
        let data = TestFixtures.textLayerPDF(text: "plain fixture page text")
        let pageData = try makePageData(
            from: data, pipelineMode: .secureRasterization, hasText: false
        )

        let rasterizer = PageRasterizer()
        let result = try await rasterizer.rasterize(pageData, dpiCap: 150)
        #expect(result.fallbackReason == nil)
    }
}
