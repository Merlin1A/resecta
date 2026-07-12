import Testing
import Foundation
import PDFKit
import UIKit
import CoreGraphics
@testable import ResectaApp
@testable import RedactionEngine

// CAT-217 — PipelineCoordinator security-path coverage.
//
// The engine's PixelDestructionTests exercise fill/verify on a bare CGContext
// via TestPipeline, deliberately sidestepping PipelineCoordinator (the
// app-target orchestrator that selects the mode, wires the regions, and decides
// the Searchable↔Secure fallback). No prior test drove the *production*
// coordinator entry point (`runFullPipeline`) and then sampled the *output PDF*
// for pixel destruction — so a regression in coordinator flag/region wiring
// would pass every engine security test with a green bar. This suite closes
// that gap end-to-end.
//
// The output is JPEG-encoded (secure rasterization re-encodes each page), so
// the engine's exact BGRA(0,0,0,255) verifyFill cannot be reused on the decoded
// pixels. The test instead classifies pixels with tolerance and asserts the
// SHAPE of the redaction in the rendered output: a black blob of about the
// region's area, horizontally aligned to the region's x-span, with the light
// background surviving elsewhere. Production already verifies the exact
// pre-JPEG fill internally (a mis-wired region/mode either throws
// fillVerificationFailed — no outputURL — or lands the fill in the wrong place,
// which the shape assertions flag). Output rendering uses PDFPage.thumbnail —
// NOT PDFPage.draw(), which carries the double-offset bug per CLAUDE.md.
@Suite("PipelineCoordinator security path (coordinator wiring)", .tags(.critical, .coordination))
@MainActor
struct PipelineCoordinatorSecurityTests {

