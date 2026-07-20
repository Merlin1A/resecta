import Testing
import PDFKit
import CoreGraphics
@testable import RedactionEngine

// Tests for ENGINE §6.6 — Sandwich-specific verification layers 6–8.

@Suite("Sandwich Verification", .tags(.security))
struct SandwichVerificationTests {

    let verifier = SandwichVerification()

    // MARK: - Layer 6: Spatial Exclusion (ENGINE §6.6)

    @Test("Spatial verification passes when no text overlaps redaction",
          .timeLimit(.minutes(1)))
    func spatialVerificationPasses() async throws {
        // Create PDF with text at known position
        let data = TestFixtures.textLayerPDF(text: "Hello World")
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))

        // Redaction far from text position
        let redactionRect = CGRect(x: 0, y: 0, width: 50, height: 50)

        let result = try await verifier.verifySpatialExclusion(
            outputPage: page,
            redactionRects: [redactionRect]
        )
        #expect(result == .pass)
    }

    @Test("Spatial verification catches text overlapping redaction region",
          .timeLimit(.minutes(1)))
    func spatialVerificationCatchesOverlap() async throws {
        let data = TestFixtures.textLayerPDF(text: "SECRET CONTENT")
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))

        // UIGraphicsPDFRenderer draws text with top-left origin, but PDFKit
        // reports bounds in bottom-left PDF coordinates. Text drawn at y=72
        // in UIKit is near the top of the page, which is high y in PDF coords.
        let pageBounds = page.bounds(for: .cropBox)
        // Cover the area where text is likely to be
        let redactionRect = CGRect(x: 50, y: pageBounds.height - 120,
                                   width: 400, height: 60)

        let result = try await verifier.verifySpatialExclusion(
            outputPage: page,
            redactionRects: [redactionRect]
        )
        #expect(result == .fail(""),
                "Spatial verification should FAIL when text overlaps redaction region")
    }

    @Test("Spatial verification passes for empty text layer")
    func spatialVerificationEmptyTextLayer() async throws {
        let data = TestFixtures.imageOnlyPDF()
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))

        let result = try await verifier.verifySpatialExclusion(
            outputPage: page,
            redactionRects: [CGRect(x: 0, y: 0, width: 612, height: 792)]
        )
        #expect(result == .pass)
    }

    @Test("SVT-1 lattice runs on a region-less page (CAT-358)")
    func svt1LatticeRunsOnRegionlessPage() async throws {
        // Region-less page → regionShapes == []. Pre-fix the guard
        // `count > 0, !regionShapes.isEmpty` short-circuited to .pass before the
        // SVT-1 lattice ran, so glyph-position tampering on a region-less page
        // evaded the only positional check. The tampered half is the red→green.

        // Correctly-pitched Courier (10 invisible words) → .pass.
        let okDoc = try #require(PDFDocument(data: TestFixtures.ctLineDrawCourierPDF()))
        let okPage = try #require(okDoc.page(at: 0))
        let okResult = try await verifier.verifySpatialExclusion(
            outputPage: okPage, regionShapes: [], pageIndex: 0)
        #expect(okResult == .pass,
                "uniform Courier on a region-less page must pass; got \(okResult)")

        // TJ-kerning-tampered Courier → .fail (origin deltas off the lattice).
        let badDoc = try #require(PDFDocument(data: TestFixtures.withBlandKerningInjection()))
        let badPage = try #require(badDoc.page(at: 0))
        let badResult = try await verifier.verifySpatialExclusion(
            outputPage: badPage, regionShapes: [], pageIndex: 0)
        #expect(badResult.isFail,
                "TJ-kerning tampering on a region-less page must FAIL the SVT-1 lattice; got \(badResult)")
    }

    // MARK: - SVT-1 pitch-flip acceptance (J-14, BH-A-02 ≡ BH-B-05)

    /// Draw invisible Courier lines writer-style (mode-3 CTLineDraw, one
    /// size per line) at the given sizes/origins and return the PDF bytes.
    private func writerStyleTwoLinePDF(
        first: (text: String, size: CGFloat, origin: CGPoint),
        second: (text: String, size: CGFloat, origin: CGPoint)
    ) throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("svt1_flip_\(UUID().uuidString).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try #require(CGContext(url as CFURL, mediaBox: &mediaBox, nil))
        ctx.beginPDFPage(nil)
        ctx.setTextDrawingMode(.invisible)
        for line in [first, second] {
            ctx.saveGState()
            ctx.textMatrix = .identity
            let font = CTFontCreateWithName("Courier" as CFString, line.size, nil)
            let attr = NSAttributedString(
                string: line.text,
                attributes: [.font: font])
            ctx.textPosition = line.origin
            CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
            ctx.restoreGState()
        }
        ctx.endPDFPage()
        ctx.closePDF()
        defer { try? FileManager.default.removeItem(at: url) }
        return try Data(contentsOf: url)
    }

    /// Read back the page and require the SVT-1 walk to see BOTH point
    /// sizes inside ONE y-band — the writer-band junction the pitch-flip
    /// rule adjudicates. Guards the acceptance tests against vacuity (two
    /// read-back bands would never reach the flip site).
    private func requireSameBandSizeJunction(
        _ page: PDFPage, sizes: Set<CGFloat>
    ) throws {
        let text = try #require(page.string) as NSString
        var units: [(y: CGFloat, size: CGFloat)] = []
        var off = 0
        while off < page.numberOfCharacters {
            let r = text.rangeOfComposedCharacterSequence(at: off)
            defer { off += max(r.length, 1) }
            guard let sel = page.selection(for: r) else { continue }
            let b = sel.bounds(for: page)
            guard b.width > 0, b.height > 0,
                  !FilterResult.isLineageWhitespace(text.substring(with: r))
            else { continue }
            var size: CGFloat = 0
            #if canImport(UIKit)
            if let a = sel.attributedString, a.length > 0,
               let f = a.attribute(.font, at: 0, effectiveRange: nil) as? UIFont {
                size = f.pointSize
            }
            #else
            if let a = sel.attributedString, a.length > 0,
               let f = a.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
                size = f.pointSize
            }
            #endif
            units.append((b.minY, size))
        }
        let bands = SandwichVerification.yBands(units.map(\.y))
        var sizesPerBand: [Int: [CGFloat]] = [:]
        for (k, u) in units.enumerated() {
            sizesPerBand[bands[k], default: []].append(u.size)
        }
        // Read-back sizes carry float slop — match at 0.05pt tolerance.
        try #require(
            sizesPerBand.values.contains { bandSizes in
                sizes.allSatisfy { want in
                    bandSizes.contains { abs($0 - want) < 0.05 }
                }
            },
            "read-back must pool both sizes \(sizes) into one band — adjust test geometry")
    }

    @Test("SVT-1 accepts a writer-grammar pitch flip inside a pooled band (J-14)",
          .tags(.critical))
    func svt1PitchFlipAtWriterQuantizedSizesPasses() async throws {
        // The C1/BH shape: two writer bands at quantized pitches (5.0pt,
        // 5.5pt) whose read-back line boxes pool into one verifier band.
        // Pre-J-14 this FAILed as "Non-uniform glyph advance" on every
        // ordinary searchable export of such a page.
        let data = try writerStyleTwoLinePDF(
            first: ("MEMBER FDIC.", 5.0, CGPoint(x: 60, y: 100)),
            second: ("RESERVE NOTICE", 5.5, CGPoint(x: 120, y: 100)))
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        try requireSameBandSizeJunction(page, sizes: [5.0, 5.5])
        let result = try await verifier.verifySpatialExclusion(
            outputPage: page, regionShapes: [], pageIndex: 0)
        #expect(!result.isFail,
                "quantized-pitch writer-band junction must not FAIL; got \(result)")
    }

    @Test("SVT-1 still fails a pitch flip to an off-lattice foreign size",
          .tags(.critical))
    func svt1PitchFlipAtForeignSizeFails() async throws {
        // A foreign text object at 5.3pt — not a §5C.2-emittable size —
        // must still read as output this writer did not produce.
        let data = try writerStyleTwoLinePDF(
            first: ("MEMBER FDIC.", 5.0, CGPoint(x: 60, y: 100)),
            second: ("INJECTED RUN", 5.3, CGPoint(x: 120, y: 100)))
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        try requireSameBandSizeJunction(page, sizes: [5.0, 5.3])
        let result = try await verifier.verifySpatialExclusion(
            outputPage: page, regionShapes: [], pageIndex: 0)
        #expect(result.isFail,
                "off-lattice pitch flip must FAIL the SVT-1 check; got \(result)")
    }

    @Test("isWriterQuantizedPitch matches the §5C.2 emittable set")
    func writerQuantizedPitchPredicate() {
        #expect(SandwichVerification.isWriterQuantizedPitch(5.0))
        #expect(SandwichVerification.isWriterQuantizedPitch(5.5))
        #expect(SandwichVerification.isWriterQuantizedPitch(12.0))
        #expect(SandwichVerification.isWriterQuantizedPitch(1.0))
        #expect(!SandwichVerification.isWriterQuantizedPitch(5.3))
        #expect(!SandwichVerification.isWriterQuantizedPitch(5.26))
        #expect(!SandwichVerification.isWriterQuantizedPitch(0.5),
                "below minimumFontSize is not writer-emittable")
    }

    // MARK: - Layer 7: Character Count Cross-Check (ENGINE §6.6)

    @Test("Character count matches digest when counts agree")
    func characterCountMatches() async throws {
        let data = TestFixtures.textLayerPDF(text: "ABCDEFGHIJ")
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))

        // Extract characters to get accurate count
        let extractor = TextLayerExtractor()
        let characters = try await extractor.extractCharacters(from: page)

        // Create digest with matching counts (no redaction)
        let digest = PageFilterDigest(
            pageIndex: 0,
            extractedCount: characters.count,
            excludedCount: 0,
            survivingCount: characters.count,
            boundaryCharacters: []
        )

        let result = try await verifier.verifyCharacterCount(
            outputPage: page, digest: digest
        )
        #expect(result == .pass)
    }

    @Test("Character count mismatch detected")
    func characterCountMismatch() async throws {
        let data = TestFixtures.textLayerPDF(text: "Hello World")
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))

        // Create digest with wrong counts
        let digest = PageFilterDigest(
            pageIndex: 0,
            extractedCount: 100,
            excludedCount: 50,
            survivingCount: 999, // Clearly wrong
            boundaryCharacters: []
        )

        let result = try await verifier.verifyCharacterCount(
            outputPage: page, digest: digest
        )
        #expect(result == .fail(""),
                "Should fail when character count doesn't match")
    }

    // MARK: - Layer 8: Font Verification (ENGINE §6.6)

    @Test("Font verification passes for blank page (no fonts)")
    func fontVerificationBlankPage() async throws {
        let data = TestFixtures.blankPage()
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))

        let result = try await verifier.verifyFontsAreMonospace(outputPage: page, pageIndex: 0)
        #expect(result == .pass)
    }

    @Test("Font verification WARNs when a page has no /Resources (CAT-380A)")
    func fontVerificationWarnsWhenNoPageResources() async throws {
        // blankPage() carries an empty-but-present `/Resources << >>` (→ .pass at
        // the no-/Font guard). This fixture omits /Resources entirely; Layer 8
        // can no longer inspect fonts, so it WARNs instead of silently passing.
        let data = TestFixtures.pageWithoutResources()
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))

        let result = try await verifier.verifyFontsAreMonospace(outputPage: page, pageIndex: 0)
        guard case .warn = result else {
            Issue.record("expected .warn for a page with no /Resources; got \(result)")
            return
        }
    }

    // MARK: - Fallback Detection

    @Test("Image-only PDF has no text layer")
    func imageOnlyNoTextLayer() throws {
        let data = TestFixtures.imageOnlyPDF()
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))

        let status = TextLayerDetector.detectTextLayer(page)
        #expect(status == .none,
                "Image-only PDF should have no text layer")
    }

    // MARK: - End-to-end: Extract → Filter → Verify Counts

    @Test("Extract, filter, and verify counts end-to-end",
          .timeLimit(.minutes(1)))
    func extractFilterVerifyCounts() async throws {
        let data = TestFixtures.textLayerPDF(text: "ABCDEFGHIJ KLMNOPQRST")
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))

        let extractor = TextLayerExtractor()
        let characters = try await extractor.extractCharacters(from: page)

        // Redact some area
        let pageBounds = page.bounds(for: .cropBox)
        let redactionInPoints = normalizedToPDFPageCoordinates(
            CGRect(x: 0.1, y: 0.85, width: 0.15, height: 0.1),
            pageRect: pageBounds
        )

        let filterResult = try await filterCharacters(
            characters: characters,
            redactionRects: [redactionInPoints]
        )

        let digest = filterResult.toDigest(
            pageIndex: 0,
            redactionRects: [redactionInPoints],
            safetyMargin: 2.0
        )

        // Verify the counts are self-consistent
        #expect(digest.extractedCount == filterResult.totalCharacters)
        #expect(digest.excludedCount == filterResult.excludedCount)
        #expect(digest.survivingCount == filterResult.surviving.count)
        #expect(digest.extractedCount == digest.excludedCount + digest.survivingCount)
    }
}
