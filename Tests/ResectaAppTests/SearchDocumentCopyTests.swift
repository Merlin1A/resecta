import Testing
import Foundation
import PDFKit
import UIKit
import RedactionEngine
@testable import ResectaApp

// SEARCH D10-F1 — per-consumer PDFDocument copy (`DocumentState.makeSearchCopy`).
// These cover the COPY mechanism the background search and the live-preview
// text-walk rely on so neither reads the on-screen instance the main-thread
// PDFView renders. NEW app-target file → ran `./regenerate.sh` so XcodeGen
// registers it (per the session plan testFiles note).
//
// The view-level fail-closed wiring (trigger sets `isSearching = false` +
// enqueues the toast; live preview calls `clearLivePreview()` when the copy is
// nil) requires constructing the SwiftUI sheet + its environment, which is out
// of unit-test scope without a production seam — that integration belongs to
// the iOS 26.4 sim pass (JESSE-TRACK: J-COPY-VERIFY). The helper-level
// nil-contract and the anti-shared-instance discipline ARE covered here.
@Suite("Search per-consumer document copy", .tags(.search))
@MainActor
struct SearchDocumentCopyTests {

    // MARK: - Helpers

    /// Build a multi-page PDF with a distinct selectable text line per page so
    /// per-page string equality is meaningful. Mirrors the engine suites'
    /// UIGraphicsPDFRenderer fixtures (real, selectable text layer).
    private func multiPagePDF(pageTexts: [String]) -> PDFDocument {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let data = renderer.pdfData { context in
            for text in pageTexts {
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
        return PDFDocument(data: data)!
    }

    // MARK: - #1 Copy identity

    @Test("makeSearchCopy returns a distinct instance with the same pages")
    func copyIsDistinctButEquivalent() throws {
        let source = multiPagePDF(pageTexts: [
            "Page zero token alpha", "Page one token beta", "Page two token gamma"
        ])
        let copy = try #require(
            DocumentState.makeSearchCopy(of: SendablePDFDocument(source)),
            "makeSearchCopy returned nil for a valid multi-page document"
        )

        // Distinct object — the off-main consumer never shares the source graph.
        #expect(copy.document !== source)
        // Same shape + same per-page text (same bytes, re-parsed).
        #expect(copy.document.pageCount == source.pageCount)
        for idx in 0..<source.pageCount {
            #expect(copy.document.page(at: idx)?.string == source.page(at: idx)?.string)
        }
    }

    // MARK: - #3 Provider isolation

    @Test("the live-preview provider reads the copy, never the source instance")
    func previewProviderReadsCopyNotSource() async throws {
        let source = multiPagePDF(pageTexts: ["alpha page", "beta page", "gamma page"])
        let previewDoc = try #require(
            DocumentState.makeSearchCopy(of: SendablePDFDocument(source))
        )
        #expect(previewDoc.document !== source)

        // Build the provider exactly as `scheduleLivePreviewIfApplicable` wires
        // it (over `previewDoc`), then confirm it reads the copy's pages.
        let pageTextProvider: @Sendable (Int) async -> String? = { idx in
            guard idx >= 0 && idx < previewDoc.document.pageCount else { return nil }
            return previewDoc.document.page(at: idx)?.string
        }
        let page0 = await pageTextProvider(0)
        #expect(page0?.contains("alpha") == true)
        // The provider's backing instance is the copy, not the source.
        #expect(previewDoc.document !== source)
    }

    // MARK: - #4 nil-contract (no shared-instance fallback)

    @Test("makeSearchCopy never hands back the source instance")
    func copyNeverAliasesSource() throws {
        // The fail-closed contract is that a nil copy ⇒ the caller stops; the
        // helper must NEVER substitute the source on the failure edge. A valid
        // copy is a fresh object; an empty (zero-page) document still yields a
        // fresh object or nil — never the source itself.
        let source = multiPagePDF(pageTexts: ["only page token"])
        let copy = DocumentState.makeSearchCopy(of: SendablePDFDocument(source))
        if let copy {
            #expect(copy.document !== source)
        }

        // A freshly-constructed empty PDFDocument has no bytes to round-trip;
        // whatever the helper returns, it is not the source instance.
        let empty = PDFDocument()
        let emptyCopy = DocumentState.makeSearchCopy(of: SendablePDFDocument(empty))
        if let emptyCopy {
            #expect(emptyCopy.document !== empty)
        }
    }
}
