import Testing
import Foundation
import PDFKit
@testable import ResectaApp
@testable import RedactionEngine

// Import annotation notice — the import path runs the engine's
// `AnnotationAnalyzer` over the validated document and stages its
// results on `DocumentState`; `DocumentEditorView` surfaces them as a
// banner while editing. These pins cover the app-side wiring: an
// annotated source stages results, clean sources stage nothing, the
// visibility contract, and the mechanism copy. Subtype filtering
// (Widget skip, black-square classification) is the engine's contract,
// pinned in the engine's own `AnnotationAnalyzerTests`.

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
