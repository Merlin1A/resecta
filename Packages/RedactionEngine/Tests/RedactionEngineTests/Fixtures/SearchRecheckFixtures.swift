import Foundation
import PDFKit
import CoreGraphics
import CoreText
import UIKit
@testable import RedactionEngine

// Fixtures and runners shared by the Search Re-check suites
// (`SearchRecheckTests`, `SearchRecheckOCRTests`, `SearchRecheckParallelismTests`).
// Every value here is synthetic and public (fixture vocabulary from the
// sample statement's disclosed manifest), so diagnostics may print counts.

extension TestFixtures {

    enum RecheckFixtureError: Error { case failed }

    // MARK: - Runner

    /// Run the Search Re-check layer through the engine's primary entry on
    /// `doc` (its own instance), every page in `mode`.
    static func recheck(
        _ doc: SendablePDFDocument,
        requests: [SearchRecheckRequest],
        mode: PipelineMode = .searchableRedaction
    ) async -> LayerResult {
        let n = doc.document.pageCount
        return await VerificationEngine().runLayer(
            .searchRecheck,
            outputDocument: doc,
            sourcePageCount: n,
            regions: [:],
            sensitiveTerms: [],
            pipelineMode: mode,
            filterDigests: Array(repeating: nil, count: n),
            perPageModes: Array(repeating: mode, count: n),
            appliedSearches: requests
        )
    }

    /// The human-readable string of a warn/info/attention/fail status
    /// (`VerificationStatus ==` compares case identity only).
    static func message(of status: VerificationStatus) -> String? {
        switch status {
        case .warn(let m), .info(let m), .attention(let m), .fail(let m): m
        case .pass, .skipped: nil
        }
    }

    // MARK: - Requests

    static func textRequest(
        _ query: String, options: SearchOptions = SearchOptions(),
        found: Int = 1, applied: Int = 1, pages: Set<Int> = [0],
        pageBound: Bool = false
    ) -> SearchRecheckRequest {
        SearchRecheckRequest(
            record: AppliedSearchRecord(
                query: AppliedSearchQuery(kind: .text(query), options: options),
                foundCount: found),
            appliedCount: applied, appliedPages: pages, pageBound: pageBound)
    }

    static func regexRequest(
        _ pattern: String, options: SearchOptions = SearchOptions(),
        found: Int = 1, applied: Int = 1, pages: Set<Int> = [0]
    ) -> SearchRecheckRequest {
        SearchRecheckRequest(
            record: AppliedSearchRecord(
                query: AppliedSearchQuery(kind: .regex(pattern), options: options),
                foundCount: found),
            appliedCount: applied, appliedPages: pages)
    }

    static func multiTermRequest(
        _ terms: [String], options: SearchOptions = SearchOptions(),
        found: Int = 1, applied: Int = 1, pages: Set<Int> = [0]
    ) -> SearchRecheckRequest {
        SearchRecheckRequest(
            record: AppliedSearchRecord(
                query: AppliedSearchQuery(kind: .multiTerm(terms), options: options),
                foundCount: found),
            appliedCount: applied, appliedPages: pages)
    }

    // MARK: - Text-layer fixtures

    /// Multi-page text-layer PDF, one string per page (real text layer via
    /// UIGraphicsPDFRenderer — the `textLayerPDF` shape, N pages).
    static func textPagesPDF(_ pages: [String], fontSize: CGFloat = 24) -> Data {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize),
            .foregroundColor: UIColor.black,
        ]
        return renderer.pdfData { context in
            for text in pages {
                context.beginPage()
                (text as NSString).draw(
                    in: CGRect(x: 72, y: 72, width: 468, height: 648),
                    withAttributes: attrs)
            }
        }
    }

    /// Three-page raw PDF whose page tree names a second kid that does not
    /// exist: pages 1 and 3 carry `term` in a text-show stream; PDFKit
    /// reports three pages and cannot open the second.
    static func brokenSecondPagePDF(term: String) -> Data {
        let stream = "BT /F1 24 Tf 100 700 Td (\(term)) Tj ET"
        let textPageBody = """
            << /Type /Page /Parent 2 0 R \
            /MediaBox [0 0 612 792] \
            /Contents 6 0 R \
            /Resources << /Font << /F1 8 0 R >> >> >>
            """
        return buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>"),
            PDFObject(id: 3, content: textPageBody),
            PDFObject(id: 5, content: textPageBody),
            PDFObject(id: 6, content: """
                << /Length \(stream.utf8.count) >>
                stream
                \(stream)
                endstream
                """),
            PDFObject(id: 8, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"),
        ], rootId: 1)
    }

    // MARK: - Raster fixtures (the Layer-2 parallelism suite's shape)

    /// A single large word in black on white, rendered through the
    /// production bottom-left bitmap context so OCR sees the orientation a
    /// rasterized page carries.
    static func renderedTextImage(
        _ s: String, width: Int, height: Int, fontSize: CGFloat
    ) throws -> CGImage {
        guard let ctx = createBitmapContext(width: width, height: height) else {
            throw RecheckFixtureError.failed
        }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.textMatrix = .identity
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attr = NSAttributedString(
            string: s,
            attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
        let line = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = CGPoint(x: CGFloat(width) * 0.04, y: CGFloat(height) * 0.5)
        CTLineDraw(line, ctx)
        guard let img = ctx.makeImage() else { throw RecheckFixtureError.failed }
        return img
    }

    /// An N-page image-only PDF from CGImages through the production
    /// reconstructor — the full-page-JPEG shape Secure Rasterization output
    /// carries (no text layer on any page).
    static func imagePagesPDF(
        _ images: [CGImage], size: CGSize, prefix: String = "recheck_"
    ) async throws -> (PDFDocument, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)\(UUID().uuidString).pdf")
        let recon = PDFStreamReconstructor(tempURL: url)
        try await recon.begin(firstPageSize: size)
        for image in images {
            try await recon.appendPage(PageOutput(image: image, size: size, textLayerEntries: nil))
        }
        await recon.finalize()
        guard let doc = PDFDocument(url: url) else { throw RecheckFixtureError.failed }
        return (doc, url)
    }
}
