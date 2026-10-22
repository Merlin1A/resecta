import Testing
import Foundation
import PDFKit
import UIKit
@testable import ResectaApp

// The sidebar's thumbnail cache. A thumbnail belongs to one document's
// page: the same page index in a second document must not read the
// first document's picture.

@Suite("Thumbnail cache")
@MainActor
struct ThumbnailCacheTests {

    private func makeThumbnail(gray: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { ctx in
            UIColor(white: gray, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
    }

    @Test("The same page index in a second document does not read the first document's thumbnail")
    func keyedByDocumentAndPage() {
        ThumbnailCache.clear()
        let first = makeTestPDFDocument()
        let second = makeTestPDFDocument()
        let firstThumbnail = makeThumbnail(gray: 0.2)

        ThumbnailCache.set(firstThumbnail, document: first, pageIndex: 0)
        ThumbnailCache.writeQueue.sync {}

        #expect(ThumbnailCache.get(document: first, pageIndex: 0) === firstThumbnail)
        #expect(ThumbnailCache.get(document: second, pageIndex: 0) == nil)
        #expect(ThumbnailCache.get(document: first, pageIndex: 1) == nil)

        ThumbnailCache.clear()
        #expect(ThumbnailCache.get(document: first, pageIndex: 0) == nil)
    }

    @Test("A new document at a freed document's address does not read the freed document's thumbnail")
    func freedAddressReuseMisses() {
        ThumbnailCache.clear()
        var old: PDFDocument? = makeTestPDFDocument()
        let oldAddress = ObjectIdentifier(old!)
        let image = makeThumbnail(gray: 0.5)
        ThumbnailCache.set(image, document: old!, pageIndex: 0)
        ThumbnailCache.writeQueue.sync {}
        #expect(ThumbnailCache.get(document: old!, pageIndex: 0) === image)
        old = nil

        var replacement = makeTestPDFDocument()
        var reused = false
        for _ in 0..<500 {
            replacement = makeTestPDFDocument()
            if ObjectIdentifier(replacement) == oldAddress { reused = true; break }
        }
        #expect(ThumbnailCache.get(document: replacement, pageIndex: 0) == nil,
                reused ? "the freed address was reused; the entry's weak document is gone, so it misses" : "a different document misses")
        ThumbnailCache.clear()
    }

    @Test("Start Over and a new import clear the cache, not only the sidebar's own change handler")
    func startOverAndImportClear() async {
        ThumbnailCache.clear()
        let coord = makeLoadedCoordinator()
        let document = coord.documentState.sourceDocument!
        let image = makeThumbnail(gray: 0.3)
        ThumbnailCache.set(image, document: document, pageIndex: 0)
        ThumbnailCache.writeQueue.sync {}
        #expect(ThumbnailCache.get(document: document, pageIndex: 0) === image)
        coord.documentState.resetForStartOver(redactionState: coord.redactionState, coordinator: coord)
        #expect(ThumbnailCache.get(document: document, pageIndex: 0) == nil, "Start Over clears the cache")

        let doc = DocumentState()
        let redaction = RedactionState()
        let stale = makeTestPDFDocument()
        ThumbnailCache.set(image, document: stale, pageIndex: 0)
        ThumbnailCache.writeQueue.sync {}
        await ImportService.importDocument(data: makeTestPDFData(), suggestedType: "pdf", documentState: doc, redactionState: redaction)
        #expect(doc.phaseKind == .editing)
        #expect(ThumbnailCache.get(document: stale, pageIndex: 0) == nil, "an import clears the cache")
    }
}
