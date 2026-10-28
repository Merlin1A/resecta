import Testing
import Foundation
import PDFKit
import UIKit
import RedactionEngine
@testable import ResectaApp

// The results screen's findings that the checks of the redacted PDF cannot
// see, derived from the real `DocumentState` + `RedactionState` and a PDF
// built here: a received document whose black square hid a word is listed
// among the findings with its page, and the masthead counts it as a note.

@Suite("Results findings the checks cannot see")
@MainActor
struct ResultsFindingsTests {

    /// A one-page text PDF with a square annotation over its account number,
    /// and that number's rect in normalized page space.
    private func coveredDocument() throws -> (PDFDocument, CGRect) {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { ctx in
            ctx.beginPage()
            ("Account 4417 1234 5678 9113 on file" as NSString).draw(
                at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
        let document = try #require(PDFDocument(data: data))
        let page = try #require(document.page(at: 0))
        let range = ((page.string ?? "") as NSString).range(of: "4417 1234 5678 9113")
        try #require(range.location != NSNotFound)
        let bounds = try #require(page.selection(for: range)).bounds(for: page)
        page.addAnnotation(PDFAnnotation(bounds: bounds.insetBy(dx: -2, dy: -2), forType: .square, withProperties: nil))
        let crop = page.bounds(for: .cropBox)
        let wide = bounds.insetBy(dx: -6, dy: -6)
        return (document, CGRect(x: (wide.minX - crop.minX) / crop.width, y: (wide.minY - crop.minY) / crop.height,
                                 width: wide.width / crop.width, height: wide.height / crop.height))
    }

    private static let passReport = VerificationReport(
        layers: [LayerResult(name: "Character Count", symbolName: "number", status: .pass,
                             shortDescription: "", detailDescription: "", pageReferences: nil, durationSeconds: 0)],
        overallStatus: .pass, durationSeconds: 0)

    @Test("An annotation over text no box covers is listed with its page; a box over the text clears it")
    func coveredTextIsAFinding() throws {
        let (document, wordRect) = try coveredDocument()
        let documentState = DocumentState()
        documentState.sourceDocument = document
        let redactionState = RedactionState()
        #expect(ResultsFindings.derive(documentState: documentState, redactionState: redactionState)
                == [.coveredTextInOriginal(pages: [0])])

        redactionState.regions = [0: [RedactionRegion(id: UUID(), normalizedRect: wordRect, source: .manual)]]
        #expect(ResultsFindings.derive(documentState: documentState, redactionState: redactionState).isEmpty)

        documentState.sourceDocument = nil
        #expect(ResultsFindings.derive(documentState: documentState, redactionState: RedactionState()).isEmpty)
    }

    @Test("The covered-text row says the share confirm's words, under its own title and identifier")
    func coveredTextWords() {
        let item = ResultsFinding.coveredTextInOriginal(pages: [0, 2])
        #expect(item.title == "Covered text in the original")
        #expect(item.sentence == ConcealingAnnotations.confirmLine(pages: [0, 2]))
        #expect(item.pages == [0, 2])
        #expect(item.accessibilityIdentifier == "resultsFinding_coveredText")
        #expect(item.spokenLabel == "Covered text in the original. \(ConcealingAnnotations.confirmLine(pages: [0, 2]))")
    }

    @Test("A clean PASS with one listed item asks the reader to read the note; with none, to look over Preview")
    func mastheadCountsFindingsAsNotes() {
        #expect(VerificationResultsView.mastheadSubtitle(report: Self.passReport, findingCount: 1)
                == "Read the note below before you share the PDF.")
        #expect(VerificationResultsView.mastheadSubtitle(report: Self.passReport, findingCount: 2)
                == "Read the notes below before you share the PDF.")
        #expect(VerificationResultsView.mastheadSubtitle(report: Self.passReport, findingCount: 0)
                == "Look over the redacted PDF in Preview before you share it.")
        #expect(VerificationResultsView.mastheadAccessibilityLabel(report: Self.passReport, findingCount: 1)
                .hasSuffix("Read the note below before you share the PDF."))
    }

    @Test("The text-layer check is titled for the redacted PDF it reads")
    func textLayerRowTitle() {
        let row = LayerResult(name: "Text Extraction", symbolName: "doc.text", status: .pass,
                              shortDescription: "", detailDescription: "", pageReferences: nil, durationSeconds: 0,
                              layer: .textExtraction)
        #expect(VerificationRowModel.title(for: row) == "Text & Annotations in the Redacted PDF")
    }
}
