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
}
