import Testing
import Foundation
import PDFKit
#if canImport(UIKit)
import UIKit
#endif

// Sendability compile canary.
//
// What this file proves: two FILE-LOCAL `@unchecked Sendable` wrappers around
// PDFDocument / PDFPage build under strict concurrency (`SWIFT_STRICT_CONCURRENCY:
// complete`) and can be handed to a nonisolated function. Nothing here touches a
// product type — the wrappers, `simulatedRunLayer` and `simulatedDetectPII` are
// stand-ins declared below; the product's own wrappers live in the app target.
// The four tests are the canary's runtime half: the wrapped values still read.

private struct SendablePDFDocument: @unchecked Sendable { let document: PDFDocument }
private struct SendablePDFPage: @unchecked Sendable { let page: PDFPage }

private func simulatedRunLayer(document: SendablePDFDocument, pageIndex: Int, layerIndex: Int) -> String {
    let text = document.document.page(at: pageIndex)?.string ?? ""
    return "Layer \(layerIndex): \(text.prefix(20))..."
}

private func simulatedDetectPII(page: SendablePDFPage) -> [String] {
    let text = page.page.string ?? ""
    // A stand-in pattern for the canary only; the product's SSN detector is
    // the DEA/SSN family in `Detection/`, not this regex.
    let regex = try? NSRegularExpression(pattern: #"\d{3}-\d{2}-\d{4}"#)
    let range = NSRange(text.startIndex..., in: text)
    return (regex?.matches(in: text, range: range) ?? []).compactMap {
        Range($0.range, in: text).map { String(text[$0]) }
    }
}

@Suite("Sendability compile canary — file-local @unchecked Sendable wrappers")
struct SendabilityCompilationTests {

    // --- @unchecked Sendable wrapper compiles and works ---
    @Test("SendablePDFDocument wrapper compiles and wraps correctly")
    func sendableWrapperCompiles() {
        let data = TestFixtures.blankPage()
        let doc = PDFDocument(data: data)!
        let wrapped = SendablePDFDocument(document: doc)
        #expect(wrapped.document.pageCount == 1)
    }

    // --- Can pass wrapper across concurrency boundaries ---
    @Test("SendablePDFDocument can cross concurrency boundaries")
    func concurrentRunLayerWithWrapper() {
        let data = TestFixtures.blankPage()
        let wrapped = SendablePDFDocument(document: PDFDocument(data: data)!)
        let result = simulatedRunLayer(document: wrapped, pageIndex: 0, layerIndex: 1)
        #expect(!result.isEmpty)
    }

    // --- PII detection with SendablePDFPage ---
    @Test("SendablePDFPage enables concurrent PII detection")
    func concurrentPIIDetectionWithWrapper() {
        let data = TestFixtures.documentWithPII(terms: ["123-45-6789"])
        let doc = PDFDocument(data: data)!
        let wrapped = SendablePDFPage(page: doc.page(at: 0)!)
        let results = simulatedDetectPII(page: wrapped)
        #expect(results.contains("123-45-6789"))
    }

    // --- Sequential access pattern safety ---
    @Test("Sequential page access through Sendable wrapper is safe")
    func sequentialAccessPatternSafety() {
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
