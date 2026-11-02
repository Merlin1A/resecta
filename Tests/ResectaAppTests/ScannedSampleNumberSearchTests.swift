import Testing
import Foundation
import PDFKit
import UIKit
@testable import ResectaApp
@testable import RedactionEngine

// The sample statement's service number on a scanned page. Page 3 drawn as
// a 300 dpi picture with no text layer is read by text recognition on the
// OCR route; a default text search for the number matches it. On iOS 27
// recognition can read the number with a space beside a hyphen, which the
// OCR literal path folds before matching.

@Suite("Search on a scanned page: the sample's service number", .tags(.importFlow))
@MainActor
struct ScannedSampleNumberSearchTests {

    /// Page `index` of the bundled sample as a picture-only PDF page.
    private func scannedSamplePage(_ index: Int) throws -> PDFDocument {
        let url = try #require(Bundle.main.url(forResource: "SampleDocument", withExtension: "pdf"))
        let page = try #require(PDFDocument(url: url)?.page(at: index)?.pageRef)
        let box = page.getBoxRect(.cropBox)
        let scale: CGFloat = 300 / 72
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let picture = UIGraphicsImageRenderer(size: CGSize(width: box.width * scale, height: box.height * scale), format: format)
            .image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: box.width * scale, height: box.height * scale))
                ctx.cgContext.translateBy(x: 0, y: box.height * scale)
                ctx.cgContext.scaleBy(x: scale, y: -scale)
                ctx.cgContext.translateBy(x: -box.minX, y: -box.minY)
                ctx.cgContext.drawPDFPage(page)
            }
        let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: box.size)).pdfData { pdf in
            pdf.beginPage()
            picture.draw(in: CGRect(origin: .zero, size: box.size))
        }
        return try #require(PDFDocument(data: data))
    }

    @Test("A default text search for the service number matches the scanned statement page")
    func serviceNumberOnTheScannedPage() async throws {
        let doc = try scannedSamplePage(2)
        #expect((doc.page(at: 0)?.string ?? "").isEmpty, "the page is a picture with no text layer")
        let searcher = DocumentSearcher()
        await searcher.setTextLayerStatus([0: TextLayerStatus.none])
        var results: [SearchResult] = []
        for await result in searcher.search(SendablePDFDocument(doc), mode: .text("1-800-555-0199", options: SearchOptions()),
                                            progress: { _, _ in }) {
            results.append(result)
        }
        #expect(results.contains { if case .ocr = $0.source { true } else { false } },
                "results: \(results.map(\.matchedText))")
    }
}
