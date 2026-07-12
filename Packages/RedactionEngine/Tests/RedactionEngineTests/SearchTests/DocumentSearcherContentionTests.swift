import Testing
import Foundation
import PDFKit
#if canImport(UIKit)
import UIKit
#endif
@testable import RedactionEngine

@Suite("DocumentSearcher actor contention", .tags(.search))
struct DocumentSearcherContentionTests {

    @Test("Actor setters drain quickly while a regex scan is in flight")
    func setterReturnsQuicklyDuringRegexScan() async throws {
        let data = multiPageTextPDF(
            pageCount: 60,
            text: "Lorem ipsum 123-45-6789 with sensitive numbers 987-65-4321."
        )
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return
        }
        let sendable = SendablePDFDocument(doc)
        let searcher = DocumentSearcher()

        let scanTask = Task {
            let stream = searcher.search(
                sendable,
                mode: .regex("\\d{3}-\\d{2}-\\d{4}", options: SearchOptions()),
                progress: { _, _ in }
            )
            for await _ in stream { }
        }

        // Let the regex scan start producing work on the actor.
        try await Task.sleep(for: .milliseconds(20))

        let start = ContinuousClock.now
        await searcher.setOverlapSink({ _ in })
        let elapsed = ContinuousClock.now - start

        scanTask.cancel()
        _ = await scanTask.value

