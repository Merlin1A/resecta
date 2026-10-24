import Testing
import Foundation
import CoreGraphics
import PDFKit
#if canImport(UIKit)
import UIKit
#endif
@testable import RedactionEngine

// The engine's embedded-text builder (`EmbeddedTextSource.make`) on empty and
// sparse pages.
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
}
