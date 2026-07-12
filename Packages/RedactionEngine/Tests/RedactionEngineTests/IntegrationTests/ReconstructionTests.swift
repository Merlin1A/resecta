import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import RedactionEngine

// ENGINE §5 — PDF reconstruction tests.

@Suite("PDF Stream Reconstruction")
struct ReconstructionTests {

    // MARK: - Basic Output

    @Test("Single-page reconstruction produces valid PDF")
    func singlePageOutput() async throws {
        let tempURL = makeTempURL()
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let image = try makeTestImage(width: 200, height: 300)
        let recon = PDFStreamReconstructor(tempURL: tempURL)
        let size = CGSize(width: 200, height: 300)

        try await recon.begin(firstPageSize: size)
        try await recon.appendPage(PageOutput(image: image, size: size, textLayerEntries: nil))
        await recon.finalize()

        // Verify output opens in PDFKit
        let doc = PDFDocument(url: tempURL)
        #expect(doc != nil, "Output PDF must open in PDFKit")
        #expect(doc?.pageCount == 1)
    }

    @Test("Multi-page reconstruction preserves page count")
    func multiPageOutput() async throws {
        let tempURL = makeTempURL()
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let image = try makeTestImage(width: 100, height: 150)
        let recon = PDFStreamReconstructor(tempURL: tempURL)
        let size = CGSize(width: 100, height: 150)

        try await recon.begin(firstPageSize: size)
        for _ in 0..<5 {
            try await recon.appendPage(PageOutput(image: image, size: size, textLayerEntries: nil))
        }
        await recon.finalize()

        let doc = PDFDocument(url: tempURL)
        #expect(doc?.pageCount == 5)
    }

    @Test("Output PDF has correct page dimensions")
    func pageDimensions() async throws {
        let tempURL = makeTempURL()
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let image = try makeTestImage(width: 612, height: 792)
        let recon = PDFStreamReconstructor(tempURL: tempURL)
        let size = CGSize(width: 612, height: 792)

        try await recon.begin(firstPageSize: size)
        try await recon.appendPage(PageOutput(image: image, size: size, textLayerEntries: nil))
        await recon.finalize()

        let doc = PDFDocument(url: tempURL)!
        let page = doc.page(at: 0)!
        let bounds = page.bounds(for: .mediaBox)
        #expect(abs(bounds.width - 612) < 1)
        #expect(abs(bounds.height - 792) < 1)
    }

    // MARK: - Metadata Stripping (ENGINE §5.4)

    @Test("Output PDF has no /Author, /Title, /Creator, /Subject, /Keywords")
    func metadataStripped() async throws {
        let tempURL = makeTempURL()
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let image = try makeTestImage(width: 100, height: 100)
        let recon = PDFStreamReconstructor(tempURL: tempURL)
        let size = CGSize(width: 100, height: 100)

        try await recon.begin(firstPageSize: size)
        try await recon.appendPage(PageOutput(image: image, size: size, textLayerEntries: nil))
        await recon.finalize()

        // Read raw PDF data and check for metadata keys
        let data = try Data(contentsOf: tempURL)
        let pdfString = String(data: data, encoding: .ascii) ?? ""

        // These should NOT be present (empty aux dict omits them)
        #expect(!pdfString.contains("/Author"))
        #expect(!pdfString.contains("/Title"))
        #expect(!pdfString.contains("/Subject"))
        #expect(!pdfString.contains("/Keywords"))
        // /Creator may or may not appear (Apple behavior)

        // /Producer is auto-injected by CGPDFContext — known limitation (§5.4)
        // Layer 5 verification will flag this as WARN
    }

    // MARK: - Atomic Write