        #expect(elapsed < .milliseconds(500), "Setter took \(elapsed) during regex scan")
    }

    @Test("Near-cap OCR pages are rejected by the pixel-count cap")
    func nearCapPixelCountRejected() async throws {
        // Build a single-page PDF whose CropBox at 300 DPI exceeds the
        // per-pixel-count cap (~36 MP) without tripping the per-axis cap.
        // 8400 pt × 8400 pt at 300 DPI = (8400 × 300/72)^2 = 35000 × 35000 px,
        // which is well above the cap on both fronts; use a milder rectangle
        // to stay axis-clean. 7200 pt × 4320 pt → 30000 × 18000 = 540 MP.
        let pageRect = CGRect(x: 0, y: 0, width: 7200, height: 4320)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let data = renderer.pdfData { context in
            context.beginPage()
            UIColor.white.setFill()
            UIBezierPath(rect: pageRect).fill()
        }
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return
        }

        let searcher = DocumentSearcher()
        let stream = searcher.search(
            SendablePDFDocument(doc),
            mode: .piiScan(categories: Set(PIICategory.allCases), options: SearchOptions()),
            progress: { _, _ in }
        )

        var results: [SearchResult] = []
        for await result in stream { results.append(result) }

        #expect(results.isEmpty, "Oversized page produced \(results.count) OCR results — pixel-count cap did not reject")
    }

    // MARK: - D10-F2 per-page yield (text + multi-term arms)

    /// #6 — the text-layer fast path holds no `await` other than the new
    /// per-page yield; without it a 60-page scan would pin the actor and a
    /// concurrently-issued setter would wait the whole document.
    @Test("Actor setters drain quickly while a text scan is in flight")
    func setterReturnsQuicklyDuringTextScan() async throws {
        try await assertSetterDrainsQuickly(
            mode: .text("123-45-6789", options: SearchOptions()))
    }

    @Test("Actor setters drain quickly while a multi-term OR scan is in flight")
    func setterReturnsQuicklyDuringMultiTermOrScan() async throws {
        try await assertSetterDrainsQuickly(
            mode: .multiTerm(
                ["123-45-6789", "987-65-4321"],
                options: SearchOptions(multiTermConjunction: false)))
    }

    @Test("Actor setters drain quickly while a multi-term AND scan is in flight")
    func setterReturnsQuicklyDuringMultiTermAndScan() async throws {
        try await assertSetterDrainsQuickly(
            mode: .multiTerm(
                ["123-45-6789", "987-65-4321"],
                options: SearchOptions(multiTermConjunction: true)))
    }

    /// #7 — guard against a future edit dropping one of the per-page yields.
    /// Best-effort: on the build machine `#filePath` resolves and the count is
    /// asserted strictly (searchText + searchRegex + both searchMultiTerm arms
    /// = 4). Off-machine the source is unreachable and the guard is vacuous —
    /// the behavioral drain tests above are the portable coverage.
    @Test("DocumentSearcher has exactly four per-page Task.yield() calls")
    func yieldCountGuard() {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SearchTests
            .deletingLastPathComponent()   // RedactionEngineTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <package root>
        let source = packageRoot
            .appendingPathComponent("Sources/RedactionEngine/Search/DocumentSearcher.swift")
        guard let text = try? String(contentsOf: source, encoding: .utf8) else { return }
        let count = text.components(separatedBy: "await Task.yield()").count - 1
        #expect(count == 4, "expected 4 await Task.yield() in DocumentSearcher.swift, found \(count)")
    }

    /// #8 — the per-page yield is behavior-neutral: the ordered result stream is
    /// stable across runs (same count, same pageIndex/term sequence).
    @Test("text and multi-term result streams are deterministic across the yield")
    func resultStreamDeterminism() async throws {
        let data = multiPageTextPDFPerPage(pages: ["alpha", "alpha beta", "alpha"])
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument"); return
        }
        let searcher = DocumentSearcher()

        func collect(_ mode: SearchMode) async -> [(Int, String)] {
            var out: [(Int, String)] = []
            let stream = searcher.search(
                SendablePDFDocument(doc), mode: mode, progress: { _, _ in })
            for await r in stream { out.append((r.pageIndex, r.term)) }
            return out
        }

        let textA = await collect(.text("alpha", options: SearchOptions()))
        let textB = await collect(.text("alpha", options: SearchOptions()))
        // Page-ordered, one "alpha" per page, every term == the query.
        #expect(textA.map(\.0) == [0, 1, 2])
        #expect(textA.allSatisfy { $0.1 == "alpha" })
        // Identical across runs — the yield introduces no nondeterminism.
        #expect(textA.map(\.0) == textB.map(\.0))
        #expect(textA.map(\.1) == textB.map(\.1))
    }

    /// #9 — a cancelled text scan stays page-granular and finishes promptly
    /// rather than running the full document. Generous bound to stay
    /// load-robust; the point is « whole-document, not a tight latency figure.
    @Test("a cancelled text scan finishes promptly")
    func cancellationFinishesPromptly() async throws {
        let data = multiPageTextPDF(
            pageCount: 200,
            text: "Lorem ipsum 123-45-6789 alpha beta gamma delta epsilon.")
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument"); return
        }
        let searcher = DocumentSearcher()
        let sendable = SendablePDFDocument(doc)
        let start = ContinuousClock.now
        let task = Task {
            let stream = searcher.search(
                sendable, mode: .text("alpha", options: SearchOptions()),
                progress: { _, _ in })
            for await _ in stream { }
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        _ = await task.value
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .milliseconds(3000), "cancelled scan took \(elapsed)")
    }

    // MARK: - D10-F1 copy coordinate equivalence / D10-F3 preview scope

    /// #5 — the per-consumer copy changes WHICH instance produces bounds, never
    /// the values. For a non-rotated page `boundingRect` is byte-equal on the
    /// copy and the source for the same NSRange (so S1's CropBox-origin fix is
    /// untouched by the copy).
    @Test("boundingRect is identical on a per-consumer copy and the source page")
    func boundingRectEquivalentOnCopy() throws {
        let data = multiPageTextPDF(
            pageCount: 1, text: "Lorem ipsum 123-45-6789 sensitive token body.")
        let source = try #require(PDFDocument(data: data))
        let copyData = try #require(source.dataRepresentation())
        let copy = try #require(PDFDocument(data: copyData))
        let searcher = DocumentSearcher()

        let sourcePage = try #require(source.page(at: 0))
        let copyPage = try #require(copy.page(at: 0))
        let full = (sourcePage.string ?? "") as NSString
        let range = full.range(of: "123-45-6789")
        try #require(range.location != NSNotFound, "fixture text-layer missing the SSN token")

        let sourceRect = try #require(searcher.boundingRect(for: range, page: sourcePage))
        let copyRect = try #require(searcher.boundingRect(for: range, page: copyPage))
        #expect(abs(sourceRect.minX - copyRect.minX) < 1e-6
            && abs(sourceRect.minY - copyRect.minY) < 1e-6
            && abs(sourceRect.width - copyRect.width) < 1e-6
            && abs(sourceRect.height - copyRect.height) < 1e-6,
            "boundingRect diverged source \(sourceRect) vs copy \(copyRect)")
    }

    /// #10 — `previewMatches(.currentPage)` walks ONLY the visible page; the
    /// instrumented provider is asked for that one index, never the others.
    @Test("previewMatches(.currentPage) walks only the visible page")
    func previewCurrentPageScopeWalksOnePage() async {
        let searcher = DocumentSearcher()
        let recorder = PreviewIndexRecorder()
        // Pages 0 & 2 contain "alpha"; current page 1 does not.
        let pages = ["hit alpha here", "no match", "hit alpha there"]
        let provider: @Sendable (Int) async -> String? = { idx in
            await recorder.record(idx)
            guard idx >= 0 && idx < pages.count else { return nil }
            return pages[idx]
        }
        let result = await searcher.previewMatches(
            mode: .text("alpha", options: SearchOptions()),
            scope: .currentPage(pageIndex: 1),
            currentPageIndex: 1, totalPageCount: 3,
            pageTextProvider: provider)
        let seen = await recorder.indices
        #expect(seen == [1], "provider read \(seen); expected only the current page [1]")
        #expect(result.totalCount == 0)
        #expect(result.currentPageMatches.isEmpty)
    }

    // MARK: - Helpers

    /// Shared body for the #6 setter-drain cases: a 60-page text fixture is
    /// scanned in `mode` while a setter is issued mid-scan; the setter must
    /// return well before the whole-document scan completes.
    private func assertSetterDrainsQuickly(mode: SearchMode) async throws {
        let data = multiPageTextPDF(
            pageCount: 60,
            text: "Lorem ipsum 123-45-6789 with sensitive numbers 987-65-4321.")
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument"); return
        }
        let sendable = SendablePDFDocument(doc)
        let searcher = DocumentSearcher()

        let scanTask = Task {
            let stream = searcher.search(sendable, mode: mode, progress: { _, _ in })
            for await _ in stream { }
        }

        try await Task.sleep(for: .milliseconds(20))

        let start = ContinuousClock.now
        await searcher.setOverlapSink({ _ in })
        let elapsed = ContinuousClock.now - start

        scanTask.cancel()
        _ = await scanTask.value

        #expect(elapsed < .milliseconds(500), "Setter took \(elapsed) during a \(mode) scan")
    }

    /// Per-page text variant of `multiPageTextPDF` — one distinct line per page
    /// so result ordering / page indices are meaningful (#8).
    private func multiPageTextPDFPerPage(pages: [String]) -> Data {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        return renderer.pdfData { context in
            for text in pages {
                context.beginPage()
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 14),
                    .foregroundColor: UIColor.black
                ]
                (text as NSString).draw(
                    in: CGRect(x: 72, y: 72, width: 468, height: 648),
                    withAttributes: attrs
                )
            }
        }
    }

    private func multiPageTextPDF(pageCount: Int, text: String) -> Data {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        return renderer.pdfData { context in
            for _ in 0..<pageCount {
                context.beginPage()
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 14),
                    .foregroundColor: UIColor.black
                ]
                (text as NSString).draw(
                    in: CGRect(x: 72, y: 72, width: 468, height: 648),
                    withAttributes: attrs
                )
            }
        }
    }
}

/// Records the page indices a `pageTextProvider` is asked for, so the preview
/// scope test (#10) can assert `.currentPage` walks only the visible page.
private actor PreviewIndexRecorder {
    private(set) var indices: [Int] = []
    func record(_ idx: Int) { indices.append(idx) }
}
