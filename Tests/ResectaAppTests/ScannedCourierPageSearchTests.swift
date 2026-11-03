import Testing
import Foundation
import CoreText
import PDFKit
import UIKit
@testable import ResectaApp
@testable import RedactionEngine

// A scanned page of Courier 10 reference and invoice lines. Text recognition
// on iOS 27 can read one of its lines as noise in its accurate read while
// the fast read of the same image keeps it; on iOS 27 Search reads both, so
// a default text search, a regex search and the PII Scan still match the
// values. On iOS 26 the accurate read holds them, and no fast read is made.

@Suite("Search on a scanned Courier page", .tags(.importFlow))
@MainActor
struct ScannedCourierPageSearchTests {

    static let lines = [
        "Customer Service: 1-800-555-0199",
        "Phone: (208) 555-0147   Fax: (208) 555-0148",
        "Account Number 4100773265   Routing 021000021",
        "NORTHLINE LOGISTICS DIRECT DEP DES:PAYROLL ID:PR4471 INDN:DELIA HARTWELL CO ID:9100004821 PPD",
        "Reference PR4471-A / Case 2026-CV-0042 / Invoice INV-00731",
        "Balance $3,796.49   Withdrawals -$2,789.27   Fees -$12.00",
        "Contact Delia R. Hartwell at 555-0147 or ext. 204",
    ]

    /// A Letter page holding `lines` in Courier 10, drawn as a 300 dpi
    /// picture with no text layer.
    private func scannedCourierPage() throws -> PDFDocument {
        let size = CGSize(width: 612, height: 792), scale: CGFloat = 300 / 72
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let font = CTFontCreateWithName("Courier" as CFString, 10, nil)
        let picture = UIGraphicsImageRenderer(size: CGSize(width: size.width * scale, height: size.height * scale), format: format)
            .image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
                let cg = ctx.cgContext
                cg.translateBy(x: 0, y: size.height * scale)
                cg.scaleBy(x: scale, y: -scale)
                for (i, text) in Self.lines.enumerated() {
                    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String): font,
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)]))
                    cg.textPosition = CGPoint(x: 54, y: 740 - CGFloat(i) * 40)
                    CTLineDraw(line, cg)
                }
            }
        let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { pdf in
            pdf.beginPage()
            picture.draw(in: CGRect(origin: .zero, size: size))
        }
        return try #require(PDFDocument(data: data))
    }

    private func results(_ mode: SearchMode, on doc: PDFDocument, searcher: DocumentSearcher) async -> [SearchResult] {
        var out: [SearchResult] = []
        for await r in searcher.search(SendablePDFDocument(doc), mode: mode, progress: { _, _ in }) { out.append(r) }
        return out
    }

    @Test("Text search, regex search and the PII Scan match the page's values")
    func valuesMatchOnTheScannedPage() async throws {
        let doc = try scannedCourierPage()
        #expect((doc.page(at: 0)?.string ?? "").isEmpty, "the page is a picture with no text layer")
        let searcher = DocumentSearcher()
        await searcher.setTextLayerStatus([0: TextLayerStatus.none])
        for value in ["INV-00731", "2026-CV-0042", "1-800-555-0199"] {
            let hits = await results(.text(value, options: SearchOptions()), on: doc, searcher: searcher)
            #expect(hits.contains { if case .ocr = $0.source { true } else { false } }, "\(value): \(hits.map(\.matchedText))")
        }
        let invoices = await results(.regex(#"INV-\d{5}"#, options: SearchOptions()), on: doc, searcher: searcher)
        #expect(!invoices.isEmpty, "regex INV-#####")
        let phones = await results(.piiScan(categories: [.phone], options: SearchOptions(includeOCR: true)), on: doc, searcher: searcher)
        #expect(phones.contains { $0.matchedText.contains("555-0147") }, "\(phones.map(\.matchedText))")
        let fastRead = await searcher._testFastOCRLines(forPageIndex: 0)
        if DocumentSearcher.readsFastOCRBeside {
            #expect(fastRead != nil, "iOS 27 reads the fast recognition beside the accurate one")
        } else {
            #expect(fastRead == nil, "iOS 26 makes no fast read")
        }
    }
}