    @Test(
        "Coordinator runFullPipeline pixel-destroys every redaction region in the output (CAT-217)",
        .timeLimit(.minutes(3))
    )
    func testCoordinatorPathFillsRegionsPixelDestructively() async throws {
        let pageCount = 3
        // Solid-white pages: a black fill band on the output proves the
        // coordinator drove a destructive fill, and a still-light background
        // proves the rest of the page survived (no over-redaction).
        let doc = makeWhiteBackgroundPDF(pages: pageCount)
        let coord = makeLoadedCoordinator(document: doc)
        addRegionToAllPages(coord, pageCount: pageCount)   // region at (0.1, 0.1, 0.4, 0.04)

        coord.runFullPipeline(documentOverride: .secureRasterization)
        await coord.documentState.activePipelineTask?.value

        guard let outputURL = coord.redactionState.outputURL else {
            // CAT-229 precedent: surface the no-output path rather than bare-return
            // (a bare return would pass with zero pixel assertions).
            Issue.record("outputURL was nil — coordinator did not produce output; pixel destruction was never asserted")
            return
        }
        defer { try? FileManager.default.removeItem(at: outputURL) }
        guard let outputDoc = PDFDocument(url: outputURL) else {
            Issue.record("Failed to load coordinator output PDF")
            return
        }
        #expect(outputDoc.pageCount == pageCount)

        // The region is at normalized x∈[0.1,0.5], a thin band (height 0.04) —
        // ~1.6% of the page. The output is JPEG-encoded, so the engine's exact
        // BGRA(0,0,0,255) verifyFill cannot be reused here (JPEG ringing means
        // no decoded pixel is byte-exact black). Instead, classify pixels with
        // tolerance and assert the *shape* of the result: a black blob of about
        // the region's area, horizontally aligned to the region's x-span, with
        // the light background surviving everywhere else. (Production already
        // verifies the exact pre-JPEG fill internally; a mis-wired region/mode
        // would either throw fillVerificationFailed — no outputURL — or land
        // the fill in the wrong place, which the shape assertions below flag.)
        for i in 0..<pageCount {
            guard let page = outputDoc.page(at: i) else {
                Issue.record("Output page \(i) missing"); continue
            }
            guard let ctx = renderToBitmapContext(page, scale: 2.0), let data = ctx.data else {
                Issue.record("Could not rasterize output page \(i) for sampling"); continue
            }
            // createBitmapContext is BGRA with memory row 0 = top, col 0 = left
            // (verifyFill's row-flip convention). x maps directly (no flip), so
            // column position is a flip-invariant location signal.
            let w = ctx.width, h = ctx.height, bpr = ctx.bytesPerRow
            let buf = data.assumingMemoryBound(to: UInt8.self)
            var darkCount = 0, lightCount = 0
            var dMinCol = w, dMaxCol = 0, dMinRow = h, dMaxRow = 0
            for row in 0..<h {
                let rowBase = row * bpr
                for col in 0..<w {
                    let off = rowBase + col * 4
                    let b = buf[off], g = buf[off + 1], r = buf[off + 2]
                    if r < 70 && g < 70 && b < 70 {
                        darkCount += 1
                        if col < dMinCol { dMinCol = col }
                        if col > dMaxCol { dMaxCol = col }
                        if row < dMinRow { dMinRow = row }
                        if row > dMaxRow { dMaxRow = row }
                    } else if r > 180 && g > 180 && b > 180 {
                        lightCount += 1
                    }
                }
            }
            let total = w * h

            // Positive: a black blob of roughly the region's area is present —
            // the coordinator drove a destructive fill into the output.
            #expect(darkCount >= total / 500,
                    "Page \(i): redaction region must be pixel-destroyed — expected a black blob in the coordinator output (got \(darkCount)/\(total) dark px)")
            // Safety: nowhere near whole-page black — only the region was filled.
            #expect(darkCount <= total / 8,
                    "Page \(i): coordinator must not over-redact — too much of the page is black (got \(darkCount)/\(total) dark px)")
            // Content preserved: the light background survives outside the region.
            #expect(lightCount >= total / 2,
                    "Page \(i): background must survive outside the region (got \(lightCount)/\(total) light px)")
            // Location (x is flip-invariant): the black blob sits within the
            // region's horizontal span [0.1, 0.5] (+ margin), not smeared across
            // the page, and is a thin band matching the region height (0.04).
            if darkCount > 0 {
                let minXN = Double(dMinCol) / Double(w)
                let maxXN = Double(dMaxCol) / Double(w)
                #expect(minXN >= 0.05 && maxXN <= 0.55,
                        "Page \(i): black fill must align horizontally with the region span [0.1,0.5] (got x∈[\(minXN), \(maxXN)])")
                let yExtent = Double(dMaxRow - dMinRow) / Double(h)
                #expect(yExtent <= 0.12,
                        "Page \(i): black fill must be a thin band matching the region height 0.04 (got y-extent \(yExtent))")
            }
        }
    }

    @Test(
        "Coordinator secure-rasterization output exposes no extractable text layer (CAT-217)",
        .timeLimit(.minutes(3))
    )
    func testCoordinatorPathDoesNotLeakTextInRegions() async throws {
        let pageCount = 3
        let token = "ResectaCanaryToken-A1B2C3"   // synthetic marker, not PII
        let doc = makeTokenTextPDF(pages: pageCount, token: token)
        let coord = makeLoadedCoordinator(document: doc)
        addRegionToAllPages(coord, pageCount: pageCount)

        coord.runFullPipeline(documentOverride: .secureRasterization)
        await coord.documentState.activePipelineTask?.value

        guard let outputURL = coord.redactionState.outputURL else {
            Issue.record("outputURL was nil — coordinator did not produce output; the text-leak guard was never asserted")
            return
        }
        defer { try? FileManager.default.removeItem(at: outputURL) }
        guard let outputDoc = PDFDocument(url: outputURL) else {
            Issue.record("Failed to load coordinator output PDF")
            return
        }
        #expect(outputDoc.pageCount == pageCount)

        // Secure rasterization re-renders each page to an image, so the output
        // carries no text layer and the seeded token cannot survive as
        // extractable text. Boolean assertions only — never interpolate page
        // text into output (ARCH §12.2 / protocol §10).
        for i in 0..<pageCount {
            guard let page = outputDoc.page(at: i) else {
                Issue.record("Output page \(i) missing"); continue
            }
            let extracted = page.string ?? ""
            #expect(!extracted.contains(token),
                    "Page \(i): secure-rasterization output must expose no extractable text from the source")
            #expect(extracted.isEmpty,
                    "Page \(i): secure-rasterization output must carry no text layer at all")
        }
    }

    // MARK: - Helpers (private)

    // Replicated from PageParallelRasterizationTests (those helpers are private
    // to that suite). A coordinator with a loaded source document, parked in the
    // .editing phase so runFullPipeline can drive it forward.
    private func makeLoadedCoordinator(document: PDFDocument) -> PipelineCoordinator {
        let coord = PipelineCoordinator(
            documentState: DocumentState(),
            redactionState: RedactionState(),
            settingsState: SettingsState()
        )
        coord.documentState.sourceDocument = document
        coord.documentState.phase = .editing
        // Pin the fill color deterministically: SettingsState reads `fillColor`
        // from UserDefaults at init, so a persisted "white" from an earlier run
        // in the same process would make a black-on-white pixel check invisible.
        coord.settingsState.fillColor = .black
        return coord
    }

    private func addRegionToAllPages(_ coord: PipelineCoordinator, pageCount: Int) {
        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.04),
            source: .manual
        )
        for i in 0..<pageCount {
            coord.redactionState.regions[i] = [region]
        }
    }

    /// Solid-white pages (the canonical pixel-destruction fixture, matching the
    /// engine's PixelDestructionTests background). Black-on-white survives JPEG
    /// re-encoding cleanly — neutral chroma means the filled band stays
    /// near-black, unlike black-on-saturated-color where 4:2:0 chroma
    /// subsampling bleeds the surround into the band.
    private func makeWhiteBackgroundPDF(pages: Int) -> PDFDocument {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let data = renderer.pdfData { ctx in
            for _ in 0..<pages {
                ctx.beginPage()
                ctx.cgContext.setFillColor(UIColor(red: 1, green: 1, blue: 1, alpha: 1).cgColor)
                ctx.cgContext.fill(pageRect)
            }
        }
        return PDFDocument(data: data)!
    }

    /// White pages stamped with a synthetic canary token so the text-leak guard
    /// has extractable text that must not survive rasterization.
    private func makeTokenTextPDF(pages: Int, token: String) -> PDFDocument {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let data = renderer.pdfData { ctx in
            for _ in 0..<pages {
                ctx.beginPage()
                let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 18)]
                (token as NSString).draw(at: CGPoint(x: 72, y: 96), withAttributes: attrs)
            }
        }
        return PDFDocument(data: data)!
    }

    /// Rasterize a PDF page into an engine-style bottom-left-origin bitmap
    /// context for pixel sampling. Uses thumbnail (NOT PDFPage.draw(), per
    /// CLAUDE.md). The context retains its backing buffer, so the returned
    /// context is safe to sample via verifyFill while it stays in scope.
    private func renderToBitmapContext(_ page: PDFPage, scale: CGFloat) -> CGContext? {
        let box = PDFDisplayBox.mediaBox
        let bounds = page.bounds(for: box)
        let pixelSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let thumb = page.thumbnail(of: pixelSize, for: box)
        guard let cg = thumb.cgImage else { return nil }
        guard let ctx = createBitmapContext(width: cg.width, height: cg.height) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return ctx
    }
}
