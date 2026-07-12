import Testing
import PDFKit
@testable import RedactionEngine

// WU-66 / [P2] — verifies the per-page regex-timeout sink fires from BOTH
// the live-preview branch (`previewRegex`) and the full-scan branch
// (`searchRegex`). Tests use the `regexTimeoutOverride` constructor
// parameter to force the timeout in nanoseconds rather than waiting the
// production 5s ceiling. Per-instance avoids the cross-test race a
// shared static would expose.
//
// RR-44: the original `[P2]` proposal swapped the function labels at the
// two cite sites. The `sinkFiresInBothSearchAndPreviewBranches` test is
// the load-bearing pin per DEFINITION_OF_DONE engine-WU section — it
// asserts the sink fires from both branches regardless of label, so a
// future refactor that flips the branches doesn't silently lose one path.

@Suite("Regex timeout sink (WU-66)")
struct RegexTimeoutSinkTests {

    // MARK: - Fixtures

    /// Single-page PDF with enough text for the regex enumerator to start
    /// matching. The actual page content is irrelevant — the test uses a
    /// ~0ns timeout so the very first iteration trips.
    private func singlePageFixture(text: String = String(repeating: "alpha ", count: 200)) -> PDFDocument {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let data = renderer.pdfData { context in
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 12),
                .foregroundColor: UIColor.black
            ]
            context.beginPage()
            (text as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: attrs)
        }
        return PDFDocument(data: data)!
    }

    private func providerFor(_ doc: PDFDocument) -> @Sendable (Int) async -> String? {
        let texts: [String] = (0..<doc.pageCount).map { doc.page(at: $0)?.string ?? "" }
        return { idx in
            guard idx >= 0 && idx < texts.count else { return nil }
            return texts[idx]
        }
    }

    // MARK: - Tests

    @Test("Abusive pattern fires sink once per affected page")
    func firesOncePerAffectedPage() async throws {
        let doc = singlePageFixture()
        let searcher = DocumentSearcher(regexTimeoutOverride: .nanoseconds(1))

        let pages = SinkBox()
        await searcher.setRegexTimeoutSink({ page in
            Task { await pages.append(page) }
        })

        _ = await searcher.previewMatches(
            mode: .regex("alpha", options: SearchOptions()),
            scope: .wholeDocument,
            currentPageIndex: 0,
            totalPageCount: doc.pageCount,
            pageTextProvider: providerFor(doc)
        )

        // Drain the sink Task into the collector.
        try await Task.sleep(for: .milliseconds(50))
        let observed = await pages.snapshot()
        #expect(observed.contains(0), "preview-branch timeout sink must fire for page 0; observed=\(observed)")
    }

    @Test("Nil sink doesn't crash")
    func nilSinkSafe() async throws {
        let doc = singlePageFixture()
        let searcher = DocumentSearcher(regexTimeoutOverride: .nanoseconds(1))

        // Explicitly leave the sink nil; no setRegexTimeoutSink call.
        _ = await searcher.previewMatches(
            mode: .regex("alpha", options: SearchOptions()),
            scope: .wholeDocument,
            currentPageIndex: 0,
            totalPageCount: doc.pageCount,
            pageTextProvider: providerFor(doc)
        )

        // Reaching this line means no crash; explicit assert keeps the
        // test intent visible to readers.
        #expect(Bool(true), "completed without crash with nil sink")
    }

    @Test("Sink fires in both search and preview branches")
    func sinkFiresInBothSearchAndPreviewBranches() async throws {
        // Load-bearing per RR-44 / DEFINITION_OF_DONE engine-WU section.
        // The `[P2]` proposal cite originally swapped the function labels
        // at the two timeout-branch sites; this test asserts both wire
        // the sink regardless of which one is which.

        let doc = singlePageFixture()
        let searcher = DocumentSearcher(regexTimeoutOverride: .nanoseconds(1))

        let pagesPreview = SinkBox()
        await searcher.setRegexTimeoutSink({ page in
            Task { await pagesPreview.append(page) }
        })
        _ = await searcher.previewMatches(
            mode: .regex("alpha", options: SearchOptions()),
            scope: .wholeDocument,
            currentPageIndex: 0,
            totalPageCount: doc.pageCount,
            pageTextProvider: providerFor(doc)
        )

        let pagesSearch = SinkBox()
        await searcher.setRegexTimeoutSink({ page in
            Task { await pagesSearch.append(page) }
        })
        let stream = searcher.search(
            SendablePDFDocument(doc),
            mode: .regex("alpha", options: SearchOptions()),
            progress: { _, _ in }
        )
        for await _ in stream { }

        try await Task.sleep(for: .milliseconds(50))
        let previewObserved = await pagesPreview.snapshot()
        let searchObserved = await pagesSearch.snapshot()
        #expect(previewObserved.contains(0), "preview branch sink fired; observed=\(previewObserved)")
        #expect(searchObserved.contains(0), "search branch sink fired; observed=\(searchObserved)")
    }
}

/// Thread-safe collector for sink callbacks. Each `append` posts to the
/// actor; `snapshot()` returns the current state.
private actor SinkBox {
    private var pages: [Int] = []
    func append(_ page: Int) { pages.append(page) }
    func snapshot() -> [Int] { pages }
}
