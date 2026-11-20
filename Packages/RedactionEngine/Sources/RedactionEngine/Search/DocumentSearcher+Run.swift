import Foundation
import PDFKit

// Moved whole from DocumentSearcher.swift; no line inside a moved body changes.

extension DocumentSearcher {

    // MARK: - Public API

    /// Search the document, yielding results progressively.
    ///
    /// Delivery is complete: the stream buffers without bound, so a page
    /// that bursts more matches than a lagging consumer has drained loses
    /// nothing. The bound on what is in flight is `maxResults` matches,
    /// enforced at every yield site; a match over several lines is one
    /// result per line, so a run can yield more results than that.
    ///
    /// - Parameters:
    ///   - document: The PDF to search (SendablePDFDocument wrapper).
    ///   - mode: Text, regex, or multi-term search.
    ///   - progress: Callback with (currentPage, totalPages).
    /// - Returns: AsyncStream of SearchResult, one per match.
    public nonisolated func search(
        _ document: SendablePDFDocument,
        mode: SearchMode,
        progress: @Sendable @escaping (Int, Int) -> Void
    ) -> AsyncStream<SearchResult> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: SearchResult.self,
            bufferingPolicy: .unbounded
        )

        let searcher = self
        let sendableDoc = document

        // The producer must be cancellable from the consumer side:
        // cancelling/dropping the stream is the caller's only cancel
        // mechanism, and an unstoppable producer keeps scanning every
        // remaining page (OCR included) and fires whichever sinks are
        // installed when it finally reaches them — a later search's,
        // corrupting that scan's suppression counts and banners. The
        // per-page `Task.isCancelled` checks read THIS task's flag, so
        // termination must propagate to it.
        let producer = Task {
            await searcher.performSearch(
                sendableDoc, mode: mode,
                progress: progress, continuation: continuation
            )
        }
        continuation.onTermination = { @Sendable _ in
            producer.cancel()
        }

        return stream
    }

    // MARK: - Text-layer routing

    /// Whether the page's import-time classification permits the
    /// text-layer fast path — the core's predicate over this actor's status
    /// map (`.rich` or unknown stays on the text layer; `.sparse`/`.none`
    /// fall through to OCR). See `SearchCore.textLayerIsSearchable`.
    func pageHasRichTextLayer(_ pageIndex: Int) -> Bool {
        SearchCore.textLayerIsSearchable(textLayerStatusByPage[pageIndex])
    }

    private func performSearch(
        _ document: SendablePDFDocument,
        mode: SearchMode,
        progress: @Sendable (Int, Int) -> Void,
        continuation: AsyncStream<SearchResult>.Continuation
    ) async {
        let doc = document.document
        let pageCount = doc.pageCount

        switch mode {
        case .text(let query, let options):
            await searchText(
                doc: doc, query: query, options: options,
                pageCount: pageCount, progress: progress,
                continuation: continuation
            )
        case .regex(let pattern, let options):
            await searchRegex(
                doc: doc, pattern: pattern, options: options,
                pageCount: pageCount, progress: progress,
                continuation: continuation
            )
        case .multiTerm(let terms, let options):
            await searchMultiTerm(
                doc: doc, terms: terms, options: options,
                pageCount: pageCount, progress: progress,
                continuation: continuation
            )
        case .piiScan(let categories, let options):
            await searchPII(
                doc: doc, categories: categories, options: options,
                pageCount: pageCount, progress: progress,
                continuation: continuation
            )
        }
    }
}
