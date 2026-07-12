import Testing
import PDFKit
#if canImport(UIKit)
import UIKit
#endif
@testable import RedactionEngine

// CAT-167 / D-27a — DocumentSearcher must not let a thin (`.sparse`) or
// image-only (`.none`) text layer suppress OCR. When a page carries a
// header-only text layer over a scanned body, the four search paths
// (text / regex / multi-term / PII) route to OCR instead of running the
// text-layer fast path against the (incomplete) embedded text.
//
// The per-page classification arrives via the `textLayerStatusByPage` init
// parameter (dossier Option A); production installs it from
// `documentState.textLayerStatus` through `setTextLayerStatus(_:)`. These tests
// use the `_testSeedOCRLines` seam to inject deterministic OCR output, so no
// real Vision OCR runs on the simulator.
//
// Privacy rule (audit-lint M-1): test names use locate/route/resolve
// vocabulary. No outcome-promise language in comments or display names.

@Suite("DocumentSearcher thin text-layer routing (CAT-167)", .tags(.search))
struct DocumentSearcherThinLayerTests {

    private func stubLine(
        _ text: String,
        rect: CGRect = CGRect(x: 0.1, y: 0.5, width: 0.6, height: 0.05),
        confidence: Float = 0.9
    ) -> OCREngine.TextLine {
        OCREngine.TextLine(text: text, normalizedRect: rect, confidence: confidence)
    }

    // MARK: - Routing (red → green)

    @Test("Sparse text layer routes the search to the OCR path")
    func testThinLayerTakesOCRPath() async {
        // The page has a non-empty header-only text layer that does NOT contain
        // the query; the query lives only in the (seeded) OCR output. With the
        // page classified `.sparse`, the search consults OCR and locates it.
        // Pre-CAT-167 the non-empty `page.string` took the text-layer path
        // exclusively → zero results (the red state).
        let data = TestFixtures.textLayerPDF(text: "Header")
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return
        }

        let searcher = DocumentSearcher(textLayerStatusByPage: [0: .sparse])
        await searcher._testSeedOCRLines(
            [stubLine("CONFIDENTIAL body text")], forPageIndex: 0
        )

        let stream = searcher.search(
            SendablePDFDocument(doc),
            mode: .text("CONFIDENTIAL", options: SearchOptions(includeOCR: true)),
            progress: { _, _ in }
        )

        var results: [SearchResult] = []
        for await result in stream { results.append(result) }

        #expect(results.count == 1)
        if case .ocr = results.first?.source {
            // expected — the match came from OCR, not the thin text layer
        } else {
            Issue.record(
                "Expected source == .ocr; got \(String(describing: results.first?.source))"
            )
        }
    }

    @Test("Rich text layer keeps the text-layer fast path")
    func testRichLayerUsesTextPath() async {
        // A `.rich` page whose embedded text contains the query resolves via the
        // text layer — not OCR. The OCR cache is seeded with a decoy that does
        // NOT contain the query, so an erroneous OCR route would yield zero
        // results; the text-layer route yields one with `.textLayer` source.
        let data = TestFixtures.textLayerPDF(text: "Contains CONFIDENTIAL here")
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return
        }

        let searcher = DocumentSearcher(textLayerStatusByPage: [0: .rich])
        await searcher._testSeedOCRLines(
            [stubLine("unrelated decoy")], forPageIndex: 0
        )

        let stream = searcher.search(
            SendablePDFDocument(doc),
            mode: .text("CONFIDENTIAL", options: SearchOptions(includeOCR: true)),
            progress: { _, _ in }
        )

        var results: [SearchResult] = []
        for await result in stream { results.append(result) }

        #expect(results.count == 1)
        #expect(results.first?.source == .textLayer)
    }

    @Test("Unknown-status page preserves pre-CAT-167 behavior")
    func testUnknownStatusUsesTextPath() async {
        // Backward-compat: a searcher constructed without status (default `[:]`)
        // treats every non-empty page as `.rich`, so callers that don't supply
        // status — including every pre-CAT-167 test — see no behavior change.
        let data = TestFixtures.textLayerPDF(text: "Contains CONFIDENTIAL here")
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return
        }

        let searcher = DocumentSearcher()  // no status supplied
        await searcher._testSeedOCRLines(
            [stubLine("unrelated decoy")], forPageIndex: 0
        )

        let stream = searcher.search(
            SendablePDFDocument(doc),
            mode: .text("CONFIDENTIAL", options: SearchOptions(includeOCR: true)),
            progress: { _, _ in }
        )

        var results: [SearchResult] = []
        for await result in stream { results.append(result) }

        #expect(results.count == 1)
        #expect(results.first?.source == .textLayer)
    }

    // MARK: - "Scanned region not analyzed" signal

    @Test("Scanned region with OCR off fires the not-analyzed signal")
    func testScannedRegionSignalFiresWhenOCRDisabled() async {
        // A `.sparse` page with `includeOCR == false` is neither text-analyzed
        // (not rich) nor OCR-analyzed (OCR off). The engine fires the
        // "scanned region not analyzed" sink so the app can surface the signal,
        // and yields no results.
        let data = TestFixtures.textLayerPDF(text: "Header")
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return
        }

        let searcher = DocumentSearcher(textLayerStatusByPage: [0: .sparse])
        let collector = ScannedRegionCollector()
        await searcher.setScannedRegionNotAnalyzedSink { page in
            Task { await collector.append(page) }
        }

        let stream = searcher.search(
            SendablePDFDocument(doc),
            mode: .text("CONFIDENTIAL", options: SearchOptions(includeOCR: false)),
            progress: { _, _ in }
        )

        var results: [SearchResult] = []
        for await result in stream { results.append(result) }

        // Drain the async sink.
        try? await Task.sleep(for: .milliseconds(50))

        #expect(results.isEmpty)
        let pages = await collector.snapshot()
        #expect(pages == [0])
    }

    @Test("Rich page does not fire the not-analyzed signal")
    func testRichPageDoesNotFireSignal() async {
        // Inverse guard: a `.rich` page never trips the signal, even with OCR
        // off — its text layer is analyzed.
        let data = TestFixtures.textLayerPDF(text: "Contains CONFIDENTIAL here")
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return
        }

        let searcher = DocumentSearcher(textLayerStatusByPage: [0: .rich])
        let collector = ScannedRegionCollector()
        await searcher.setScannedRegionNotAnalyzedSink { page in
            Task { await collector.append(page) }
        }

        let stream = searcher.search(
            SendablePDFDocument(doc),
            mode: .text("CONFIDENTIAL", options: SearchOptions(includeOCR: false)),
            progress: { _, _ in }
        )

        var results: [SearchResult] = []
        for await result in stream { results.append(result) }
        try? await Task.sleep(for: .milliseconds(50))

        #expect(results.count == 1)
        let pages = await collector.snapshot()
        #expect(pages.isEmpty)
    }
}

/// Thread-safe collector for the scanned-region sink callbacks.
private actor ScannedRegionCollector {
    private var pages: [Int] = []
    func append(_ page: Int) { pages.append(page) }
    func snapshot() -> [Int] { pages }
}
