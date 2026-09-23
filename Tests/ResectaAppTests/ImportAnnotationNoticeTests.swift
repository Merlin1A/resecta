import Testing
import Foundation
import PDFKit
@testable import ResectaApp
@testable import RedactionEngine

// Import annotation notice — the import path runs the engine's
// `AnnotationAnalyzer` over the validated document, counts the form
// fields that carry a value, and stages both on `DocumentState`;
// `DocumentEditorView` surfaces them as one banner while editing. These
// pins cover the app-side wiring: an annotated source stages results,
// clean sources stage nothing, a form stages its filled-field count, the
// visibility contract, and the mechanism copy. Subtype filtering (Widget
// skip, black-square classification) is the engine's contract, pinned in
// the engine's own `AnnotationAnalyzerTests`.

@Suite("Import annotation notice", .tags(.importFlow))
@MainActor
struct ImportAnnotationNoticeTests {

    /// One-page PDF with drawn page text plus a black-filled `Square`
    /// annotation, built through PDFKit so the annotation serializes the
    /// way a real annotated document carries it.
    private func makeAnnotatedPDFData() throws -> Data {
        let base = makeTextPDFData(text: "Sample page text")
        let doc = try #require(PDFDocument(data: base))
        let page = try #require(doc.page(at: 0))
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 60, y: 690, width: 260, height: 40),
            forType: .square,
            withProperties: nil
        )
        annotation.interiorColor = .black
        page.addAnnotation(annotation)
        let data = try #require(doc.dataRepresentation())
        // Guard against a vacuous pass: the annotation must survive the
        // PDFKit round-trip, or the import assertions below would be
        // checking an unannotated document.
        let reloaded = try #require(PDFDocument(data: data))
        let reloadedPage = try #require(reloaded.page(at: 0))
        #expect(!reloadedPage.annotations.isEmpty)
        return data
    }

    // MARK: - Import wiring

    @Test("Annotated PDF import stages annotation results and resets dismissal")
    func annotatedImportStagesResults() async throws {
        let doc = DocumentState()
        let redaction = RedactionState()
        // Stale value from a previously-open document: import must reset it.
        doc.annotationNoticeDismissed = true

        await ImportService.importDocument(
            data: try makeAnnotatedPDFData(), suggestedType: "pdf",
            documentState: doc, redactionState: redaction)

        #expect(doc.phaseKind == .editing)
        #expect(!doc.sourceAnnotationFindings.isEmpty,
                "an annotated source must stage analyzer results at import")
        #expect(doc.annotationNoticeDismissed == false,
                "dismissal is per-document and resets on import")
    }

    @Test("PDF without annotations stages nothing")
    func cleanImportStagesNothing() async {
        let doc = DocumentState()
        let redaction = RedactionState()

        await ImportService.importDocument(
            data: makeTextPDFData(text: "Plain page"), suggestedType: "pdf",
            documentState: doc, redactionState: redaction)

        #expect(doc.phaseKind == .editing)
        #expect(doc.sourceAnnotationFindings.isEmpty)
    }

    @Test("Image import stages nothing — a rendered page has no annotations")
    func imageImportStagesNothing() async {
        let doc = DocumentState()
        let redaction = RedactionState()

        await ImportService.importDocument(
            data: makeJPEGImageData(), suggestedType: "image",
            documentState: doc, redactionState: redaction)

        #expect(doc.phaseKind == .editing)
        #expect(doc.sourceAnnotationFindings.isEmpty)
    }

    /// One-page PDF whose only annotation is an ordinary hyperlink — the
    /// commonest annotation subtype in circulation, and one that draws
    /// nothing over page content.
    private func makeLinkOnlyPDFData() throws -> Data {
        let base = makeTextPDFData(text: "Sample page text")
        let doc = try #require(PDFDocument(data: base))
        let page = try #require(doc.page(at: 0))
        let link = PDFAnnotation(
            bounds: CGRect(x: 60, y: 690, width: 260, height: 20),
            forType: .link,
            withProperties: nil
        )
        link.url = try #require(URL(string: "https://example.com"))
        page.addAnnotation(link)
        let data = try #require(doc.dataRepresentation())
        // Round-trip guard: the Link must survive serialization, or the
        // quiet-import assertions below would pass on an unannotated
        // document.
        let reloaded = try #require(PDFDocument(data: data))
        let reloadedPage = try #require(reloaded.page(at: 0))
        #expect(reloadedPage.annotations.contains { $0.type == "Link" })
        return data
    }

    /// One-page PDF carrying both a hyperlink and a black-filled `Square`
    /// — the concealing subtype must keep the notice on even when a
    /// filtered subtype is present alongside it.
    private func makeLinkPlusSquarePDFData() throws -> Data {
        let base = makeTextPDFData(text: "Sample page text")
        let doc = try #require(PDFDocument(data: base))
        let page = try #require(doc.page(at: 0))
        let link = PDFAnnotation(
            bounds: CGRect(x: 60, y: 740, width: 260, height: 20),
            forType: .link,
            withProperties: nil
        )
        link.url = try #require(URL(string: "https://example.com"))
        page.addAnnotation(link)
        let square = PDFAnnotation(
            bounds: CGRect(x: 60, y: 690, width: 260, height: 40),
            forType: .square,
            withProperties: nil
        )
        square.interiorColor = .black
        page.addAnnotation(square)
        let data = try #require(doc.dataRepresentation())
        let reloaded = try #require(PDFDocument(data: data))
        let reloadedPage = try #require(reloaded.page(at: 0))
        #expect(reloadedPage.annotations.contains { $0.type == "Link" })
        #expect(reloadedPage.annotations.contains { $0.type == "Square" })
        return data
    }

    // MARK: - Non-concealing subtype filter

    @Test("Link-only PDF stages its finding but does not show the notice")
    func linkOnlyImportStaysQuiet() async throws {
        let doc = DocumentState()
        let redaction = RedactionState()

        await ImportService.importDocument(
            data: try makeLinkOnlyPDFData(), suggestedType: "pdf",
            documentState: doc, redactionState: redaction)

        #expect(doc.phaseKind == .editing)
        // Staging stays the faithful record of what the analyzer saw…
        #expect(doc.sourceAnnotationFindings.contains { $0.id == "annotation-link" },
                "the staged findings must still carry the analyzer's record")
        // …and the banner's own policy keeps it out of the count.
        let count = ImportAnnotationNoticeBanner.noticeWorthyCount(doc.sourceAnnotationFindings)
        #expect(count == 0)
        #expect(!ImportAnnotationNoticeBanner.isVisible(
            phaseKind: .editing, annotationTypeCount: count, dismissed: false,
            pausedBannerActive: false, detectionBannerActive: false))
    }

    @Test("Link plus a black square still shows the notice")
    func linkPlusSquareStillShowsNotice() async throws {
        let doc = DocumentState()
        let redaction = RedactionState()

        await ImportService.importDocument(
            data: try makeLinkPlusSquarePDFData(), suggestedType: "pdf",
            documentState: doc, redactionState: redaction)

        #expect(doc.phaseKind == .editing)
        let count = ImportAnnotationNoticeBanner.noticeWorthyCount(doc.sourceAnnotationFindings)
        #expect(count == 1, "the square stays notice-worthy; only the link is filtered")
        #expect(ImportAnnotationNoticeBanner.isVisible(
            phaseKind: .editing, annotationTypeCount: count, dismissed: false,
            pausedBannerActive: false, detectionBannerActive: false))
    }

    // MARK: - Filled form fields

    /// Objects numbered from 1 in order, a valid cross-reference table
    /// (the engine's fixture factories are not visible to this target).
    private static func rawPDF(_ objects: [String]) -> Data {
        var body = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (index, content) in objects.enumerated() {
            offsets.append(body.utf8.count)
            body += "\(index + 1) 0 obj\n\(content)\nendobj\n"
        }
        let xrefOffset = body.utf8.count
        body += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            body += String(format: "%010d 00000 n \n", offset)
        }
        body += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        return Data(body.utf8)
    }

    /// A real AcroForm: `/AcroForm` in the catalog, one merged
    /// field-plus-widget dictionary per entry (`/FT /Tx`, `/T`, `/V`), no
    /// appearance streams — the shape a filled form carries when its
    /// values live in the field dictionaries and nowhere on the page.
    private static func acroFormPDF(fields: [(name: String, value: String)]) -> Data {
        let firstFieldID = 5
        let refs = fields.indices.map { "\(firstFieldID + $0) 0 R" }.joined(separator: " ")
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [\(refs)] /DA (/Helv 0 Tf 0 g) /NeedAppearances true >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << >> /Annots [\(refs)] >>",
            "<< /Length 0 >>\nstream\n\nendstream",
        ]
        for (index, field) in fields.enumerated() {
            let y = 640 - index * 40
            objects.append(
                "<< /Type /Annot /Subtype /Widget /FT /Tx /T (\(field.name)) /V (\(field.value)) "
                + "/Rect [72 \(y) 372 \(y + 24)] /F 4 /DA (/Helv 12 Tf 0 g) /P 3 0 R >>")
        }
        return rawPDF(objects)
    }

    private static let filledForm: [(name: String, value: String)] = [
        ("applicant_ssn", "987-65-4329"),
        ("applicant_phone", "(208) 555-0147"),
        ("notes", ""),
    ]

    @Test("Filled form fields are counted by value; an empty field is not")
    func filledFormFieldsCountedByValue() throws {
        let doc = try #require(PDFDocument(data: Self.acroFormPDF(fields: Self.filledForm)))
        // Guard against a vacuous pass: PDFKit must see all three widgets
        // and read the values, or the count below would be checking a
        // document without fields.
        let page = try #require(doc.page(at: 0))
        let widgets = page.annotations.filter { $0.type == "Widget" }
        #expect(widgets.count == 3)
        #expect(widgets.contains { $0.widgetStringValue == "987-65-4329" })

        #expect(ImportAnnotationNoticeBanner.filledFormFieldCount(in: doc) == 2)

        let empty = try #require(PDFDocument(data: makeTextPDFData(text: "No fields")))
        #expect(ImportAnnotationNoticeBanner.filledFormFieldCount(in: empty) == 0)
    }

    @Test("A filled form stages its count and shows the notice with no annotation result staged")
    func filledFormImportStagesCountAndShowsNotice() async {
        let doc = DocumentState()
        let redaction = RedactionState()
        // Stale count from a previously-open document: import must replace it.
        doc.sourceFilledFormFieldCount = 9

        await ImportService.importDocument(
            data: Self.acroFormPDF(fields: Self.filledForm), suggestedType: "pdf",
            documentState: doc, redactionState: redaction)

        #expect(doc.phaseKind == .editing)
        #expect(doc.sourceFilledFormFieldCount == 2)
        // Widgets stay out of the analyzer's findings — the count is the
        // notice's only read of them.
        #expect(doc.sourceAnnotationFindings.isEmpty)
        let annotationCount = ImportAnnotationNoticeBanner.noticeWorthyCount(doc.sourceAnnotationFindings)
        #expect(annotationCount == 0)
        #expect(ImportAnnotationNoticeBanner.isVisible(
            phaseKind: .editing, annotationTypeCount: annotationCount,
            filledFormFieldCount: doc.sourceFilledFormFieldCount, dismissed: false,
            pausedBannerActive: false, detectionBannerActive: false))

        // An image import resets the count: a rendered page has no fields.
        await ImportService.importDocument(
            data: makeJPEGImageData(), suggestedType: "image",
            documentState: doc, redactionState: redaction)
        #expect(doc.sourceFilledFormFieldCount == 0)
    }

    @Test("Notice copy: annotations alone, fields alone, both — one paragraph on one surface")
    func noticeCopyPerSource() {
        let annotationsOnly = ImportAnnotationNoticeBanner.noticeMessage(
            annotationCount: 1, filledFormFieldCount: 0)
        #expect(annotationsOnly == ImportAnnotationNoticeBanner.noticeMessage)

        #expect(ImportAnnotationNoticeBanner.noticeMessage(annotationCount: 0, filledFormFieldCount: 2)
                == "This document contains 2 filled form fields; their values are not carried into the output. Check the preview before sharing.")
        #expect(ImportAnnotationNoticeBanner.noticeMessage(annotationCount: 0, filledFormFieldCount: 1)
                == "This document contains 1 filled form field; its value is not carried into the output. Check the preview before sharing.")

        let both = ImportAnnotationNoticeBanner.noticeMessage(annotationCount: 2, filledFormFieldCount: 3)
        #expect(both.hasPrefix("This document contains annotations such as boxes, stamps, or notes."))
        #expect(both.contains("It also contains 3 filled form fields; their values are not carried into the output."))
        #expect(both.hasSuffix("Check the preview before sharing."))
        #expect(both.components(separatedBy: "Check the preview before sharing.").count == 2,
                "the preview sentence closes the paragraph once")

        #expect(ImportAnnotationNoticeBanner.noticeMessage(annotationCount: 0, filledFormFieldCount: 0).isEmpty)
    }

    // MARK: - Visibility contract

    @Test("Notice shows only while editing an undismissed annotated document")
    func visibilityContract() {
        // The one visible combination.
        #expect(ImportAnnotationNoticeBanner.isVisible(
            phaseKind: .editing, annotationTypeCount: 1, dismissed: false,
            pausedBannerActive: false, detectionBannerActive: false))

        // Each gate flips it off independently.
        #expect(!ImportAnnotationNoticeBanner.isVisible(
            phaseKind: .empty, annotationTypeCount: 1, dismissed: false,
            pausedBannerActive: false, detectionBannerActive: false))
        #expect(!ImportAnnotationNoticeBanner.isVisible(
            phaseKind: .editing, annotationTypeCount: 0, dismissed: false,
            pausedBannerActive: false, detectionBannerActive: false))
        #expect(!ImportAnnotationNoticeBanner.isVisible(
            phaseKind: .editing, annotationTypeCount: 1, dismissed: true,
            pausedBannerActive: false, detectionBannerActive: false))

        // The sibling top-edge banners take precedence; the notice
        // returns once they clear (dismissal is the only terminal state).
        #expect(!ImportAnnotationNoticeBanner.isVisible(
            phaseKind: .editing, annotationTypeCount: 1, dismissed: false,
            pausedBannerActive: true, detectionBannerActive: false))
        #expect(!ImportAnnotationNoticeBanner.isVisible(
            phaseKind: .editing, annotationTypeCount: 1, dismissed: false,
            pausedBannerActive: false, detectionBannerActive: true))
    }

    // MARK: - Copy

    @Test("Notice copy is the pinned mechanism description")
    func noticeCopyIsPinned() {
        // Verbatim pin, mirroring `AccessibilityLabelTests`' treatment of
        // the Settings mode hint: copy edits must be deliberate.
        #expect(ImportAnnotationNoticeBanner.noticeMessage
            == "This document contains annotations such as boxes, stamps, or notes. Annotations are not part of the page image, so the exported file is built without them, and page content beneath them is included in the export. Check the preview before sharing.")
    }
}
