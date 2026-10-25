import Testing
import Foundation
import PDFKit
import RedactionEngine
@testable import ResectaApp

// Covers drawn by a form field or a Watermark annotation: a PDF someone
// "redacted" by placing empty form fields with a black background (or a
// black watermark) over the text. The viewer draws the cover; the export
// is rebuilt from the page content, which draws no annotation, so the text
// under it prints in the output. Both the import notice and the share
// confirm name it, as they do a black square.

@Suite("Form-field and watermark covers")
@MainActor
struct CoverWidgetsTests {

    /// The cover's rect: over the SSN the content stream prints at 72, 700.
    private static let coverRect = "[66 692 260 722]"

    /// A Form XObject the size of the cover, as an appearance stream.
    private static func appearance(_ ops: String, resources: String = "") -> String {
        "<< /Type /XObject /Subtype /Form /BBox [0 0 194 30] \(resources) /Length \(ops.utf8.count) >>\nstream\n\(ops)\nendstream"
    }
    private static let blackAppearance = appearance("0 g 0 0 194 30 re f")

    /// One page that prints "SSN 123-45-6789" in its content stream, under
    /// `annotation` (objects 1–5; object 6 is `sixth`, the appearance stream).
    private static func coveredPDF(_ annotation: String, acroForm: Bool = true,
                                   sixth: String = blackAppearance) -> Data {
        let text = "BT /F1 18 Tf 72 700 Td (SSN 123-45-6789) Tj ET"
        let form = acroForm ? " /AcroForm << /Fields [5 0 R] /DA (/Helv 0 Tf 0 g) >>" : ""
        return rawPDF([
            "<< /Type /Catalog /Pages 2 0 R\(form) >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
                + "/Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >> "
                + "/Annots [5 0 R] >>",
            "<< /Length \(text.utf8.count) >>\nstream\n\(text)\nendstream",
            annotation,
            sixth,
        ])
    }

    /// An empty text field with a black background (`/MK /BG`), no value,
    /// no appearance stream: the Acrobat "black field" cover.
    static let blackBackgroundField = coveredPDF(
        "<< /Type /Annot /Subtype /Widget /FT /Tx /T (cover) /Rect \(coverRect) /F 4 "
        + "/MK << /BG [0 0 0] >> /DA (/Helv 12 Tf 0 g) /P 3 0 R >>")

    /// A field whose appearance stream paints black, with no `/MK` colours.
    static let blackAppearanceField = coveredPDF(
        "<< /Type /Annot /Subtype /Widget /FT /Tx /T (cover) /Rect \(coverRect) /F 4 "
        + "/AP << /N 6 0 R >> /DA (/Helv 12 Tf 0 g) /P 3 0 R >>")

    /// An empty field with no background and no appearance: nothing drawn.
    static let transparentField = coveredPDF(
        "<< /Type /Annot /Subtype /Widget /FT /Tx /T (cover) /Rect \(coverRect) /F 4 "
        + "/DA (/Helv 12 Tf 0 g) /P 3 0 R >>")

    /// A Watermark annotation whose appearance paints black.
    static let blackWatermark = coveredPDF(
        "<< /Type /Annot /Subtype /Watermark /Rect \(coverRect) /F 4 /AP << /N 6 0 R >> /P 3 0 R >>",
        acroForm: false)

    private static let quad = "/QuadPoints [66 722 260 722 66 692 260 692]"

    /// A black highlight: multiplied or not, it darkens the text away.
    static let blackHighlight = coveredPDF(
        "<< /Type /Annot /Subtype /Highlight /Rect \(coverRect) \(quad) /C [0 0 0] /F 4 /P 3 0 R >>",
        acroForm: false)

    /// A yellow highlight painted over the text (Normal blend, opaque).
    static let opaqueHighlight = coveredPDF(
        "<< /Type /Annot /Subtype /Highlight /Rect \(coverRect) \(quad) /C [1 1 0] /F 4 /AP << /N 6 0 R >> /P 3 0 R >>",
        acroForm: false, sixth: appearance("1 1 0 rg 0 0 194 30 re f"))

    /// A yellow highlight multiplied with the text, as viewers draw one.
    static let multipliedHighlight = coveredPDF(
        "<< /Type /Annot /Subtype /Highlight /Rect \(coverRect) \(quad) /C [1 1 0] /F 4 /AP << /N 6 0 R >> /P 3 0 R >>",
        acroForm: false,
        sixth: appearance("/G0 gs 1 1 0 rg 0 0 194 30 re f",
                          resources: "/Resources << /ExtGState << /G0 << /BM /Multiply >> >> >>"))

    private func document(_ data: Data) throws -> PDFDocument {
        let document = try #require(PDFDocument(data: data))
        let page = try #require(document.page(at: 0))
        // Guard against a vacuous pass: the text must read and the
        // annotation must be there.
        try #require((page.string ?? "").contains("123-45-6789"), "the fixture's text layer")
        try #require(page.annotations.count == 1, "the fixture's annotation")
        return document
    }

