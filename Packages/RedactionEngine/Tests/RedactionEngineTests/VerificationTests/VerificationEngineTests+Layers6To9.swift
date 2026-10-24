import Testing
import Foundation
import PDFKit
import CoreGraphics
import CoreText
@testable import RedactionEngine

extension VerificationEngineTests {

    // MARK: - Layer 6: spatial-exclusion check on region-less searchable pages

    @Test("Layer 6 runs the spatial-exclusion check on region-less searchable pages")
    func layer6RunsOnRegionlessPage() async throws {
        // regions: [:] — pre-fix runLayer6 skipped region-less pages entirely
        // (guard !pageRegions.isEmpty), so a tampered region-less searchable
        // page passed Layer 6. After the split the empty maps flow into
        // verifySpatialExclusion(regionShapes: []) and the spatial-exclusion lattice FAILs.
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withBlandKerningInjection(), prefix: "layer6_regionless_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .spatialVerification, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .searchableRedaction,
            filterDigests: [], perPageModes: [.searchableRedaction]
        )
        #expect(result.status.isFail,
                "Layer 6 must run the spatial-exclusion check on a tampered region-less page; got \(result.status)")
    }

    // MARK: - Layers 7 & 9: Skipped-Layer Honesty
    //
    // On the verify-only resume path the per-page filter digests are rebuilt
    // all-nil, so the digest-consuming cross-checks (Layer 7 character count,
    // Layer 9 character lineage) run zero comparisons. They must report the
    // truth (.skipped) rather than a silent .pass. Pre-fix these returned
    // .pass — the assertions below are the failing-then-green pins.

    @Test("Layer 7 returns .skipped when all eligible pages have nil digests")
    func layer7AllNilDigestsReturnsSkipped() async throws {
        let (doc, url) = try makeBlankPDF(pageCount: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .characterCount, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 2, regions: [:], sensitiveTerms: [],
            pipelineMode: .searchableRedaction,
            filterDigests: [nil, nil],
            perPageModes: [.searchableRedaction, .searchableRedaction]
        )
        #expect(result.status == .skipped,
                "Layer 7 eligible-but-unchecked must report .skipped, not .pass")
    }

    @Test("Layer 9 returns .skipped when all eligible pages have nil digests")
    func layer9AllNilDigestsReturnsSkipped() async throws {
        let (doc, url) = try makeBlankPDF(pageCount: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .characterLineage, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 2, regions: [:], sensitiveTerms: [],
            pipelineMode: .searchableRedaction,
            filterDigests: [nil, nil],
            perPageModes: [.searchableRedaction, .searchableRedaction]
        )
        #expect(result.status == .skipped,
                "Layer 9 eligible-but-unchecked must report .skipped, not .pass")
    }

    @Test("Layer 7 stays .pass when no page is eligible (all per-page SR)")
    func layer7AllSRPagesStaysPass() async throws {
        // eligible == 0 (every page is per-page Secure Rasterization, e.g. a
        // rotated-page stopgap): the layer is skipped by design and
        // must stay .pass — promoting it would WARN-flag valid docs.
        let (doc, url) = try makeBlankPDF(pageCount: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .characterCount, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 2, regions: [:], sensitiveTerms: [],
            pipelineMode: .searchableRedaction,
            filterDigests: [nil, nil],
            perPageModes: [.secureRasterization, .secureRasterization]
        )
        #expect(result.status == .pass,
                "Layer 7 with zero eligible pages stays .pass (skipped by design)")
    }

    // MARK: - Layers 6–9: Per-Page Mode Coverage
    //
    // The four Searchable-layer dispatchers select their pages through
    // `perPageModes[i]`. An array shorter than the document used to drop
    // its tail from the check and land on `.pass` having compared nothing
    // there. They now report the uncovered pages as a WARN on the
    // otherwise-PASS exit, with the uncovered pages as page references.
    // The coordinator always supplies one mode per page, so these pins
    // exercise a defensive arm for callers that do not.
    //
    // Layers 7 and 9 keep their `.skipped` precedence: a covered
    // Searchable page with a nil digest is eligible-but-unchecked and
    // reports `.skipped` before the coverage arm is reached, so their pins
    // cover the one page with per-page Secure Rasterization (zero eligible
    // pages — the exit that used to stay `.pass`). Layers 6 and 8 check
    // the covered blank page and reach the coverage arm on its PASS exit.

    @Test("Layer 6 WARNs when perPageModes is shorter than the document")
    func layer6ShortPerPageModesWarns() async throws {
        try await expectCoverageWarn(
            layerIndex: 5, label: "Layer 6", coveredMode: .searchableRedaction)
    }

    @Test("Layer 7 WARNs when perPageModes is shorter than the document")
    func layer7ShortPerPageModesWarns() async throws {
        try await expectCoverageWarn(
            layerIndex: 6, label: "Layer 7", coveredMode: .secureRasterization)
    }

    @Test("Layer 8 WARNs when perPageModes is shorter than the document")
    func layer8ShortPerPageModesWarns() async throws {
        try await expectCoverageWarn(
            layerIndex: 7, label: "Layer 8", coveredMode: .searchableRedaction)
    }

    @Test("Layer 9 WARNs when perPageModes is shorter than the document")
    func layer9ShortPerPageModesWarns() async throws {
        try await expectCoverageWarn(
            layerIndex: 8, label: "Layer 9", coveredMode: .secureRasterization)
    }

    // MARK: - Per-page mode on pages declared Secure Rasterization

    @Test("Layer 6 FAILs a secure-declared page that carries a text layer")
    func layer6SecureDeclaredPageWithTextFails() async throws {
        // A real text layer on a page the run declared image-only: the
        // writer never draws text on such a page, so this is a tampered or
        // foreign output — a FAIL, not a skip.
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.textLayerPDF(text: "Hello World"), prefix: "l6_secure_text_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .spatialVerification, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .searchableRedaction,
            filterDigests: [nil],
            perPageModes: [.secureRasterization])
        #expect(result.status.isFail,
                "a page declared image-only that carries a text layer must FAIL, not be skipped; got \(result.status)")
        if case .fail(let msg) = result.status {
            #expect(msg.contains("image-only"), "got: \(msg)")
            #expect(msg.contains("page 1"), "copy prints the 1-based page number; got: \(msg)")
        }
        #expect(result.pageReferences == [0],
                "0-based reference to the offending page; got \(String(describing: result.pageReferences))")
    }

    @Test("Layer 6 still skips a secure-declared page with no text")
    func layer6SecureDeclaredBlankPagePasses() async throws {
        let (doc, url) = try makeBlankPDF(pageCount: 1)
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .spatialVerification, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .searchableRedaction,
            filterDigests: [nil],
            perPageModes: [.secureRasterization])
        #expect(result.status == .pass,
                "an image-only page with no text layer is not position-checked and passes; got \(result.status)")
        #expect(result.pageReferences == nil,
                "got \(String(describing: result.pageReferences))")
    }

    @Test("Layer 6 reports unmeasured-position characters as a WARN with the page referenced")
    func layer6ZeroBoundsUnitsWarnWithReference() async throws {
        // Page 1 is a normal text page; page 2 carries glyphs PDFKit cannot
        // place. The per-page WARN from the exclusion pass reaches the layer
        // result with the offending page referenced (below FAIL, above the
        // unreadable-page and coverage WARNs).
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.zeroBoundsGlyphPDF(text: "AB"), prefix: "l6_zero_bounds_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .spatialVerification, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .searchableRedaction,
            filterDigests: [nil],
            perPageModes: [.searchableRedaction])
        #expect(result.status.isWarn, "got \(result.status)")
        if case .warn(let msg) = result.status {
            #expect(msg.contains("had no measurable position"), "got: \(msg)")
            #expect(msg.contains("not position-checked"), "got: \(msg)")
        }
        #expect(result.pageReferences == [0],
                "got \(String(describing: result.pageReferences))")
    }

    @Test("Layer 1 keys on the per-page mode, not the document mode")
    func layer1KeysOnPerPageMode() async throws {
        // Two text pages in a Searchable run; page 2 fell back to Secure
        // Rasterization. Only that page's text is reported — page 1's text
        // is expected under its own (Searchable) mode.
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.textPagesPDF(["Alpha page", "Beta page"]), prefix: "l1_perpage_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .textExtraction, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 2, regions: [:], sensitiveTerms: [],
            pipelineMode: .searchableRedaction,
            filterDigests: [nil, nil],
            perPageModes: [.searchableRedaction, .secureRasterization])
        #expect(result.status.isFail,
                "text on the page declared image-only must FAIL; got \(result.status)")
        if case .fail(let msg) = result.status {
            #expect(msg.contains("Selectable text found on page 2"), "got: \(msg)")
        }
        #expect(result.pageReferences == [1],
                "only the secure-declared page is referenced; got \(String(describing: result.pageReferences))")
    }

    /// Two-page blank document, a one-entry `perPageModes` (page 0 covered
    /// with `coveredMode`, page 1 beyond the array), all-nil digests:
    /// the layer must WARN with "not checked" and reference page 1.
    private func expectCoverageWarn(
        layerIndex: Int, label: String, coveredMode: PipelineMode
    ) async throws {
        let (doc, url) = try makeBlankPDF(pageCount: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            engine.layers(for: .searchableRedaction)[layerIndex], outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 2, regions: [:], sensitiveTerms: [],
            pipelineMode: .searchableRedaction,
            filterDigests: [nil, nil],
            perPageModes: [coveredMode]
        )
        #expect(result.status.isWarn, "\(label): got \(result.status)")
        if case .warn(let msg) = result.status {
            #expect(msg.contains("not checked"), "\(label): got: \(msg)")
        }
        #expect(result.pageReferences == [1],
                "\(label): got \(String(describing: result.pageReferences))")
    }

    // MARK: - Layer 9 cooperative cancellation

    @Test("Layer 9 surrenders to cancellation as .skipped")
    func layer9CancelledReturnsSkipped() async throws {
        // The digest's lineage hash deliberately mismatches the blank page,
        // so a run that ignored cancellation would FAIL — .skipped proves the
        // entry check surrendered first. The task cancels itself before
        // calling the layer, making the outcome order-deterministic (no
        // wall-clock assertion; the 50 ms latency budget is owned by the
        // report-only perf suite).
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.blankPage(), prefix: "l9_cancel_")
        defer { try? FileManager.default.removeItem(at: url) }
        let digest = PageFilterDigest(
            pageIndex: 0, extractedCount: 1, excludedCount: 0,
            survivingCount: 1, boundaryCharacters: [],
            lineageHash: Data([0x01]))

        let engine = VerificationEngine()
        let sendableDoc = SendablePDFDocument(doc)
        let task = Task { () -> LayerResult in
            withUnsafeCurrentTask { $0?.cancel() }
            return await engine.runLayer(
                .characterLineage, outputDocument: sendableDoc,
                sourcePageCount: 1, regions: [:], sensitiveTerms: [],
                pipelineMode: .searchableRedaction,
                filterDigests: [digest],
                perPageModes: [.searchableRedaction])
        }
        let result = await task.value
        #expect(result.status.isSkipped,
                "cancelled Layer 9 must surrender as .skipped; got \(result.status)")
    }

    /// Build an N-page blank (solid-white) PDF with a valid documentURL. Used
    /// by the Layer 7/9 skipped-honesty tests, where the layer short-circuits
    /// on the per-page-mode / nil-digest guards and never reads page content.
    private func makeBlankPDF(pageCount: Int) throws -> (PDFDocument, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("verify_blank_\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 300)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw TestError.failed
        }
        for _ in 0..<pageCount {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            ctx.fill(box)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        guard let doc = PDFDocument(url: url) else { throw TestError.failed }
        return (doc, url)
    }
}
