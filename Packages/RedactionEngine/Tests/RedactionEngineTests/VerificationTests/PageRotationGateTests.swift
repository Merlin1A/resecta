import Testing
import Foundation
import PDFKit
import CoreGraphics
@testable import RedactionEngine

// A page `/Rotate` that is not a right angle is invalid (ISO 32000 §7.7.3.3)
// but still opens. PDFKit rounds it to the nearest quarter turn — the frame
// the editor, text extraction, search and every region use — while
// CoreGraphics keeps the raw value. Such a page is refused by the pre-flight
// before anything is rendered; the right-angle controls render, fill and
// verify; and a direct render follows PDFKit's frame, not the raw value.

@Suite("Page rotation gate", .tags(.security))
struct PageRotationGateTests {

    /// One 612 × 792 pt page carrying one line of synthetic text. `/Rotate`
    /// sits on the page dictionary, or on the parent `/Pages` node when
    /// `inherited` is set.
    static func rotatedPDF(rotate: String, inherited: Bool = false) -> Data {
        let content = "BT /F1 18 Tf 72 700 Td (SYNTHROT 900-00-0003) Tj ET"
        let pagesRotate = inherited ? " /Rotate \(rotate)" : ""
        let pageRotate = inherited ? "" : " /Rotate \(rotate)"
        return buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1\(pagesRotate) >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792]\(pageRotate) \
                /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>
                """),
            PDFObject(id: 4, content: "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"),
            PDFObject(id: 5, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"),
        ], rootId: 1)
    }

    static func openPage(rotate: String, inherited: Bool = false) throws -> PDFPage {
        let doc = try #require(PDFDocument(data: rotatedPDF(rotate: rotate, inherited: inherited)))
        return try #require(doc.page(at: 0))
    }

    static func pageData(
        _ page: PDFPage, regions: [RedactionRegion], fill: FillColor
    ) -> PDFPageData {
        PDFPageData(
            page: page, pageIndex: 0, regions: regions, fillColor: fill,
            targetDPI: 150, pipelineMode: .secureRasterization, rotation: page.rotation,
            cropBoxBounds: page.bounds(for: .cropBox), cgPage: page.pageRef,
            hasText: !(page.string ?? "").isEmpty)
    }

    /// A manual region over the text line, built the way the editor builds
    /// one: the extracted glyph boxes in PDFKit's frame, padded, normalised
    /// by the page's displayed size. Reads its own copy of the page.
    static func regionOverText(rotate: String) async throws -> RedactionRegion {
        let page = try openPage(rotate: rotate)
        let size = effectiveBounds(page.bounds(for: .cropBox), rotation: page.rotation).size
        let chars = try await TextLayerExtractor().extractCharacters(from: page)
        try #require(!chars.isEmpty, "the fixture's text line must extract")
        let union = chars.map(\.bounds).reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -6, dy: -6)
        let normalized = CGRect(
            x: union.minX / size.width, y: union.minY / size.height,
            width: union.width / size.width, height: union.height / size.height)
        return RedactionRegion(id: UUID(), normalizedRect: normalized, source: .manual)
    }

    /// Pixels whose red channel is below half intensity (the text is black
    /// on a white page).
    static func darkPixels(_ image: CGImage) -> Int {
        rgba(image).enumerated().reduce(0) { n, pair in
            pair.offset % 4 == 0 && pair.element < 128 ? n + 1 : n
        }
    }

    static func rgba(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        buffer.withUnsafeMutableBytes { raw in
            let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return buffer
    }

    static func expectRefused(_ page: PDFPage, _ label: String) async {
        #expect(validatePageGeometry(page) == false,
                "/Rotate \(label): the pre-flight must refuse the page")
        do {
            _ = try await PageRasterizer().rasterize(
                pageData(page, regions: [], fill: .black), dpiCap: 150)
            Issue.record("/Rotate \(label): rasterize rendered a page the pre-flight must refuse")
        } catch let error as PipelineError {
            guard case .redactionError(.unsupportedPageGeometry(let index)) = error else {
                Issue.record("/Rotate \(label): expected .unsupportedPageGeometry, got \(error)")
                return
            }
            #expect(index == 0)
        } catch {
            Issue.record("/Rotate \(label): unexpected error \(error)")
        }
    }

    // MARK: - The refusal

    @Test("A /Rotate that is not a right angle is refused before rendering",
          arguments: ["45", "135", "225", "315", "30"])
    func nonRightAngleRefused(_ rotate: String) async throws {
        await Self.expectRefused(try Self.openPage(rotate: rotate), rotate)
    }

    @Test("A /Rotate 45 inherited from the /Pages node is refused before rendering")
    func inheritedNonRightAngleRefused() async throws {
        await Self.expectRefused(try Self.openPage(rotate: "45", inherited: true), "45 (inherited)")
    }

    // MARK: - The right-angle controls

    @Test("A right-angle /Rotate renders, the fill covers the text, and verification passes",
          arguments: ["0", "90", "180", "270", "-90", "450"])
    func rightAngleFillsAndVerifies(_ rotate: String) async throws {
        let page = try Self.openPage(rotate: rotate)
        #expect(validatePageGeometry(page), "/Rotate \(rotate): the pre-flight must admit the page")
        let region = try await Self.regionOverText(rotate: rotate)

        // Coverage: an unfilled render shows the text; a white fill over the
        // region leaves no dark pixel on the page.
        let bare = try await PageRasterizer().rasterize(
            Self.pageData(page, regions: [], fill: .white), dpiCap: 150)
        let filled = try await PageRasterizer().rasterize(
            Self.pageData(page, regions: [region], fill: .white), dpiCap: 150)
        #expect(Self.darkPixels(bare.pageOutput.image) > 0, "/Rotate \(rotate): the text must render")
        #expect(Self.darkPixels(filled.pageOutput.image) == 0,
                "/Rotate \(rotate): the fill must cover every text pixel")

        // End to end: the production writer, then the verification run.
        let result = try await PageRasterizer().rasterize(
            Self.pageData(page, regions: [region], fill: .black), dpiCap: 150)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rotation_gate_\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = PDFStreamReconstructor(tempURL: url)
        try await writer.begin(firstPageSize: result.pageOutput.size)
        try await writer.appendPage(result.pageOutput)
        await writer.finalize()
        let output = try #require(PDFDocument(url: url))
        let report = try await VerificationOrchestrator().run(
            outputDocument: SendablePDFDocument(output), sourcePageCount: 1,
            regions: [0: [region]], sensitiveTerms: [], pipelineMode: .secureRasterization,
            filterDigests: [nil], perPageModes: [.secureRasterization],
            perPageFallbackReasons: [nil], appliedSearches: [],
            provisionLayerDocuments: { _ in nil }, events: { _ in })
        let rows = report.layers.map { "\($0.name)=\($0.status)" }.joined(separator: " | ")
        #expect(report.overallStatus == .pass, "/Rotate \(rotate): \(report.overallStatus) :: \(rows)")
    }

    @Test("A right-angle /Rotate inherited from the /Pages node is admitted")
    func inheritedRightAngleAdmitted() throws {
        let page = try Self.openPage(rotate: "90", inherited: true)
        #expect(page.rotation == 90)
        #expect(validatePageGeometry(page))
    }

    // MARK: - The render frame

    /// A direct render (the detection path renders without the pre-flight)
    /// follows PDFKit's rounded rotation: the page renders exactly like the
    /// same page carrying that right angle.
    @Test("A direct render of a non-right-angle page follows PDFKit's rotation",
          arguments: ["45", "135", "225", "315", "30"])
    func directRenderFollowsDisplayedRotation(_ rotate: String) async throws {
        let odd = try Self.openPage(rotate: rotate)
        let displayed = odd.rotation
        let control = try Self.openPage(rotate: String(displayed))
        let oddImage = try await PageRasterizer().renderPage(odd, pageIndex: 0, dpi: 150)
        let controlImage = try await PageRasterizer().renderPage(control, pageIndex: 0, dpi: 150)
        #expect(oddImage.width == controlImage.width && oddImage.height == controlImage.height)
        let differing = zip(Self.rgba(oddImage), Self.rgba(controlImage)).filter { $0 != $1 }.count
        #expect(differing == 0,
                "/Rotate \(rotate) (displayed \(displayed)): \(differing) bytes differ from the right-angle control")
    }
}