    @Test("A field with an opaque background or appearance, and a black watermark, over text name the page at share; an empty field does not")
    func shareConfirmNamesCovers() throws {
        for (name, data) in [("background", Self.blackBackgroundField), ("appearance", Self.blackAppearanceField),
                             ("watermark", Self.blackWatermark)] {
            let document = try document(data)
            #expect(ConcealingAnnotations.pages(in: document, regions: [:]) == [0], "\(name)")
        }
        #expect(ConcealingAnnotations.pages(in: try document(Self.transparentField), regions: [:]).isEmpty,
                "an empty field draws nothing over the text")
    }

    @Test("A highlight that hides the text (black, or painted over it opaque) names the page at share; a multiplied yellow one does not")
    func opaqueHighlightConceals() throws {
        for (name, data) in [("black", Self.blackHighlight), ("opaque", Self.opaqueHighlight)] {
            #expect(ConcealingAnnotations.pages(in: try document(data), regions: [:]) == [0], "\(name)")
        }
        #expect(ConcealingAnnotations.pages(in: try document(Self.multipliedHighlight), regions: [:]).isEmpty,
                "a multiplied highlight leaves the text readable")
    }

    @Test("A black form-field cover over text raises both the import notice and the share confirm")
    func blackFieldRaisesNoticeAndConfirm() async throws {
        let doc = DocumentState()
        let redaction = RedactionState()
        await ImportService.importDocument(
            data: Self.blackBackgroundField, suggestedType: "pdf", documentState: doc, redactionState: redaction)

        #expect(doc.phaseKind == .editing)
        let annotationCount = ImportAnnotationNoticeBanner.noticeWorthyCount(doc.sourceAnnotationFindings)
        #expect(ImportAnnotationNoticeBanner.isVisible(
            phaseKind: .editing, annotationTypeCount: annotationCount,
            filledFormFieldCount: doc.sourceFilledFormFieldCount, dismissed: false),
            "the import notice")
        #expect(ConcealingAnnotations.pages(
            in: doc.sourceDocument, regions: redaction.regions, textLayerStatus: doc.textLayerStatus) == [0],
            "the share confirm")
    }

    /// A field's rect over blank page space, below the printed line.
    private static let blankRect = "[300 400 500 424]"

    /// The I-9's shape: a combo-box choice field with a white background,
    /// over blank space (PDFKit drops a choice field with no `/Opt`).
    static let whiteFieldOverBlank = coveredPDF(
        "<< /Type /Annot /Subtype /Widget /FT /Ch /Ff 131072 /Opt [(CA) (NY)] /T (state) /Rect \(blankRect) /F 4 "
        + "/MK << /BG [1 1 1] >> /DA (/Helv 12 Tf 0 g) /P 3 0 R >>")

    /// The SF-2809's shape: a text field with a light-grey background, over blank space.
    static let greyFieldOverBlank = coveredPDF(
        "<< /Type /Annot /Subtype /Widget /FT /Tx /T (name) /Rect \(blankRect) /F 4 "
        + "/MK << /BG [0.85 0.85 0.85] >> /DA (/Helv 12 Tf 0 g) /P 3 0 R >>")

    /// A white-background field over the printed line: a white-out.
    static let whiteFieldOverText = coveredPDF(
        "<< /Type /Annot /Subtype /Widget /FT /Tx /T (cover) /Rect \(coverRect) /F 4 "
        + "/MK << /BG [1 1 1] >> /DA (/Helv 12 Tf 0 g) /P 3 0 R >>")

    @Test("An ordinary form's white or light-grey fields over blank space raise no import notice and no share confirm")
    func lightFieldsOverBlankStayQuiet() async throws {
        for (name, data) in [("white", Self.whiteFieldOverBlank), ("grey", Self.greyFieldOverBlank)] {
            let document = try document(data)
            #expect(ConcealingAnnotations.coverWidgetCount(in: document) == 0, "\(name)")
            #expect(ConcealingAnnotations.pages(in: document, regions: [:]).isEmpty, "\(name)")

            let doc = DocumentState()
            await ImportService.importDocument(
                data: data, suggestedType: "pdf", documentState: doc, redactionState: RedactionState())
            #expect(doc.phaseKind == .editing)
            let annotationCount = ImportAnnotationNoticeBanner.noticeWorthyCount(doc.sourceAnnotationFindings)
            #expect(!ImportAnnotationNoticeBanner.isVisible(
                phaseKind: .editing, annotationTypeCount: annotationCount,
                filledFormFieldCount: doc.sourceFilledFormFieldCount, dismissed: false),
                "\(name): no field lies over page content")
        }
    }

    @Test("A white field over text hides it, so it still counts; a black one over text still counts")
    func fieldsOverTextStillCount() throws {
        for (name, data) in [("white", Self.whiteFieldOverText), ("black", Self.blackBackgroundField)] {
            let document = try document(data)
            #expect(ConcealingAnnotations.coverWidgetCount(in: document) == 1, "\(name)")
            #expect(ConcealingAnnotations.pages(in: document, regions: [:]) == [0], "\(name)")
        }
    }

    @Test("A black watermark over text raises the import notice; an empty field raises nothing")
    func watermarkNoticeAndEmptyFieldQuiet() async throws {
        let doc = DocumentState()
        let redaction = RedactionState()
        await ImportService.importDocument(
            data: Self.blackWatermark, suggestedType: "pdf", documentState: doc, redactionState: redaction)
        #expect(ImportAnnotationNoticeBanner.noticeWorthyCount(doc.sourceAnnotationFindings) == 1)

        await ImportService.importDocument(
            data: Self.transparentField, suggestedType: "pdf", documentState: doc, redactionState: redaction)
        #expect(doc.sourceAnnotationFindings.isEmpty)
        #expect(doc.sourceFilledFormFieldCount == 0)
    }

    // MARK: - Helpers

    /// Objects numbered from 1 in order, a valid cross-reference table.
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
}
