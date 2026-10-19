import Testing
import Foundation
import CoreGraphics
import PDFKit
#if canImport(UIKit)
import UIKit
#endif
@testable import RedactionEngine

// The engine's embedded-text builder (`EmbeddedTextSource.make`) on empty and
// sparse pages, and `DetectionResult`'s default provenance.
@Suite("OCR Skip Fast Path", .serialized)
struct OCRSkipFastPathTests {

    // MARK: - Coverage gate helpers (engine-level builder)

    @Test("EmbeddedTextSource.make returns nil for empty pages")
    func testEmbeddedTextSourceNilOnEmpty() throws {
        let data = TestFixtures.blankPage()
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        let source = EmbeddedTextSource.make(from: page)
        #expect(source == nil)
    }

    @Test("EmbeddedTextSource.make returns a source with low coverage for sparse text")
    func testEmbeddedTextSourceLowCoverageOnSparseText() throws {
        let data = TestFixtures.textLayerPDF(
            text: "John Smith SSN 123-45-6789 lives at 742 Evergreen Terrace"
        )
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        let source = try #require(EmbeddedTextSource.make(from: page))
        // Single line on an 8.5x11 sheet — coverage is well under the locked
        // 0.95 threshold. Skip gate must NOT engage.
        #expect(source.coverage < 0.95)
        #expect(source.coverage > 0)
    }

    // MARK: - Provenance default value

    @Test("DetectionResult init defaults to .ocrRan provenance")
    func testDetectionResultDefaultProvenanceIsOcrRan() {
        let det = DetectionResult(
            normalizedRect: CGRect(x: 0, y: 0, width: 0.1, height: 0.1),
            kind: .pii(.ssn),
            confidence: 0.9
        )
        #expect(det.provenance.ocrSkipped == false)
        #expect(det.provenance.ocrSkipReason == nil)
        #expect(det.provenance == .ocrRan)
    }
}
