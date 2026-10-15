import Testing
import PDFKit
#if canImport(UIKit)
import UIKit
#endif
@testable import RedactionEngine

@Suite("Search Performance", .tags(.search))
struct SearchPerformanceTests {

    // MARK: - Result Cap

    @Test("Result cap at 1000 prevents unbounded growth")
    func resultCap() async {
        // Create a PDF where every page has many matches
        let repeatedText = Array(repeating: "match", count: 100).joined(separator: " ")
        let data = multiPageTextPDF(pageCount: 20, text: repeatedText)
        guard let doc = PDFDocument(data: data) else {
            Issue.record("Failed to create PDFDocument")
            return
        }

        let searcher = DocumentSearcher()
        let mode = SearchMode.text("match", options: SearchOptions())
        let stream = searcher.search(
            SendablePDFDocument(doc), mode: mode,
            progress: { _, _ in }
        )

        var count = 0
        for await _ in stream { count += 1 }

        #expect(count <= DocumentSearcher.maxResults)
    }

    // MARK: - Helpers

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
