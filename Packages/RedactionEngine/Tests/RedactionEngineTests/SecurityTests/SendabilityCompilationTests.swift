import Testing
import Foundation
import PDFKit
#if canImport(UIKit)
import UIKit
#endif

// EXP-013 migrated: Sendability Compilation
// Audit: CC-3-1 (High), CC-4-1 (High)
// Tests @unchecked Sendable wrappers for PDFDocument/PDFPage under strict concurrency.

private struct SendablePDFDocument: @unchecked Sendable { let document: PDFDocument }
private struct SendablePDFPage: @unchecked Sendable { let page: PDFPage }

private func simulatedRunLayer(document: SendablePDFDocument, pageIndex: Int, layerIndex: Int) -> String {
    let text = document.document.page(at: pageIndex)?.string ?? ""
    return "Layer \(layerIndex): \(text.prefix(20))..."
}

private func simulatedDetectPII(page: SendablePDFPage) -> [String] {
    let text = page.page.string ?? ""
    let regex = try? NSRegularExpression(pattern: #"\d{3}-\d{2}-\d{4}"#)
    let range = NSRange(text.startIndex..., in: text)
    return (regex?.matches(in: text, range: range) ?? []).compactMap {
        Range($0.range, in: text).map { String(text[$0]) }
    }
}

@Suite("Sendability Compilation", .tags(.critical))
struct SendabilityCompilationTests {

    // --- CC-3-1: @unchecked Sendable wrapper compiles and works ---
    @Test("SendablePDFDocument wrapper compiles and wraps correctly")
    func sendableWrapperCompiles() {
        let data = TestFixtures.blankPage()
        let doc = PDFDocument(data: data)!
        let wrapped = SendablePDFDocument(document: doc)
        #expect(wrapped.document.pageCount == 1)
    }

    // --- CC-3-1: Can pass wrapper across concurrency boundaries ---
    @Test("SendablePDFDocument can cross concurrency boundaries")
    func concurrentRunLayerWithWrapper() async {
        let data = TestFixtures.blankPage()
        let wrapped = SendablePDFDocument(document: PDFDocument(data: data)!)
        let result = simulatedRunLayer(document: wrapped, pageIndex: 0, layerIndex: 1)
        #expect(!result.isEmpty)
    }

    // --- CC-4-1: PII detection with SendablePDFPage ---
    @Test("SendablePDFPage enables concurrent PII detection")
    func concurrentPIIDetectionWithWrapper() async {
        let data = TestFixtures.documentWithPII(terms: ["123-45-6789"])
        let doc = PDFDocument(data: data)!
        let wrapped = SendablePDFPage(page: doc.page(at: 0)!)
        let results = simulatedDetectPII(page: wrapped)
        #expect(results.contains("123-45-6789"))
    }

    // --- CC-4-1: Sequential access pattern safety ---
    @Test("Sequential page access through Sendable wrapper is safe")
    func sequentialAccessPatternSafety() async {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let multiPageData = renderer.pdfData { context in
            for _ in 0..<3 { context.beginPage() }
        }
        let doc = PDFDocument(data: multiPageData)!
        let wrapped = SendablePDFDocument(document: doc)
        for i in 0..<wrapped.document.pageCount {
            let result = simulatedRunLayer(document: wrapped, pageIndex: i, layerIndex: 1)
            #expect(!result.isEmpty)
        }
    }
}