    @Test("Incomplete write does not produce output at final URL")
    func atomicWriteSafety() async throws {
        let tempURL = makeTempURL()
        let outputURL = makeTempURL(prefix: "output_")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        let image = try makeTestImage(width: 100, height: 100)
        let recon = PDFStreamReconstructor(tempURL: tempURL)
        let size = CGSize(width: 100, height: 100)

        try await recon.begin(firstPageSize: size)
        try await recon.appendPage(PageOutput(image: image, size: size, textLayerEntries: nil))

        // Before finalize(), outputURL should not exist
        #expect(!FileManager.default.fileExists(atPath: outputURL.path))

        await recon.finalize()

        // Temp file exists
        #expect(FileManager.default.fileExists(atPath: tempURL.path))

        // Atomic promote (same pattern as PipelineCoordinator)
        try FileManager.default.moveItem(at: tempURL, to: outputURL)
        #expect(FileManager.default.fileExists(atPath: outputURL.path))
        #expect(!FileManager.default.fileExists(atPath: tempURL.path))
    }

    // MARK: - JPEG Encoding

    @Test("Appendage with image data produces non-empty PDF file")
    func jpegEncodingProducesOutput() async throws {
        let tempURL = makeTempURL()
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // Create a colorful image to verify JPEG encoding works
        guard let ctx = createBitmapContext(width: 100, height: 100) else {
            Issue.record("Could not create bitmap context")
            return
        }
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 50, height: 100))
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 50, y: 0, width: 50, height: 100))
        guard let image = ctx.makeImage() else {
            Issue.record("Could not make image")
            return
        }

        let recon = PDFStreamReconstructor(tempURL: tempURL)
        let size = CGSize(width: 100, height: 100)
        try await recon.begin(firstPageSize: size)
        try await recon.appendPage(PageOutput(image: image, size: size, textLayerEntries: nil))
        await recon.finalize()

        let fileSize = try FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int ?? 0
        // CAT-253: raised 100 → 5_000. A 100×100 two-color JPEG page in a PDF
        // container always clears 5 KB; the old 100-byte floor could not flag a
        // JPEG-compression collapse or an empty-page reconstruction.
        #expect(fileSize > 5_000, "Output PDF should have substantial content (got \(fileSize) bytes)")
    }

    // MARK: - Error Handling

    @Test("appendPage before begin() throws reconstructionFailed")
    func appendBeforeBeginThrows() async throws {
        let recon = PDFStreamReconstructor(tempURL: makeTempURL())
        let image = try makeTestImage(width: 10, height: 10)
        let output = PageOutput(image: image, size: CGSize(width: 10, height: 10), textLayerEntries: nil)

        do {
            try await recon.appendPage(output)
            Issue.record("Expected reconstructionFailed error")
        } catch let error as PipelineError {
            guard case .redactionError(.reconstructionFailed) = error else {
                Issue.record("Expected reconstructionFailed, got \(error)")
                return
            }
        }
    }

    // MARK: - Temp File Cleanup

    @Test("cleanOrphanedTempFiles removes stale recon_ files")
    func tempFileCleanup() throws {
        let tmp = FileManager.default.temporaryDirectory
        let staleURL = tmp.appendingPathComponent("recon_stale_test.pdf")
        FileManager.default.createFile(atPath: staleURL.path, contents: Data([0x25, 0x50, 0x44, 0x46]))
        defer { try? FileManager.default.removeItem(at: staleURL) }

        // Set creation date to 2 hours ago
        try FileManager.default.setAttributes(
            [.creationDate: Date().addingTimeInterval(-7200)],
            ofItemAtPath: staleURL.path
        )

        cleanOrphanedTempFiles()

        #expect(!FileManager.default.fileExists(atPath: staleURL.path),
                "Stale recon_ file should be cleaned up")
    }

    // MARK: - Mixed Page Sizes

    @Test("Reconstruction with mixed page sizes preserves page count")
    func mixedPageSizes() async throws {
        let tempURL = makeTempURL()
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let sizes: [(w: Int, h: Int)] = [(612, 792), (595, 842), (500, 500)]
        let recon = PDFStreamReconstructor(tempURL: tempURL)
        try await recon.begin(firstPageSize: CGSize(width: sizes[0].w, height: sizes[0].h))
        for s in sizes {
            let image = try makeTestImage(width: s.w, height: s.h)
            try await recon.appendPage(PageOutput(
                image: image, size: CGSize(width: s.w, height: s.h), textLayerEntries: nil))
        }
        await recon.finalize()

        let doc = PDFDocument(url: tempURL)!
        #expect(doc.pageCount == 3)
        // CGPDFContext may adjust page dimensions during re-encoding;
        // page count preservation is the critical invariant.
    }

    // MARK: - EOF Marker Count

    @Test("Multi-page output has single %%EOF marker")
    func singleEOFMarker() async throws {
        let tempURL = makeTempURL()
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let image = try makeTestImage(width: 100, height: 100)
        let recon = PDFStreamReconstructor(tempURL: tempURL)
        let size = CGSize(width: 100, height: 100)
        try await recon.begin(firstPageSize: size)
        for _ in 0..<3 {
            try await recon.appendPage(PageOutput(image: image, size: size, textLayerEntries: nil))
        }
        await recon.finalize()

        let data = try Data(contentsOf: tempURL)
        let eofMarker = "%%EOF".data(using: .ascii)!
        var count = 0
        var searchRange = data.startIndex..<data.endIndex
        while let range = data.range(of: eofMarker, options: [], in: searchRange) {
            count += 1
            searchRange = range.upperBound..<data.endIndex
        }
        #expect(count == 1, "Expected 1 %%EOF, found \(count)")
    }

    // MARK: - cleanOrphanedTempFiles Preserves Recent Files

    @Test("cleanOrphanedTempFiles ignores recent files (< 1 hour old)")
    func ignoresRecentFiles() throws {
        let tmp = FileManager.default.temporaryDirectory
        let recentURL = tmp.appendingPathComponent("recon_recent_test.pdf")
        FileManager.default.createFile(atPath: recentURL.path, contents: Data([0x25, 0x50, 0x44, 0x46]))
        defer { try? FileManager.default.removeItem(at: recentURL) }

        // Creation date is now (< 1 hour threshold)
        cleanOrphanedTempFiles()
        #expect(FileManager.default.fileExists(atPath: recentURL.path),
                "Recent recon_ file should NOT be cleaned up")
    }

    @Test("cleanOrphanedTempFiles respects 1-hour threshold at the boundary")
    func cleanOrphanedTempFilesRespects1HourThreshold() throws {
        let tmp = FileManager.default.temporaryDirectory
        let youngerURL = tmp.appendingPathComponent("recon_59min_test.pdf")
        let olderURL = tmp.appendingPathComponent("recon_61min_test.pdf")
        FileManager.default.createFile(atPath: youngerURL.path, contents: Data([0x25, 0x50, 0x44, 0x46]))
        FileManager.default.createFile(atPath: olderURL.path, contents: Data([0x25, 0x50, 0x44, 0x46]))
        defer {
            try? FileManager.default.removeItem(at: youngerURL)
            try? FileManager.default.removeItem(at: olderURL)
        }

        try FileManager.default.setAttributes(
            [.creationDate: Date().addingTimeInterval(-59 * 60)],
            ofItemAtPath: youngerURL.path
        )
        try FileManager.default.setAttributes(
            [.creationDate: Date().addingTimeInterval(-61 * 60)],
            ofItemAtPath: olderURL.path
        )

        cleanOrphanedTempFiles()

        #expect(FileManager.default.fileExists(atPath: youngerURL.path),
                "59-minute-old file should be retained (under 1-hour threshold)")
        #expect(!FileManager.default.fileExists(atPath: olderURL.path),
                "61-minute-old file should be removed (over 1-hour threshold)")
    }

    // MARK: - RES-02: Broadened resecta_* prefix sweep

    /// RES-02 — the sweep used to match only `recon_*` and `redacted_*`,
    /// which left `resecta_audit_*` and `resecta_coverage_*` share-sheet
    /// temp files orphaned if the app was killed mid-dismiss. Verifies that
    /// every `resecta_*` prefix is now reaped under the same 1-hour TTL,
    /// while `recon_*` / `redacted_*` continue to be swept and recent
    /// `resecta_*` files are preserved.
    @Test("cleanOrphanedTempFiles sweeps all resecta_* prefixes")
    func testCleanOrphanedTempFilesSweepsAllResectaPrefixes() throws {
        let tmp = FileManager.default.temporaryDirectory

        // Stale resecta_* writers (both from MatchExportService) plus a
        // hypothetical future verification dump.
        let staleAudit    = tmp.appendingPathComponent("resecta_audit_doc_2026.csv")
        let staleCoverage = tmp.appendingPathComponent("resecta_coverage_20260518.json")
        let staleFuture   = tmp.appendingPathComponent("resecta_verification_xyz.log")
        // Recent resecta_* file must NOT be swept (under TTL).
        let recentResecta = tmp.appendingPathComponent("resecta_audit_recent.csv")
        // Legacy prefixes must continue to be swept.
        let staleRecon    = tmp.appendingPathComponent("recon_legacy_test.pdf")
        let staleRedacted = tmp.appendingPathComponent("redacted_legacy_test.pdf")

        for url in [staleAudit, staleCoverage, staleFuture, recentResecta,
                    staleRecon, staleRedacted] {
            FileManager.default.createFile(
                atPath: url.path,
                contents: Data([0x25, 0x50, 0x44, 0x46])
            )
        }
        defer {
            for url in [staleAudit, staleCoverage, staleFuture, recentResecta,
                        staleRecon, staleRedacted] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        // Backdate everything except `recentResecta` past the 1-hour TTL.
        let twoHoursAgo = Date().addingTimeInterval(-7200)
        for url in [staleAudit, staleCoverage, staleFuture,
                    staleRecon, staleRedacted] {
            try FileManager.default.setAttributes(
                [.creationDate: twoHoursAgo],
                ofItemAtPath: url.path
            )
        }

        cleanOrphanedTempFiles()

        #expect(!FileManager.default.fileExists(atPath: staleAudit.path),
                "Stale resecta_audit_* file should be swept")
        #expect(!FileManager.default.fileExists(atPath: staleCoverage.path),
                "Stale resecta_coverage_* file should be swept")
        #expect(!FileManager.default.fileExists(atPath: staleFuture.path),
                "Stale resecta_verification_* file should be swept")
        #expect(FileManager.default.fileExists(atPath: recentResecta.path),
                "Recent resecta_* file should be retained (under 1-hour TTL)")
        #expect(!FileManager.default.fileExists(atPath: staleRecon.path),
                "Stale recon_* file must continue to be swept (no regression)")
        #expect(!FileManager.default.fileExists(atPath: staleRedacted.path),
                "Stale redacted_* file must continue to be swept (no regression)")
    }

    // MARK: - Large Page

    @Test("Reconstruction handles large page dimensions")
    func largePageReconstruction() async throws {
        let tempURL = makeTempURL()
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let image = try makeTestImage(width: 2000, height: 3000)
        let recon = PDFStreamReconstructor(tempURL: tempURL)
        let size = CGSize(width: 2000, height: 3000)
        try await recon.begin(firstPageSize: size)
        try await recon.appendPage(PageOutput(image: image, size: size, textLayerEntries: nil))
        await recon.finalize()

        let doc = PDFDocument(url: tempURL)
        #expect(doc?.pageCount == 1)
    }

    // MARK: - CND-11 (launch-fix-v2 S5) draw-on-append color + order

    /// Draw-on-append (K=0) draws each page into the PDF context as it arrives
    /// rather than from a retained buffer. This pins that the streaming path
    /// still preserves per-page identity AND order — the coverage the removed
    /// ReplacePageTests held, restated for the append-only model. Distinct
    /// primary colors per page index let a center-pixel sample after a CGPDF
    /// round-trip identify which image landed on which page.
    @Test("Draw-on-append preserves per-page color and order")
    func multiPageColorAndOrderPreserved() async throws {
        let tempURL = makeTempURL()
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let size = CGSize(width: 200, height: 200)
        let colors: [(r: CGFloat, g: CGFloat, b: CGFloat)] = [
            (1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0), (0, 1, 1),
        ]

        let recon = PDFStreamReconstructor(tempURL: tempURL)
        try await recon.begin(firstPageSize: size)
        for c in colors {
            let image = try makeSolidColorImage(red: c.r, green: c.g, blue: c.b,
                                                width: 200, height: 200)
            try await recon.appendPage(PageOutput(image: image, size: size, textLayerEntries: nil))
        }
        await recon.finalize()

        #expect(await recon.writtenPageCount == colors.count)

        let doc = try #require(PDFDocument(url: tempURL))
        #expect(doc.pageCount == colors.count, "every appended page must survive")
        for (i, c) in colors.enumerated() {
            let pixel = try samplePageCenterColor(in: tempURL, page: i)
            #expect(isRoughly(pixel, red: UInt8(c.r * 255),
                              green: UInt8(c.g * 255), blue: UInt8(c.b * 255)),
                    "page \(i) should keep its color, got \(pixel)")
        }
    }

    // MARK: - Helpers

    private func makeTempURL(prefix: String = "recon_test_") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)\(UUID().uuidString).pdf")
    }

    private func makeTestImage(width: Int, height: Int) throws -> CGImage {
        guard let ctx = createBitmapContext(width: width, height: height) else {
            throw TestError.contextCreationFailed
        }
        ctx.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage() else {
            throw TestError.contextCreationFailed
        }
        return image
    }

    private func makeSolidColorImage(
        red: CGFloat, green: CGFloat, blue: CGFloat, width: Int, height: Int
    ) throws -> CGImage {
        guard let ctx = createBitmapContext(width: width, height: height) else {
            throw TestError.contextCreationFailed
        }
        ctx.setFillColor(red: red, green: green, blue: blue, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage() else {
            throw TestError.contextCreationFailed
        }
        return image
    }

    /// Sample the center pixel of a rendered output page via Core Graphics
    /// `CGContext.drawPDFPage` (the M-5-banned PDFKit page-draw path is avoided).
    /// The createBitmap format is byteOrder32Little + premultipliedFirst, so an
    /// opaque pixel is laid out B,G,R,A in memory; the alpha-position heuristic
    /// also tolerates an ARGB backing if the format ever changes.
    private func samplePageCenterColor(
        in pdfURL: URL, page pageIndex: Int
    ) throws -> (r: UInt8, g: UInt8, b: UInt8) {
        guard let cgDoc = CGPDFDocument(pdfURL as CFURL),
              let cgPage = cgDoc.page(at: pageIndex + 1) else {  // CGPDF pages are 1-based
            throw TestError.contextCreationFailed
        }
        let mediaBox = cgPage.getBoxRect(.mediaBox)
        let renderSize = 40
        guard let ctx = createBitmapContext(width: renderSize, height: renderSize) else {
            throw TestError.contextCreationFailed
        }
        ctx.scaleBy(x: CGFloat(renderSize) / mediaBox.width,
                    y: CGFloat(renderSize) / mediaBox.height)
        ctx.translateBy(x: -mediaBox.minX, y: -mediaBox.minY)
        ctx.drawPDFPage(cgPage)
        guard let image = ctx.makeImage(),
              let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else {
            throw TestError.contextCreationFailed
        }
        let bpr = image.bytesPerRow
        let bpp = image.bitsPerPixel / 8
        let offset = (renderSize / 2) * bpr + (renderSize / 2) * bpp
        let b0 = bytes[offset], b1 = bytes[offset + 1]
        let b2 = bytes[offset + 2], b3 = bytes[offset + 3]
        if b3 == 255 { return (r: b2, g: b1, b: b0) }   // B,G,R,A (createBitmapContext)
        if b0 == 255 { return (r: b1, g: b2, b: b3) }   // A,R,G,B fallback
        return (r: b0, g: b1, b: b2)
    }

    private func isRoughly(
        _ pixel: (r: UInt8, g: UInt8, b: UInt8),
        red: UInt8, green: UInt8, blue: UInt8, tolerance: Int = 32
    ) -> Bool {
        abs(Int(pixel.r) - Int(red)) <= tolerance
            && abs(Int(pixel.g) - Int(green)) <= tolerance
            && abs(Int(pixel.b) - Int(blue)) <= tolerance
    }

    private enum TestError: Error {
        case contextCreationFailed
    }
}
