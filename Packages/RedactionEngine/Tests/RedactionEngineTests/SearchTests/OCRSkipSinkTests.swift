import Testing
import PDFKit
#if canImport(UIKit)
import UIKit
#endif
@testable import RedactionEngine

// ST-83 (q13) — the oversized-OCR-skip sink. Pages whose 300-DPI render
// exceeds the OCR pixel caps skip OCR entirely (pre-existing behavior,
// unchanged); the sink now reports the page index so the app layer can
// tell the user that page's image content was never text-scanned.
// Reporting-only: the tests also pin that the skip still yields zero
// results.

@Suite("OCR skip sink (ST-83)", .tags(.search))
struct OCRSkipSinkTests {

    private actor Collector {
        var pages: [Int] = []
        func append(_ page: Int) { pages.append(page) }
        func snapshot() -> [Int] { pages }
    }

    /// A PDF whose single page renders far over the OCR pixel caps at
    /// 300 DPI: 2600 pt × (300/72) ≈ 10 833 px per axis, past the
    /// 10 000 px per-axis cap. No text is drawn — image-only page.
    private func oversizedImageOnlyPDF() -> PDFDocument? {
        let pageRect = CGRect(x: 0, y: 0, width: 2600, height: 2600)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let data = renderer.pdfData { context in
            context.beginPage()
        }
        return PDFDocument(data: data)
    }

    @Test("Oversized page fires the OCR-skip sink and still yields no results")
    func oversizedPageFiresSink() async throws {
        guard let doc = oversizedImageOnlyPDF() else {
            Issue.record("PDFDocument creation failed")
            return
        }

        // `.none` classification routes the page to the OCR path.
        let searcher = DocumentSearcher(textLayerStatusByPage: [0: .none])
        let collector = Collector()
        await searcher.setOCRSkipSink { page in
            Task { await collector.append(page) }
        }

        let stream = searcher.search(
            SendablePDFDocument(doc),
            mode: .text("anything", options: SearchOptions(includeOCR: true)),
            progress: { _, _ in }
        )
        var results: [SearchResult] = []
        for await result in stream { results.append(result) }

        // Drain the async sink Task into the collector.
        try? await Task.sleep(for: .milliseconds(50))
        let observed = await collector.snapshot()
        #expect(observed.contains(0),
                "oversized page must report the OCR skip; observed=\(observed)")
        #expect(results.isEmpty, "the skip behavior itself is unchanged")
    }

    @Test("Nil sink stays safe on the oversized-skip path")
    func nilSinkSafe() async throws {
        guard let doc = oversizedImageOnlyPDF() else {
            Issue.record("PDFDocument creation failed")
            return
        }

        let searcher = DocumentSearcher(textLayerStatusByPage: [0: .none])
        // No setOCRSkipSink call — sink stays nil.
        let stream = searcher.search(
            SendablePDFDocument(doc),
            mode: .text("anything", options: SearchOptions(includeOCR: true)),
            progress: { _, _ in }
        )
        var results: [SearchResult] = []
        for await result in stream { results.append(result) }
        #expect(results.isEmpty)
    }
}
