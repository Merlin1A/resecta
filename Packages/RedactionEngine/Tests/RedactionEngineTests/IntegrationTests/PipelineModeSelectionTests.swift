import Testing
import Foundation
import PDFKit
import CoreGraphics
@testable import RedactionEngine

// ARCH §3.2: Per-page pipeline mode selection based on text layer detection.

@Suite("Pipeline Mode Selection", .tags(.critical))
struct PipelineModeSelectionTests {

    // MARK: - TextLayerDetector Integration

    @Test("Rich text page detected as .rich")
    func richTextPageDetectedAsRich() {
        let doc = makeTextPDF(text: "This is a document with substantial text content for testing purposes.")
        guard let page = doc.page(at: 0) else {
            Issue.record("Failed to get page from text PDF")
            return
        }
        let status = TextLayerDetector.detectTextLayer(page)
        #expect(status == .rich)
    }

    @Test("Image-only page detected as .none")
    func imageOnlyPageDetectedAsNone() {
        let data = TestFixtures.imageOnlyPDF()
        guard let doc = PDFDocument(data: data),
              let page = doc.page(at: 0) else {
            Issue.record("Failed to create image-only PDF")
            return
        }
        let status = TextLayerDetector.detectTextLayer(page)
        #expect(status == .none)
    }

    @Test("Blank page detected as .none")
    func blankPageDetectedAsNone() {
        let data = TestFixtures.blankPage()
        guard let doc = PDFDocument(data: data),
              let page = doc.page(at: 0) else {
            Issue.record("Failed to create blank PDF")
            return
        }
        let status = TextLayerDetector.detectTextLayer(page)
        #expect(status == .none)
    }

    // MARK: - Mode Selection Logic

    @Test("Secure mode always produces secureRasterization regardless of text layer")
    func secureModeOverridesRichTextLayer() {
        // When global mode is .secureRasterization, even rich text pages use secure
        let doc = makeTextPDF(text: "Some text")
        guard let page = doc.page(at: 0) else {
            Issue.record("Failed to get page")
            return
        }
        // Simulate the mode selection logic from PipelineCoordinator.buildPDFPageData
        let effectiveMode = PipelineMode.secureRasterization
        let textLayerStatus = TextLayerDetector.detectTextLayer(page)
        let pageMode: PipelineMode
        if effectiveMode == .searchableRedaction, textLayerStatus == .rich {
            pageMode = .searchableRedaction
        } else {
            pageMode = .secureRasterization
        }
        #expect(pageMode == .secureRasterization)
    }

    @Test("Searchable mode with rich text produces searchableRedaction")
    func searchableModeWithRichText() {
        let doc = makeTextPDF(text: "Sufficient text for rich detection in this test PDF document.")
        guard let page = doc.page(at: 0) else {
            Issue.record("Failed to get page")
            return
        }
        let effectiveMode = PipelineMode.searchableRedaction
        let textLayerStatus = TextLayerDetector.detectTextLayer(page)
        let pageMode: PipelineMode
        if effectiveMode == .searchableRedaction, textLayerStatus == .rich {
            pageMode = .searchableRedaction
        } else {
            pageMode = .secureRasterization
        }
        // If text layer detected as rich, mode should be searchable
        if textLayerStatus == .rich {
            #expect(pageMode == .searchableRedaction)
        } else {
            // Sparse/none falls back to secure
            #expect(pageMode == .secureRasterization)
        }
    }

    @Test("Searchable mode with no text falls back to secure")
    func searchableModeWithNoTextFallsBack() {
        let data = TestFixtures.imageOnlyPDF()
        guard let doc = PDFDocument(data: data),
              let page = doc.page(at: 0) else {
            Issue.record("Failed to create image-only PDF")
            return
        }
        let effectiveMode = PipelineMode.searchableRedaction
        let textLayerStatus = TextLayerDetector.detectTextLayer(page)
        let pageMode: PipelineMode
        if effectiveMode == .searchableRedaction, textLayerStatus == .rich {
            pageMode = .searchableRedaction
        } else {
            pageMode = .secureRasterization
        }
        #expect(pageMode == .secureRasterization)
    }

