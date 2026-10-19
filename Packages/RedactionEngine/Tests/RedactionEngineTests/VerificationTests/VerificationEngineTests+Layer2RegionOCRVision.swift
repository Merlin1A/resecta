import Testing
import Foundation
import PDFKit
import CoreGraphics
import CoreText
@testable import RedactionEngine

extension VerificationEngineTests {

    // -- Vision integration fixtures (full-page JPEG → runLayer(1)) ----------

    @Test("Layer 2: SR out-of-region text WITH regions present → INFO (expected content, noted)")
    func layer2ScopedOCR_textOutsideRegions_secureInfoWhenRegionsPresent() async throws {
        let size = CGSize(width: 600, height: 800)
        let image = try renderTextPageImage(
            [("INCOME", CGPoint(x: 40, y: 680), 80)], size: size)   // top-left
        let (doc, url) = try await makeImagePDF(image, size: size)
        defer { try? FileManager.default.removeItem(at: url) }

        let region = manualRegion(CGRect(x: 0.6, y: 0.05, width: 0.3, height: 0.2)) // bottom-right
        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .ocrCheck, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [0: [region]], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization])
        // Readable non-redacted content outside every region is the page's
        // own: the check read it and reports nothing, so the arm is a PASS
        // whose detail says what was read (never a WARN — that tier is kept
        // for could-not-verify conditions — and never a note the summary
        // has to count). The leak this arm's old WARN chased is carried by
        // the specific arms: a redacted term surviving out-of-region raises
        // ATTENTION (pins below), in-region survivors FAIL. Without regions
        // the PASS carries no detail
        // (layer2ScopedOCR_textOutsideRegions_noRegions_passes).
        #expect(result.status == .pass,
                "SR out-of-region text with regions present is a PASS with a detail; got \(result.status)")
        #expect(result.detailDescription == VerificationEngine.layer2OutsideTextDetail,
                "the detail names the mechanism; got \(result.detailDescription)")
        #expect(result.hasDetail)
    }

    @Test("Layer 2: SR out-of-region text with NO regions → PASS (no over-block)")
    func layer2ScopedOCR_textOutsideRegions_noRegions_passes() async throws {
        let size = CGSize(width: 600, height: 800)
        let image = try renderTextPageImage(
            [("INCOME", CGPoint(x: 40, y: 680), 80)], size: size)
        let (doc, url) = try await makeImagePDF(image, size: size)
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .ocrCheck, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [:], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization])
        // documentHasRegions == false → the text is the raster's own content,
        // nothing was redacted to miss → PASS. Guards against over-blocking a
        // Secure-Rasterized document that carried no redaction regions.
        #expect(result.status == .pass,
                "SR text with no regions is the raster's own content → PASS; got \(result.status)")
    }

    @Test("Layer 2: Searchable out-of-region text → INFO (continuity preserved)")
    func layer2ScopedOCR_textOutsideRegions_searchable_info() async throws {
        let size = CGSize(width: 600, height: 800)
        let image = try renderTextPageImage(
            [("INCOME", CGPoint(x: 40, y: 680), 80)], size: size)
        let (doc, url) = try await makeImagePDF(image, size: size)
        defer { try? FileManager.default.removeItem(at: url) }

        let region = manualRegion(CGRect(x: 0.6, y: 0.05, width: 0.3, height: 0.2))
        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .ocrCheck, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [0: [region]], sensitiveTerms: [],
            pipelineMode: .searchableRedaction,
            filterDigests: [], perPageModes: [.searchableRedaction])
        // Selectable text outside regions is the Searchable page's own: a
        // PASS whose detail says it was read, never a note.
        #expect(result.status == .pass,
                "Searchable out-of-region text is a PASS with a detail; got \(result.status)")
        #expect(result.detailDescription == VerificationEngine.layer2OutsideTextDetail)
    }

    @Test("Layer 2: sensitive term inside a region → FAIL, page number only")
    func layer2ScopedOCR_sensitiveTermInsideRegion_fails() async throws {
        let size = CGSize(width: 600, height: 800)
        // A solid, common dictionary word recognizes reliably under the FROZEN
        // .fast verifier preset (a non-dictionary token like "SECRETCODE" can be
        // split/misread, defeating an exact term match). The term is synthetic —
        // no PII — so naming it in the fixture is safe.
        let term = "CONFIDENTIAL"
        let image = try renderTextPageImage(
            [(term, CGPoint(x: 30, y: 400), 64)], size: size)       // centered
        let (doc, url) = try await makeImagePDF(image, size: size)
        defer { try? FileManager.default.removeItem(at: url) }

        let region = manualRegion(CGRect(x: 0.02, y: 0.42, width: 0.95, height: 0.2))
        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .ocrCheck, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [0: [region]], sensitiveTerms: [term].map { SensitiveTerm(text: $0) },
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization])
        #expect(result.status.isFail, "term readable inside a region must FAIL; got \(result.status)")
        if case .fail(let msg) = result.status {
            // The FAIL message carries only the page number; document content
            // (the term) never echoes.
            #expect(msg.contains("1"))
            #expect(!msg.localizedCaseInsensitiveContains(term),
                    "FAIL message must never echo the matched term")
        }
    }

    @Test("Layer 2: SR text in a region → FAIL (page only); identity coordinate guard")
    func layer2ScopedOCR_textTopRegionTop_intersects() async throws {
        let size = CGSize(width: 600, height: 800)
        let image = try renderTextPageImage(
            [("HEADER", CGPoint(x: 40, y: 700), 80)], size: size)   // baseline high = top
        let (doc, url) = try await makeImagePDF(image, size: size)
        defer { try? FileManager.default.removeItem(at: url) }

        let topBand = manualRegion(CGRect(x: 0, y: 0.55, width: 1.0, height: 0.43))
        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .ocrCheck, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [0: [topBand]], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization])
        // Identity mapping: top text (high y) ∈ top band → in-region → FAIL
        // (readable text in a destroyed-pixel SR region is a leak, no term
        // needed). A reintroduced y-flip would map it low → out-of-region → the
        // INFO note, so identity vs flip stays distinguishable (FAIL ≠ INFO).
        #expect(result.status.isFail,
                "top text vs top region must intersect under identity mapping (FAIL); got \(result.status)")
        if case .fail(let msg) = result.status {
            // The FAIL message carries only the page number; document content is absent.
            #expect(msg.contains("1"))
            #expect(!msg.localizedCaseInsensitiveContains("HEADER"),
                    "FAIL message must not echo OCR'd content")
        }
    }

    @Test("Layer 2: coordinate guard — text BOTTOM, region TOP → out-of-region (INFO)")
    func layer2ScopedOCR_textBottomRegionTop_outOfRegion() async throws {
        let size = CGSize(width: 600, height: 800)
        let image = try renderTextPageImage(
            [("FOOTER", CGPoint(x: 40, y: 80), 80)], size: size)    // baseline low = bottom
        let (doc, url) = try await makeImagePDF(image, size: size)
        defer { try? FileManager.default.removeItem(at: url) }

        let topBand = manualRegion(CGRect(x: 0, y: 0.55, width: 1.0, height: 0.43))
        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .ocrCheck, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [0: [topBand]], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization])
        // Identity mapping: bottom text (low y) ∉ top band → out-of-region →
        // the PASS with the outside-text detail (regions present). A
        // reintroduced y-flip would map it high → in-region → FAIL, so
        // identity vs flip stays distinguishable (PASS ≠ FAIL).
        #expect(result.status == .pass,
                "bottom text vs top region must not intersect under identity mapping (out-of-region PASS); got \(result.status)")
        #expect(result.detailDescription == VerificationEngine.layer2OutsideTextDetail,
                "the outside-text detail marks the arm; got \(result.detailDescription)")
    }

    @Test("Layer 2: Searchable readable text inside a region → WARN (unchanged string)")
    func layer2ScopedOCR_textInRegion_searchable_warns() async throws {
        let size = CGSize(width: 600, height: 800)
        let image = try renderTextPageImage(
            [("CONFIDENTIAL", CGPoint(x: 30, y: 400), 64)], size: size)
        let (doc, url) = try await makeImagePDF(image, size: size)
        defer { try? FileManager.default.removeItem(at: url) }

        let region = manualRegion(CGRect(x: 0.02, y: 0.42, width: 0.95, height: 0.2))
        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .ocrCheck, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [0: [region]], sensitiveTerms: [],
            pipelineMode: .searchableRedaction,
            filterDigests: [], perPageModes: [.searchableRedaction])
        // The Searchable branch keeps the existing WARN (a glyph layer
        // legitimately survives behind a Searchable fill). Regression-lock the
        // WARN + in-region wording (the grammar was updated; wording only).
        #expect(result.status.isWarn,
                "Searchable in-region text stays WARN; got \(result.status)")
        if case .warn(let msg) = result.status {
            #expect(msg.contains("OCR detected text within a redacted region"),
                    "Searchable in-region WARN wording must stay in-region-scoped; got \(msg)")
        }
    }

    @Test("Layer 2: sensitive term inside a region → FAIL in Searchable mode too")
    func layer2ScopedOCR_termInRegion_searchable_fails() async throws {
        let size = CGSize(width: 600, height: 800)
        let term = "CONFIDENTIAL"   // synthetic, non-PII
        let image = try renderTextPageImage(
            [(term, CGPoint(x: 30, y: 400), 64)], size: size)
        let (doc, url) = try await makeImagePDF(image, size: size)
        defer { try? FileManager.default.removeItem(at: url) }

        let region = manualRegion(CGRect(x: 0.02, y: 0.42, width: 0.95, height: 0.2))
        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .ocrCheck, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [0: [region]], sensitiveTerms: [term].map { SensitiveTerm(text: $0) },
            pipelineMode: .searchableRedaction,
            filterDigests: [], perPageModes: [.searchableRedaction])
        // The .sensitiveTermInRegion super-priority FAIL is mode-independent (it
        // returns before any mode branch), so a recognized term in a region FAILs
        // in Searchable mode as well as Secure (secure is pinned by
        // layer2ScopedOCR_sensitiveTermInsideRegion_fails).
        #expect(result.status.isFail,
                "term readable inside a region must FAIL in Searchable mode; got \(result.status)")
    }

    @Test("Layer 2: SR faithfully redacted region (no in-region text) → PASS")
    func layer2ScopedOCR_noSurvivor_secure_passes() async throws {
        let size = CGSize(width: 600, height: 800)
        // A blank (white) page models a faithfully destroyed region: the OCR pass
        // reads no text at all, so neither the in-region FAIL nor the out-of-region
        // INFO note fires → PASS. Locks that the Layer 2 verdicts do not over-block
        // a correctly redacted Secure-Rasterization output.
        let image = try renderTextPageImage([], size: size)
        let (doc, url) = try await makeImagePDF(image, size: size)
        defer { try? FileManager.default.removeItem(at: url) }

        let region = manualRegion(CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .ocrCheck, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [0: [region]], sensitiveTerms: [],
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization])
        #expect(result.status == .pass,
                "no in-region or out-of-region text → PASS (no over-block); got \(result.status)")
    }

    @Test("Layer 2: fallback-rasterized page in a Searchable-mode run — in-region text → FAIL")
    func layer2ScopedOCR_mixedMode_fallbackPageFails() async throws {
        let size = CGSize(width: 600, height: 800)
        // Page 1: clean. Page 2: readable text inside its region — and page 2
        // was fallback-rasterized (perPageModes), so its region is a
        // destroyed-pixel box that holds no readable text by construction.
        let clean = try renderTextPageImage([], size: size)
        let leaky = try renderTextPageImage(
            [("CONFIDENTIAL", CGPoint(x: 30, y: 400), 64)], size: size)
        let (doc, url) = try await makeImagePDF(pages: [clean, leaky], size: size)
        defer { try? FileManager.default.removeItem(at: url) }

        let region = manualRegion(CGRect(x: 0.02, y: 0.42, width: 0.95, height: 0.2))
        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .ocrCheck, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 2, regions: [1: [region]], sensitiveTerms: [],
            pipelineMode: .searchableRedaction,
            filterDigests: [],
            perPageModes: [.searchableRedaction, .secureRasterization])
        // Before the per-page fold, the document-level Searchable mode demoted
        // this to the glyph-layer WARN — a real leak reported at the wrong tier
        // (Layer 2 is the only layer that inspects a fallback page's pixels).
        #expect(result.status.isFail,
                "in-region text on a fallback-rasterized page must FAIL; got \(result.status)")
        if case .fail(let msg) = result.status {
            #expect(msg.contains("2"), "FAIL must name the fallback page; got \(msg)")
        }
    }

    @Test("Layer 2: same fixture, all pages Searchable → WARN (existing tier pinned)")
    func layer2ScopedOCR_mixedModeFixture_allSearchable_warns() async throws {
        let size = CGSize(width: 600, height: 800)
        let clean = try renderTextPageImage([], size: size)
        let leaky = try renderTextPageImage(
            [("CONFIDENTIAL", CGPoint(x: 30, y: 400), 64)], size: size)
        let (doc, url) = try await makeImagePDF(pages: [clean, leaky], size: size)
        defer { try? FileManager.default.removeItem(at: url) }

        let region = manualRegion(CGRect(x: 0.02, y: 0.42, width: 0.95, height: 0.2))
        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .ocrCheck, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 2, regions: [1: [region]], sensitiveTerms: [],
            pipelineMode: .searchableRedaction,
            filterDigests: [],
            perPageModes: [.searchableRedaction, .searchableRedaction])
        // A genuinely Searchable page keeps a glyph layer behind the fill, so a
        // non-term in-region hit stays the existing WARN tier.
        #expect(result.status.isWarn,
                "in-region text on a Searchable page stays WARN; got \(result.status)")
    }

    @Test("Layer 2: OCR error on one page → unchecked WARN, sibling page still clean")
    func layer2ScopedOCR_performError_foldsToUnchecked() async throws {
        // The Vision perform error cannot be produced deterministically from a
        // fixture, so the guard seam flags THIS test's page-1 image only. The
        // page sizes are sentinels no other fixture uses, so a concurrently
        // running test can never match the predicate.
        let errorSize = CGSize(width: 597, height: 800)
        let cleanSize = CGSize(width: 598, height: 800)
        let errorPage = try renderTextPageImage([], size: errorSize)
        let cleanPage = try renderTextPageImage([], size: cleanSize)
        let (doc, url) = try await makeImagePDF(
            pages: [errorPage, cleanPage], size: errorSize)
        defer { try? FileManager.default.removeItem(at: url) }

        let region = manualRegion(CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        let engine = VerificationEngine()
        // The seam is task-local: bound for this run's task tree only.
        let result = await VerificationEngine.$onLayer2OCRSimulateError.withValue({ $0.width == 597 }) {
            await engine.runLayer(
                .ocrCheck, outputDocument: SendablePDFDocument(doc),
                sourcePageCount: 2, regions: [0: [region], 1: [region]],
                sensitiveTerms: [], pipelineMode: .secureRasterization,
                filterDigests: [],
                perPageModes: [.secureRasterization, .secureRasterization])
        }
        // "Could not check" must not read as "checked, found nothing": the
        // errored page folds to the unchecked WARN instead of a clean PASS,
        // while the sibling page classifies normally (nothing above the
        // unchecked arm fires).
        #expect(result.status.isWarn,
                "an OCR error page must WARN, never contribute to PASS; got \(result.status)")
        if case .warn(let msg) = result.status {
            #expect(msg.contains("OCR could not be run on 1 page"),
                    "errored page folds to the unchecked arm; got \(msg)")
            #expect(result.couldNotVerify, "OCR could not be run: the check did not fully run")
        }
    }

    @Test("Layer 2: SR page, region clean, term readable elsewhere → ATTENTION naming the term for the results row")
    func layer2ScopedOCR_termOutsideRegion_secure_raisesAttention() async throws {
        let size = CGSize(width: 600, height: 800)
        let term = "CONFIDENTIAL"   // synthetic, non-PII
        // Term at the top of the page; the region (bottom-right) is faithfully
        // blank — a redacted term surviving outside every region on a
        // rasterized page is ATTENTION: the redaction is intact but an
        // un-redacted occurrence of the term survives, and on a rasterized
        // page this layer is the only one that can see it. The message is
        // byte-exact and never echoes the term; the term rides
        // `reviewTermTexts` for the results row. In-region survivors still
        // FAIL (pins above).
        let image = try renderTextPageImage(
            [(term, CGPoint(x: 30, y: 680), 64)], size: size)
        let (doc, url) = try await makeImagePDF(image, size: size)
        defer { try? FileManager.default.removeItem(at: url) }

        let region = manualRegion(CGRect(x: 0.6, y: 0.05, width: 0.3, height: 0.2))
        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .ocrCheck, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [0: [region]], sensitiveTerms: [term].map { SensitiveTerm(text: $0) },
            pipelineMode: .secureRasterization,
            filterDigests: [], perPageModes: [.secureRasterization])
        #expect(result.status.isAttention,
                "a term readable outside every region on an SR page raises ATTENTION; got \(result.status)")
        if case .attention(let msg) = result.status {
            #expect(msg == "Text matching your redactions is still readable on page 1 — read by OCR outside every redacted region",
                    "the attention message must render byte-exact; got \(msg)")
            #expect(!msg.localizedCaseInsensitiveContains(term),
                    "the message must never echo the matched term")
        }
        #expect(result.pageReferences == [0])
        #expect(result.reviewTermTexts == [term],
                "the matched term rides reviewTermTexts for the results row; got \(String(describing: result.reviewTermTexts))")
    }

    @Test("Layer 2: Searchable page, term readable outside regions → ATTENTION too (same tier as L3/L10; the masthead dedups the name)")
    func layer2ScopedOCR_termOutsideRegion_searchable_raisesAttention() async throws {
        let size = CGSize(width: 600, height: 800)
        let term = "CONFIDENTIAL"   // synthetic, non-PII
        let image = try renderTextPageImage(
            [(term, CGPoint(x: 30, y: 680), 64)], size: size)
        let (doc, url) = try await makeImagePDF(image, size: size)
        defer { try? FileManager.default.removeItem(at: url) }

        let region = manualRegion(CGRect(x: 0.6, y: 0.05, width: 0.3, height: 0.2))
        let engine = VerificationEngine()
        let result = await engine.runLayer(
            .ocrCheck, outputDocument: SendablePDFDocument(doc),
            sourcePageCount: 1, regions: [0: [region]], sensitiveTerms: [term].map { SensitiveTerm(text: $0) },
            pipelineMode: .searchableRedaction,
            filterDigests: [], perPageModes: [.searchableRedaction])
        // On a Searchable page Layers 3/10 read the same text from the text
        // layer; the pixel-side signal reports the same tier so the layer's
        // verdict does not depend on the page's mode, and the results
        // masthead names the text once across layers.
        #expect(result.status.isAttention,
                "Searchable out-of-region term raises ATTENTION; got \(result.status)")
        if case .attention(let msg) = result.status {
            #expect(msg == "Text matching your redactions is still readable on page 1 — read by OCR outside every redacted region")
            #expect(!msg.localizedCaseInsensitiveContains(term))
        }
        #expect(result.pageReferences == [0])
        #expect(result.reviewTermTexts == [term])
    }
}
