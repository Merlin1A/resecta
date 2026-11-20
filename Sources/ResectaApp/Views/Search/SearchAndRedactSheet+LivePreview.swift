import SwiftUI
import RedactionEngine

extension SearchAndRedactSheet {
    // MARK: - Live Preview

    func scheduleLivePreviewIfApplicable() {
        guard let liveDoc = documentState.sourceDocument,
              searchState.searchModeType != .piiScan
        else {
            searchState.clearLivePreview()
            return
        }
        // The preview text-walk reads a private copy off the live
        // instance; the rect resolution (resolveAndPublishLivePreviewRects)
        // stays on the LIVE page on MainActor. A nil copy ⇒ clear the preview
        // rather than read the shared instance the PDFView renders. The engine
        // path never invokes OCR for live preview.
        guard let previewDoc = SearchCopy.make(of: SendablePDFDocument(liveDoc), unlockingWith: documentState.documentPassword) else {
            searchState.clearLivePreview()
            return
        }
        searchState.scheduleLivePreview(
            searcher: searcher,
            currentPageIndex: documentState.currentPageIndex,
            totalPageCount: liveDoc.pageCount,
            pageTextProvider: { idx in
                guard idx >= 0 && idx < previewDoc.document.pageCount else { return nil }
                return previewDoc.document.page(at: idx)?.string
            }
        )
    }

    func resolveAndPublishLivePreviewRects() {
        guard let preview = searchState.livePreview,
              let doc = documentState.sourceDocument,
              let page = doc.page(at: documentState.currentPageIndex)
        else {
            searchState.setLivePreviewRects([])
            return
        }
        let rects = PageHighlightOverlay.previewRects(for: preview, page: page, searcher: searcher)
        searchState.setLivePreviewRects(rects)
    }
}