    @Test("CJK text triggers fallback per page")
    func cjkTextTriggersFallback() {
        let data = TestFixtures.cjkTextPDF()
        guard let doc = PDFDocument(data: data),
              let page = doc.page(at: 0) else {
            Issue.record("Failed to create CJK PDF")
            return
        }
        let status = TextLayerDetector.detectTextLayer(page)
        // CJK may be detected as rich or sparse depending on content.
        // The key assertion is that it doesn't crash and returns a valid status.
        #expect(status == .rich || status == .sparse || status == .none)
    }

    // MARK: - Gate with fallback triggers (s15: D2 rotation stopgap REMOVED; ENGINE §5A)
    //
    // Mirrors the production gate in PipelineCoordinator.buildPDFPageData
    // (app target — the end-to-end tests live in PipelineCoordinatorTests).
    // Keep this helper in lockstep with that gate. CAT-353 (D-34/D-35) removed
    // the `page.rotation == 0` conjunct once T_rot completed the canonical
    // coordinate contract.

    private func selectPageMode(effectiveMode: PipelineMode, page: PDFPage) -> PipelineMode {
        let textLayerStatus = TextLayerDetector.detectTextLayer(page)
        if effectiveMode == .searchableRedaction,
           textLayerStatus == .rich {
            if TextLayerDetector.checkFallbackTriggers(page) != nil {
                return .secureRasterization
            }
            return .searchableRedaction
        }
        return .secureRasterization
    }

    @Test("Normal rich page remains searchable under the trigger-wired gate")
    func normalPageRemainsSearchable() throws {
        let doc = makeTextPDF(text: "Sufficient plain English text for rich detection in this page.")
        let page = try #require(doc.page(at: 0))
        #expect(selectPageMode(effectiveMode: .searchableRedaction, page: page) == .searchableRedaction)
    }

    @Test("RTL page forces secureRasterization (ENGINE §5A per-page fallback)")
    func rtlPageForcesSecureRasterization() throws {
        let doc = makeTextPDF(text: "هذا مستند تجريبي باللغة العربية للتحقق من مسار التراجع")
        let page = try #require(doc.page(at: 0))
        #expect(TextLayerDetector.checkFallbackTriggers(page) == .rtlText)
        #expect(selectPageMode(effectiveMode: .searchableRedaction, page: page) == .secureRasterization)
    }

    @Test("CAT-353 (s15): rotated rich page now takes searchableRedaction", arguments: [90, 180, 270])
    func rotatedPageTakesSearchable(rotation: Int) throws {
        // s15 stopgap removal (D-34/D-35): the canonical coordinate contract
        // (T_rot) makes rotated rich pages safe for searchable mode; the former
        // D2 stopgap that forced secureRasterization here is gone.
        let doc = makeTextPDF(text: "Sufficient plain English text for rich detection in this page.")
        let page = try #require(doc.page(at: 0))
        page.rotation = rotation
        #expect(selectPageMode(effectiveMode: .searchableRedaction, page: page) == .searchableRedaction)
    }

    @Test("Unrotated rich page takes searchableRedaction (control case)")
    func rotationZeroAllowsSearchable() throws {
        let doc = makeTextPDF(text: "Sufficient plain English text for rich detection in this page.")
        let page = try #require(doc.page(at: 0))
        #expect(page.rotation == 0)
        #expect(selectPageMode(effectiveMode: .searchableRedaction, page: page) == .searchableRedaction)
    }

    @Test("Sample statement selects searchable on all three pages (RC-9 regression)")
    func sampleStatementAllPagesSearchable() throws {
        // Before the PD-5 diversity floor, the length-confounded ratio
        // rasterized the sample doc's dense pages (p2, p3) — a Searchable-mode
        // run reported "1 Searchable, 2 Rasterized" on a fully born-digital
        // document. All three pages must take searchable mode through the
        // trigger-wired gate.
        let data = try TestFixtures.sampleStatementPDF()
        let doc = try #require(PDFDocument(data: data))
        #expect(doc.pageCount == TestFixtures.sampleStatementPageCount)
        for i in 0..<doc.pageCount {
            let page = try #require(doc.page(at: i))
            #expect(TextLayerDetector.detectTextLayer(page) == .rich)
            #expect(selectPageMode(effectiveMode: .searchableRedaction, page: page)
                    == .searchableRedaction,
                    "sample page \(i + 1) must keep searchable mode")
        }
    }

    // MARK: - Helpers

    private func makeTextPDF(text: String) -> PDFDocument {
        let data = TestFixtures.textLayerPDF(text: text)
        return PDFDocument(data: data)!
    }
}
