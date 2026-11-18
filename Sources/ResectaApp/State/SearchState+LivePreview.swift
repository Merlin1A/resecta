import Foundation
import RedactionEngine

extension SearchState {
    // MARK: - Live Preview

    /// Debounce + run a live-preview pass. Each call cancels the
    /// previous task; only the last result is published. Independent
    /// from the sheet's existing 300 ms full-search debounce.
    func scheduleLivePreview(
        searcher: DocumentSearcher,
        currentPageIndex: Int,
        totalPageCount: Int,
        pageTextProvider: @Sendable @escaping (Int) async -> String?,
        // Match the full-search debounce (300 ms, see `debounceSearch`)
        // so the preview does not issue an extra off-main page.string read ahead
        // of every keystroke; a still-typing user then produces no preview walk
        // at all.
        debounce: Duration = .milliseconds(300)
    ) {
        livePreviewTask?.cancel()

        // Build the engine SearchMode from the same conversion the sheet
        // uses for the full search. Don't preview piiScan.
        let mode: SearchMode
        switch searchModeType {
        case .text:
            guard !queryText.isEmpty else { clearLivePreview(); return }
            mode = .text(queryText, options: options)
        case .regex:
            guard !queryText.isEmpty else { clearLivePreview(); return }
            mode = .regex(queryText, options: options)
        case .multiTerm:
            guard !searchTerms.isEmpty else { clearLivePreview(); return }
            mode = .multiTerm(searchTerms, options: options)
        case .piiScan:
            clearLivePreview(); return
        }

        // The live preview only renders the visible page's highlight
        // rects; the whole-document total is owned by the full search that the
        // same keystroke kicks off. Always scope the preview to the current page
        // so it stops re-walking every page's `page.string` off-main against the
        // freshly-copied PDFDocument (the previewDoc copy).
        let scope: SearchPreviewScope = .currentPage(pageIndex: currentPageIndex)

        livePreviewTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            if Task.isCancelled { return }
            let result = await searcher.previewMatches(
                mode: mode,
                scope: scope,
                currentPageIndex: currentPageIndex,
                totalPageCount: totalPageCount,
                pageTextProvider: pageTextProvider
            )
            if Task.isCancelled { return }
            // The enclosing Task is MainActor-isolated
            // (SearchState is @MainActor by SE-0466 default and the Task
            // closure inherits the surrounding isolation), and
            // `searcher.previewMatches` returns to MainActor after the
            // actor hop. A second `await MainActor.run` was a redundant
            // re-hop — dropped. The `guard let self` mirrors the
            // original closure's weak-self contract.
            guard let self else { return }
            self.livePreview = result
            // Rects are filled by the caller after this returns; clear
            // any stale rects from a previous query in the meantime.
            self.livePreviewRects = []
        }
    }

    /// Caller-supplied resolved rects (normalized 0–1 PDF coords) for
    /// the visible page. The view layer does the NSRange→CGRect conversion
    /// because the engine has no PDFPage context.
    func setLivePreviewRects(_ rects: [CGRect]) {
        livePreviewRects = rects
        resultVersion += 1
    }

    /// Cancel any in-flight preview and clear the published state.
    func clearLivePreview() {
        livePreviewTask?.cancel()
        livePreviewTask = nil
        let hadPreview = (livePreview != nil) || !livePreviewRects.isEmpty
        livePreview = nil
        livePreviewRects = []
        if hadPreview { resultVersion += 1 }
    }
}
