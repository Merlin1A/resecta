import Testing
import Foundation
import PDFKit
import CoreGraphics
import CoreText
@testable import RedactionEngine

extension VerificationEngineTests {

    // MARK: - Layer 1 / Layer 2 Silent-Bypass Hardening

    @Test("Layer 1 warns when documentURL is nil (AcroForm cannot be checked)")
    func layer1WarnsOnCGPDFDocumentFailure() async throws {
        // PDFDocument loaded from Data has no documentURL, so the
        // CGPDFDocument(url:) chain cannot verify /AcroForm.
        let doc = try await makeCleanPDFWithoutURL()

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .textExtraction, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        #expect(result.status.isWarn,
                "Layer 1 should warn when CGPDFDocument cannot be opened")
    }

    @Test("Layer 2 OCR-checks a no-JPEG page via the thumbnail fallback")
    func layer2ThumbnailFallbackChecksNoJPEGPage() async throws {
        // Before this fix a page with no extractable JPEG XObject was added to
        // uncheckedPages and the layer WARNed. Now the layer renders a PDFPage
        // thumbnail and OCRs it instead, so a vector page with no text is now
        // genuinely checked (OCR ran) and PASSes rather than warning unchecked.
        let (doc, url) = try makeVectorOnlyPDF()
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .ocrCheck, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization]
        )
        #expect(result.status == .pass,
                "vector page (no text) is OCR-checked via thumbnail → pass; got \(result.status)")
    }

    // MARK: - Layer 2: Multi-image + thumbnail fallback

    @Test("extractPageImages returns every image XObject on a page")
    func multiImagePageBothImagesOCRd() async throws {
        // Two JPEG XObjects on one page. Pre-fix extractPageImage returned a
        // single CGImage (first XObject only, via `return false`);
        // extractPageImages returns both, and runLayer2OCR OCRs each.
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.twoImageJPEGPagePDF(), prefix: "twoimg_")
        defer { try? FileManager.default.removeItem(at: url) }
        let page = try #require(doc.page(at: 0))
        let cgPage = try #require(page.pageRef)

        let extraction = VerificationEngine.extractPageImages(from: cgPage)
        #expect(extraction.images.count == 2,
                "both embedded JPEG XObjects must be extracted; got \(extraction.images.count)")
        #expect(extraction.failedDecodeCount == 0,
                "well-formed JPEGs must not count as decode failures")
    }

    @Test("Multi-image page with a region + text → conservative WARN")
    func multiImagePageConservativeWarn() async throws {
        // Per-image Vision coordinates cannot be identity-mapped to page space
        // (C-B contract); with a region present and OCR text found, the page is
        // surfaced as a WARN rather than an identity-mapped FAIL/PASS.
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.twoImageJPEGPagePDF(textA: "ALPHA", textB: "BRAVO"),
            prefix: "twoimg_warn_")
        defer { try? FileManager.default.removeItem(at: url) }

        let region = manualRegion(CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9))
        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .ocrCheck, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [0: [region]], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization])
        #expect(result.status.isWarn,
                "multi-image page with a region must conservatively WARN; got \(result.status)")
    }

    @Test("aspectMatches: unpadded matches, letterboxed mismatches")
    func thumbnailAspectMismatchIsConservative() {
        // A thumbnail whose aspect matches the requested page aspect is trusted
        // (unpadded); a mismatched (letterboxed) render is not — its
        // observations must be treated conservatively, never identity-mapped.
        #expect(VerificationEngine.aspectMatches(
            CGSize(width: 612, height: 792), CGSize(width: 612, height: 792)))
        #expect(VerificationEngine.aspectMatches(
            CGSize(width: 1224, height: 1584), CGSize(width: 612, height: 792)),
            "2× scale keeps the aspect → still trusted")
        #expect(!VerificationEngine.aspectMatches(
            CGSize(width: 792, height: 792), CGSize(width: 612, height: 792)),
            "square render of a portrait page is padded → not trusted")
    }

    // MARK: - Page references for Layers 1/2/3

    @Test("Layer 1 accumulates annotation pages across the document and returns 0-based references")
    func layer1AnnotationPagesAccumulatedWithReferences() async throws {
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.threePageAnnotationsOnFirstAndThird(), prefix: "l1_annot_pages_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .textExtraction, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 3, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [],
            perPageModes: Array(repeating: .secureRasterization, count: 3))
        #expect(result.status.isFail,
                "annotations in output must FAIL; got \(result.status)")
        #expect(result.pageReferences == [0, 2],
                "both annotation pages must be referenced 0-based; got \(String(describing: result.pageReferences))")
        if case .fail(let msg) = result.status {
            #expect(msg.contains("2 pages"),
                    "message must name both pages, not stop at the first; got \(msg)")
        }
    }

    @Test("Layer 1 accumulates selectable-text pages across the document by per-page mode and returns 0-based references")
    func layer1SelectableTextPagesAccumulatedWithReferences() async throws {
        // Text on pages 1 and 3, page 2 blank. The per-page modes declare
        // pages 1 and 3 image-only (page 2 Searchable): both text pages are
        // reported, accumulated across the document rather than stopping at
        // the first.
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withSensitiveTermOnFirstAndThirdPages(term: "Acme"),
            prefix: "l1_text_pages_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .textExtraction, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 3, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [],
            perPageModes: [.secureRasterization, .searchableRedaction, .secureRasterization])
        #expect(result.status.isFail,
                "selectable text on pages declared image-only must FAIL; got \(result.status)")
        #expect(result.pageReferences == [0, 2],
                "both text pages must be referenced 0-based; got \(String(describing: result.pageReferences))")
        if case .fail(let msg) = result.status {
            #expect(msg.contains("2 pages"),
                    "message must name both pages, not stop at the first; got \(msg)")
        }
    }

    @Test("Layer 2 in-region FAIL carries the winning bucket's pages as 0-based references")
    func layer2InRegionFailCarriesPageReferences() async throws {
        let size = CGSize(width: 600, height: 800)
        let image = try renderTextPageImage(
            [("HEADER", CGPoint(x: 40, y: 700), 80)], size: size)
        let (doc, url) = try await makeImagePDF(image, size: size)
        defer { try? FileManager.default.removeItem(at: url) }

        let topBand = manualRegion(CGRect(x: 0, y: 0.55, width: 1.0, height: 0.43))
        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .ocrCheck, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [0: [topBand]], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization])
        #expect(result.status.isFail,
                "in-region text on a Secure-Rasterized page must FAIL; got \(result.status)")
        // Message numbering is 1-based ("page 1"); references are 0-based.
        #expect(result.pageReferences == [0],
                "references must be the message's page list minus one; got \(String(describing: result.pageReferences))")
    }

    @Test("Layer 3 accumulates decoded-page hits across the document with 0-based references")
    func layer3DecodedPagesAccumulatedWithReferences() async throws {
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.withSensitiveTermOnFirstAndThirdPages(term: "Acme"),
            prefix: "l3_decoded_pages_")
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .binaryStringSearch, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 3, regions: [:], sensitiveTerms: ["acme"].map { SensitiveTerm(text: $0) },
            pipelineMode: .searchableRedaction,
            filterDigests: [nil, nil, nil],
            perPageModes: Array(repeating: .searchableRedaction, count: 3))
        #expect(result.status.isAttention,
                "decoded-page leak must flag (residual tier); got \(result.status)")
        #expect(result.pageReferences == [0, 2],
                "both decoded hit pages must be referenced 0-based; got \(String(describing: result.pageReferences))")
        if case .attention(let msg) = result.status {
            #expect(msg.contains("2 pages"),
                    "message must name both pages, not stop at the first; got \(msg)")
            #expect(msg.contains("instances"), "count stays in the message; got \(msg)")
        }
    }

    // MARK: - Layer-2 decode cap

    @Test("extractPageImages caps the transient decode size")
    func extractPageImagesDecodeCap() async throws {
        // 5000-px JPEG: an uncapped decode would exceed the 4096-px OCR cap;
        // the bounded thumbnail decode must come back within it.
        let jpeg = TestFixtures.solidJPEG(width: 5000, height: 120)
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.pdfWithDCTImageStream(jpeg), prefix: "decode_cap_")
        defer { try? FileManager.default.removeItem(at: url) }
        let page = try #require(doc.page(at: 0))
        let cgPage = try #require(page.pageRef)

        let extraction = VerificationEngine.extractPageImages(from: cgPage)
        #expect(extraction.failedDecodeCount == 0)
        let image = try #require(extraction.images.first)
        #expect(max(image.width, image.height) <= 4096,
                "decode must be capped at the OCR pixel ceiling; got \(image.width)x\(image.height)")
    }

    @Test("Layer 2 buckets a page with an undecodable image as unchecked")
    func layer2UndecodableImageUnchecked() async throws {
        // A DCTDecode stream whose bytes are not a decodable JPEG: the page
        // was never OCR-checked, so it must WARN as unchecked rather than
        // fall through to the thumbnail path and read as clean.
        var bad = Data([0xFF, 0xD8, 0xFF, 0xE0])
        bad.append(Data(repeating: 0x00, count: 64))
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.pdfWithDCTImageStream(bad), prefix: "bad_jpeg_")
        defer { try? FileManager.default.removeItem(at: url) }
        let page = try #require(doc.page(at: 0))
        let cgPage = try #require(page.pageRef)

        let extraction = VerificationEngine.extractPageImages(from: cgPage)
        #expect(extraction.failedDecodeCount == 1,
                "undecodable DCT stream must count as a decode failure")
        #expect(extraction.images.isEmpty)

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .ocrCheck, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization])
        #expect(result.status.isWarn, "got \(result.status)")
        if case .warn(let msg) = result.status {
            #expect(msg.contains("OCR could not be run"), "got: \(msg)")
            #expect(result.couldNotVerify, "OCR could not be run: the check did not fully run")
        }
        #expect(result.pageReferences == [0],
                "got \(String(describing: result.pageReferences))")
    }

    private func makeCleanPDFWithoutURL() async throws -> PDFDocument {
        let (_, url) = try await makeCleanPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)
        guard let doc = PDFDocument(data: data) else { throw TestError.failed }
        return doc
    }

    /// Build a single-page vector-only PDF. No image XObjects, so
    /// `extractPageImage` returns nil on every page.
    private func makeVectorOnlyPDF() throws -> (PDFDocument, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("verify_vector_\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 300)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw TestError.failed
        }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
        ctx.endPDFPage()
        ctx.closePDF()
        guard let doc = PDFDocument(url: url) else { throw TestError.failed }
        return (doc, url)
    }
}
