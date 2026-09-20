import Testing
import Foundation
import PDFKit
import CoreGraphics
@testable import RedactionEngine

// Tests for Sandwich-specific verification layers 6–8.

@Suite("Sandwich Verification", .tags(.security))
struct SandwichVerificationTests {

    let verifier = SandwichVerification()

    // MARK: - Layer 6: Spatial Exclusion

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
            regionShapes: [RegionShape(expandedBounds: redactionRect, polygonVertices: nil)]
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
            regionShapes: [RegionShape(expandedBounds: redactionRect, polygonVertices: nil)]
        )
        #expect(result == .fail(""),
                "Spatial verification should FAIL when text overlaps redaction region")
    }

    @Test("Zero-bounds non-whitespace units WARN instead of being skipped")
    func spatialVerificationZeroBoundsUnitsWarn() async throws {
        // Two drawn glyphs under a zero text matrix: extracted, but PDFKit
        // reports empty selection bounds for both. Before this check they
        // were dropped from the walk and the page passed; now they are
        // counted and the page WARNs.
        let data = TestFixtures.zeroBoundsGlyphPDF(text: "AB")
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        #expect(page.numberOfCharacters == 2, "fixture: got \(page.numberOfCharacters)")
        let first = try #require(page.selection(for: NSRange(location: 0, length: 1)))
        let bounds = first.bounds(for: page)
        #expect(bounds.width <= 0 || bounds.height <= 0,
                "fixture must read back an empty selection bounds; got \(bounds)")

        let result = try await verifier.verifySpatialExclusion(
            outputPage: page, regionShapes: [], pageIndex: 0)
        #expect(result.isWarn, "unmeasured units must WARN, not pass; got \(result)")
        if case .warn(let msg) = result {
            #expect(msg == "2 characters on page 1 had no measurable position and were not position-checked",
                    "got: \(msg)")
        }

        // The copy seam pluralises by count and prints the 1-based page.
        if case .warn(let msg) = SandwichVerification.zeroBoundsWarning(count: 1, pageIndex: 1) {
            #expect(msg == "1 character on page 2 had no measurable position and was not position-checked",
                    "got: \(msg)")
        } else {
            Issue.record("zeroBoundsWarning must return .warn")
        }
    }

    @Test("Spatial verification passes for empty text layer")
    func spatialVerificationEmptyTextLayer() async throws {
        let data = TestFixtures.imageOnlyPDF()
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))

        let result = try await verifier.verifySpatialExclusion(
            outputPage: page,
            regionShapes: [RegionShape(
                expandedBounds: CGRect(x: 0, y: 0, width: 612, height: 792),
                polygonVertices: nil)]
        )
        #expect(result == .pass)
    }

    @Test("Layer 6 lattice runs on a region-less page")
    func svt1LatticeRunsOnRegionlessPage() async throws {
        // Region-less page → regionShapes == []. Pre-fix the guard
        // `count > 0, !regionShapes.isEmpty` short-circuited to .pass before the
        // Layer 6 lattice ran, so glyph-position tampering on a region-less page
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
                "TJ-kerning tampering on a region-less page must FAIL the Layer 6 lattice; got \(badResult)")
    }

    // MARK: - Layer 6 pitch-flip acceptance

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

    /// Read back the page and require the Layer 6 walk to see BOTH point
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

    @Test("Layer 6 accepts a writer-grammar pitch flip inside a pooled band",
          .tags(.critical))
    func svt1PitchFlipAtWriterQuantizedSizesPasses() async throws {
        // Two writer bands at quantized pitches (5.0pt, 5.5pt) whose
        // read-back line boxes pool into one verifier band. Before this fix
        // it FAILed as "Non-uniform glyph advance" on every ordinary
        // searchable export of such a page.
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

    @Test("Layer 6 still fails a pitch flip to an off-lattice foreign size",
          .tags(.critical))
    func svt1PitchFlipAtForeignSizeFails() async throws {
        // A foreign text object at 5.3pt — not a writer-emittable size —
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
                "off-lattice pitch flip must FAIL the Layer 6 check; got \(result)")
    }

    @Test("isWriterQuantizedPitch matches the writer-emittable set")
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

    // MARK: - Layer 7: Character Count Cross-Check

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

    // MARK: - Layer 8: Font Verification

    @Test("Font verification passes for blank page (no fonts)")
    func fontVerificationBlankPage() async throws {
        let data = TestFixtures.blankPage()
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))

        let result = try await verifier.verifyFontsAreMonospace(outputPage: page, pageIndex: 0)
        #expect(result == .pass)
    }

    @Test("Font verification WARNs when a page has no /Resources")
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

    // MARK: - Layer 6: unmeasured units (the R111-04 residue, S4-V2)

    /// A page whose units have NO read-back selection at all — the class
    /// `selection(for:)` returns nil for. The exclusion walk reads only
    /// `string`, `numberOfCharacters` and `selection(for:)` before its
    /// exclusion pass, so this double is sufficient.
    private final class NilSelectionPage: PDFPage {
        let text: String
        init(text: String) {
            self.text = text
            super.init()
        }
        override var string: String? { text }
        override var numberOfCharacters: Int { (text as NSString).length }
        override func selection(for range: NSRange) -> PDFSelection? { nil }
    }

    @Test("A nil-selection non-whitespace unit is counted as unmeasured (WARN, could-not-verify)")
    func nilSelectionUnitCountedAsUnmeasured() async throws {
        let page = NilSelectionPage(text: "A")
        let region = RegionShape(
            expandedBounds: CGRect(x: 100, y: 100, width: 50, height: 20),
            polygonVertices: nil)
        let outcome = try await verifier.spatialExclusionOutcome(
            outputPage: page, regionShapes: [region], pageIndex: 3)
        #expect(outcome.status.isWarn,
                "a character the check could not place must be reported, not silently skipped; got \(outcome.status)")
        #expect(outcome.couldNotVerify,
                "the unmeasured-position note is the could-not-verify class")
        if case .warn(let msg) = outcome.status {
            #expect(msg == "1 character on page 4 had no measurable position and was not position-checked",
                    "got: \(msg)")
        }
    }

    @Test("A nil-selection whitespace unit is not counted (whitespace is outside the position domain)")
    func nilSelectionWhitespaceNotCounted() async throws {
        let page = NilSelectionPage(text: " ")
        let region = RegionShape(
            expandedBounds: CGRect(x: 100, y: 100, width: 50, height: 20),
            polygonVertices: nil)
        let outcome = try await verifier.spatialExclusionOutcome(
            outputPage: page, regionShapes: [region])
        #expect(outcome.status == .pass, "got \(outcome.status)")
        #expect(!outcome.couldNotVerify)
    }

    // MARK: - Layer 9: empty-lineage symmetry (C12-79 / F12-05, S4-V2)

    @Test("The output walk of a textless page hashes like the filter's empty survivor set")
    func emptyOutputWalkHashesLikeEmptySurvivorSet() async throws {
        let doc = try #require(PDFDocument(data: TestFixtures.blankPage()))
        let page = try #require(doc.page(at: 0))
        let outputHash = try SandwichVerification.computeOutputLineageHash(page)
        let filterHash = FilterResult.computeLineageHash(over: [])
        #expect(!filterHash.isEmpty,
                "the filter's empty-set digest is the SHA-256 of zero updates, never Data()")
        #expect(outputHash == filterHash,
                "a page with no text layer must hash as zero survivors recorded, not as 'no lineage recorded'")
    }

    @Test("A fully-redacted searchable page verifies: Layer 9 PASS and Layer 7 PASS",
          .timeLimit(.minutes(1)))
    func fullyRedactedSearchablePageVerifies() async throws {
        let fixture = TestFixtures.fakeRedaction()
        let fullPage = RedactionRegion(
            id: UUID(), normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            source: .manual)
        let url = try await TestPipeline.processAndExport(
            fixture, mode: .searchableRedaction, regions: [0: [fullPage]])
        defer { try? FileManager.default.removeItem(at: url) }
        let digests = try await TestPipeline.searchableDigests(fixture, regions: [0: [fullPage]])
        let digest = try #require(digests[0])
        #expect(digest.survivingCount == 0, "the full-page region empties the survivor set")
        let outDoc = try #require(PDFDocument(url: url))
        let outPage = try #require(outDoc.page(at: 0))

        let lineage = try await verifier.verifyCharacterLineage(outputPage: outPage, digest: digest)
        #expect(lineage == .pass,
                "zero survivors recorded and zero output characters must agree; got \(lineage)")
        let count = try await verifier.verifyCharacterCount(outputPage: outPage, digest: digest)
        #expect(count == .pass, "got \(count)")
    }

    @Test("The empty-set digest against an output page carrying a glyph FAILs (an injection)")
    func emptySetDigestAgainstDrawnGlyphFails() async throws {
        let digest = PageFilterDigest(
            pageIndex: 0, extractedCount: 1, excludedCount: 1, survivingCount: 0,
            boundaryCharacters: [], lineageHash: FilterResult.computeLineageHash(over: []))
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.courierTextLayerPDF(text: "A"), prefix: "s4v2_empty_vs_glyph_")
        defer { try? FileManager.default.removeItem(at: url) }
        let page = try #require(doc.page(at: 0))
        let result = try await verifier.verifyCharacterLineage(outputPage: page, digest: digest)
        #expect(result == .fail(""),
                "0 survivors recorded with a measurable output unit must FAIL; got \(result)")
    }

    @Test("A Data() lineage digest means 'not recorded' and passes (the legacy guard holds)")
    func emptyDataDigestMeansNotRecorded() async throws {
        let digest = PageFilterDigest(
            pageIndex: 0, extractedCount: 1, excludedCount: 0, survivingCount: 1,
            boundaryCharacters: [])
        #expect(digest.lineageHash.isEmpty)
        let (doc, url) = try TestFixtures.writeTempPDF(
            TestFixtures.courierTextLayerPDF(text: "A"), prefix: "s4v2_data_guard_")
        defer { try? FileManager.default.removeItem(at: url) }
        let page = try #require(doc.page(at: 0))
        let result = try await verifier.verifyCharacterLineage(outputPage: page, digest: digest)
        #expect(result == .pass, "got \(result)")
    }

    @Test("emptyLineageDigest is the filter's empty-set digest and the textless output walk's value")
    func emptyLineageDigestIsShared() async throws {
        #expect(SandwichVerification.emptyLineageDigest == FilterResult.computeLineageHash(over: []))
        #expect(SandwichVerification.emptyLineageDigest.count == 32)
        let doc = try #require(PDFDocument(data: TestFixtures.blankPage()))
        let page = try #require(doc.page(at: 0))
        #expect(try SandwichVerification.computeOutputLineageHash(page)
                == SandwichVerification.emptyLineageDigest)
    }
}
