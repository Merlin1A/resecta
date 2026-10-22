import Testing
import Foundation
import PDFKit
import UIKit
import RedactionEngine
@testable import ResectaApp

// The share confirm's concealing-annotations line: a received PDF whose
// annotations (a black square, a stamp, an unapplied redaction mark) sat
// over text that no redaction box covers exports that text visible — the
// export is rebuilt from the page content, which carries no annotations.

@Suite("Concealing annotations at share")
@MainActor
struct ConcealingAnnotationsTests {

    /// A one-page text PDF and the bounds (page space) of its account number.
    private func page() throws -> (PDFDocument, PDFPage, CGRect) {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { ctx in
            ctx.beginPage()
            ("Account 4417 1234 5678 9113 on file" as NSString).draw(
                at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
        let document = try #require(PDFDocument(data: data))
        let page = try #require(document.page(at: 0))
        let range = ((page.string ?? "") as NSString).range(of: "4417 1234 5678 9113")
        try #require(range.location != NSNotFound)
        let selection = try #require(page.selection(for: range))
        return (document, page, selection.bounds(for: page))
    }

    private func normalized(_ rect: CGRect, on page: PDFPage) -> CGRect {
        let crop = page.bounds(for: .cropBox)
        return CGRect(x: (rect.minX - crop.minX) / crop.width, y: (rect.minY - crop.minY) / crop.height,
                      width: rect.width / crop.width, height: rect.height / crop.height)
    }

    @Test("A square annotation over text no box covers names its page; a box over it, a square over blank space and a link do not")
    func detector() throws {
        let (document, page, bounds) = try page()
        page.addAnnotation(PDFAnnotation(bounds: bounds.insetBy(dx: -2, dy: -2), forType: .square, withProperties: nil))
        #expect(ConcealingAnnotations.pages(in: document, regions: [:]) == [0])
        let box = RedactionRegion(id: UUID(), normalizedRect: normalized(bounds.insetBy(dx: -6, dy: -6), on: page), source: .manual)
        #expect(ConcealingAnnotations.pages(in: document, regions: [0: [box]]).isEmpty, "a redaction box covers it")

        let (blankDocument, blankPage, _) = try self.page()
        blankPage.addAnnotation(PDFAnnotation(bounds: CGRect(x: 300, y: 300, width: 100, height: 40), forType: .square, withProperties: nil))
        #expect(ConcealingAnnotations.pages(in: blankDocument, regions: [:]).isEmpty, "no text under it")

        let (linkDocument, linkPage, linkBounds) = try self.page()
        linkPage.addAnnotation(PDFAnnotation(bounds: linkBounds, forType: .link, withProperties: nil))
        #expect(ConcealingAnnotations.pages(in: linkDocument, regions: [:]).isEmpty, "a link does not conceal")
        #expect(ConcealingAnnotations.pages(in: nil, regions: [:]).isEmpty)
    }

    @Test("The confirm line names the pages in the row's page phrase, singular and plural; the title")
    func copy() {
        #expect(ConcealingAnnotations.confirmLine(pages: [2])
                == "An annotation in the original covers text on\u{00A0}page\u{00A0}3 that no redaction box covers. Annotations are not part of the page image, so that text is visible in the exported PDF.")
        #expect(ConcealingAnnotations.confirmLine(pages: [0, 2])
                == "Annotations in the original cover text on pages 1\u{00A0}and\u{00A0}3 that no redaction box covers. Annotations are not part of the page image, so that text is visible in the exported PDF.")
        #expect(ConcealingAnnotations.confirmTitle == "Share with covered text?")
    }

    @Test("The confirm applies on any verdict when pages are named and not yet acknowledged; acknowledging and re-arming")
    func predicateAndAcknowledgement() {
        #expect(!DocumentEditorView.shareNeedsConcealedAnnotationsConfirm(pages: [], acknowledged: false))
        #expect(DocumentEditorView.shareNeedsConcealedAnnotationsConfirm(pages: [1], acknowledged: false))
        #expect(!DocumentEditorView.shareNeedsConcealedAnnotationsConfirm(pages: [1], acknowledged: true))
        let state = DocumentState()
        #expect(!state.concealedAnnotationsShareAcknowledged)
        state.acknowledgeConcealedAnnotationsShare()
        #expect(state.concealedAnnotationsShareAcknowledged)
        state.rearmShareRiskConfirms()
        #expect(!state.concealedAnnotationsShareAcknowledged, "backing out of the share sheet re-arms it")
    }

    @Test("The concealed-annotations family: its own title and identifier, no list header and no item lines (its line is the cross-cutting one)")
    func kind() {
        let kind = ShareRiskConfirmKind.concealedAnnotations(.skipped)
        #expect(kind.id == "concealedAnnotations")
        #expect(kind.title == ConcealingAnnotations.confirmTitle)
        #expect(kind.listHeader == nil)
        #expect(kind.itemLines.isEmpty)
        #expect(kind.accessibilityIdentifier == "shareConcealedAnnotationsConfirm")
    }
}
