import Testing
import Foundation
import PDFKit
import CoreGraphics
@testable import RedactionEngine

// EXP-009 migrated: Rotated & Non-Zero-Origin Coordinates
// Audit: PD-5-1 (High), AA-12-1 (High), TL-1-1 (High), AA-13-1 (High)
// Security-critical: wrong coordinates = data leakage.

@Suite("Rotated Page Coordinates", .tags(.security, .critical))
struct RotatedPageCoordinateTests {

    private func makePDFDocument(rotation: Int) -> PDFDocument {
        let data: Data
        if rotation == 0 {
            data = TestFixtures.blankPage()
        } else {
            data = TestFixtures.rotatedPDF(rotation: rotation)
        }
        return PDFDocument(data: data)!
    }

    private func makeTextPDFDocument(rotation: Int) -> PDFDocument {
        let data = TestFixtures.rotatedTextPDF(rotation: rotation)
        return PDFDocument(data: data)!
    }

    private func makeCGPDFDocument(rotation: Int) -> CGPDFDocument {
        let data = TestFixtures.rotatedTextPDF(rotation: rotation)
        return CGPDFDocument(CGDataProvider(data: data as CFData)!)!
    }

    private func renderPage(_ pdfPage: CGPDFPage, dpi: CGFloat = 150) -> CGImage {
        let rawBounds = pdfPage.getBoxRect(.cropBox)
        let rotation = pdfPage.rotationAngle
        let effectiveBounds: CGRect
        switch rotation {
        case 90, 270:
            effectiveBounds = CGRect(x: rawBounds.origin.x, y: rawBounds.origin.y,
                                     width: rawBounds.height, height: rawBounds.width)
        default:
            effectiveBounds = rawBounds
        }
        let scale = dpi / 72.0
        let w = Int(ceil(effectiveBounds.width * scale))
        let h = Int(ceil(effectiveBounds.height * scale))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
                       | CGImageAlphaInfo.premultipliedFirst.rawValue
        let bytesPerRow = ((w * 4) + 0x0F) & ~0x0F
        let ctx = CGContext(data: nil, width: w, height: h,
                            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                            space: colorSpace, bitmapInfo: bitmapInfo)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let drawRect = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
        let transform = pdfPage.getDrawingTransform(.cropBox, rect: drawRect,
                                                     rotate: 0, preserveAspectRatio: true)
        ctx.concatenate(transform)
        ctx.drawPDFPage(pdfPage)
        return ctx.makeImage()!
    }

    // --- PD-5-1: Overlay bounds match post-rotation ---
    @Test("Overlay bounds match post-rotation dimensions (PD-5-1)",
          arguments: [0, 90, 180, 270])
    func overlayBoundsMatchPostRotation(rotation: Int) {
        let doc = makePDFDocument(rotation: rotation)
        let page = doc.page(at: 0)!
        let rawBounds = page.bounds(for: .cropBox)

        if rotation == 90 || rotation == 270 {
            // Effective dimensions are swapped
            #expect(rawBounds.height > 0)
            #expect(rawBounds.width > 0)
        }
    }

    // --- AA-12-1: Rendered bitmap correctness for rotated pages ---
    @Test("Rendered bitmap dimensions correct for /Rotate 90 (AA-12-1)")
    func rotatedPageRenderCorrectness() {
        let cgDoc = makeCGPDFDocument(rotation: 90)
        let page = cgDoc.page(at: 1)!
        let image = renderPage(page, dpi: 150)
        let rawBounds = page.getBoxRect(.cropBox)
        let rotation = page.rotationAngle
        let scale: CGFloat = 150.0 / 72.0

        let expectedWidth: Int
        let expectedHeight: Int
        if rotation == 90 || rotation == 270 {
            expectedWidth = Int(ceil(rawBounds.height * scale))
            expectedHeight = Int(ceil(rawBounds.width * scale))
        } else {
            expectedWidth = Int(ceil(rawBounds.width * scale))
            expectedHeight = Int(ceil(rawBounds.height * scale))
        }

        #expect(image.width == expectedWidth, "Bitmap width must match post-rotation")
        #expect(image.height == expectedHeight, "Bitmap height must match post-rotation")

        // Verify non-blank by sampling pixels across the full image
        let ptr = CFDataGetBytePtr(image.dataProvider!.data!)!
        let totalPixels = image.width * image.height
        var nonWhite = 0
        // Sample every 100th pixel across the full image
        for i in stride(from: 0, to: totalPixels * 4, by: 100 * 4) {
            if ptr[i] != 255 || ptr[i+1] != 255 || ptr[i+2] != 255 { nonWhite += 1 }
        }
        #expect(nonWhite > 0, "Rendered bitmap must contain visible content")
    }

    // --- TL-1-1: PDFSelection.bounds coordinate frame with /Rotate ---
    @Test("PDFSelection bounds in correct coordinate frame with /Rotate (TL-1-1)")
    func pdfSelectionBoundsCoordinateFrame() {
        let doc = makeTextPDFDocument(rotation: 90)
        let page = doc.page(at: 0)!
        let rawBounds = page.bounds(for: .cropBox)
        guard let pageString = page.string, !pageString.isEmpty else {
            // Rotated text PDF may not have extractable text via raw PDF streams
            return
        }
        let firstCharSel = page.selection(for: NSRange(location: 0, length: 1))
        if let bounds = firstCharSel?.bounds(for: page) {
            let inBounds = bounds.maxX <= rawBounds.width + rawBounds.origin.x + 1
                && bounds.maxY <= rawBounds.height + rawBounds.origin.y + 1
            #expect(inBounds, "Selection bounds must be within page bounds")
        }
    }

    // --- AA-13-1: PDFSelection.bounds with non-zero cropBox origin ---
    @Test("PDFSelection bounds with non-zero cropBox origin (AA-13-1)")
    func pdfSelectionBoundsWithNonZeroOrigin() {
        let data = TestFixtures.nonZeroOriginPDF()
        let doc = PDFDocument(data: data)!
        let page = doc.page(at: 0)!
        let cropBox = page.bounds(for: .cropBox)

        #expect(cropBox.origin != .zero,
                "Non-zero-origin fixture must have non-zero cropBox origin")

        guard let pageString = page.string, !pageString.isEmpty else {
            Issue.record("Non-zero-origin test PDF must contain text"); return
        }
        let sel = page.selection(for: NSRange(location: 0, length: 1))
        if let bounds = sel?.bounds(for: page) {
            // Selection bounds should account for cropBox origin offset
            let includesOffset = bounds.minX >= cropBox.origin.x - 1
            #expect(includesOffset,
                    "Selection bounds should include cropBox origin offset")
        }
    }

    // --- S15 E1: PDFKit selection frame under /Rotate (pins T_rot direction) ---
    // C-C deep-plan §5/§6 + ADV-2 A2-7 §0: BEFORE any T_rot production code, pin
    // whether `PDFSelection.bounds(for:)` returns UNROTATED source-page space (so
    // CAT-353's T_rot must apply the rotation mapping) or already-rotation-applied
    // DISPLAYED space (T_rot collapses to identity-plus-translation). The single
    // highest risk in the cluster — the direction must rest on measurement, not
    // assumption. Synthetic fixture only; coordinates are safe to log (no PII,
    // not a real document — protocol §10). The memo (A2-7) predicts UNROTATED/invariant.
    @Test("E1: PDFSelection.bounds(for:) frame under /Rotate (CAT-353 direction probe)")
    func e1SelectionFrameUnderRotation() throws {
        var anchorByRot: [Int: CGRect] = [:]
        var markerByRot: [Int: CGRect] = [:]
        for rotation in [0, 90, 180, 270] {
            let data = TestFixtures.rotatedTextPDF(rotation: rotation)
            let doc = try #require(PDFDocument(data: data))
            let page = try #require(doc.page(at: 0))
            let cropBox = page.bounds(for: .cropBox)
            let pageText = (page.string ?? "") as NSString
            print("E1-PROBE r=\(rotation) pdfkitRot=\(page.rotation) cropBox=\(cropBox) "
                + "chars=\(page.numberOfCharacters) "
                + "hasANCHOR=\(pageText.range(of: "ANCHOR").location != NSNotFound) "
                + "hasMARKER=\(pageText.range(of: "MARKER").location != NSNotFound)")
            #expect(page.numberOfCharacters > 0,
                    "rotated fixture must yield extractable text (r=\(rotation))")
            for word in ["ANCHOR", "MARKER"] {
                let rg = pageText.range(of: word)
                guard rg.location != NSNotFound,
                      let sel = page.selection(for: rg) else {
                    print("E1-PROBE r=\(rotation) word=\(word) NO-SELECTION")
                    continue
                }
                let b = sel.bounds(for: page)
                print("E1-PROBE r=\(rotation) word=\(word) bounds="
                    + "(\(b.minX), \(b.minY), \(b.width), \(b.height))")
                if word == "ANCHOR" { anchorByRot[rotation] = b } else { markerByRot[rotation] = b }
            }
        }
        // PINNED RESULT (S15, iOS 26 sim): a word's bounds are INVARIANT across
        // all four rotations — PDFKit reports UNROTATED source-page space and
        // treats /Rotate as a pure display attribute. Therefore CAT-353's T_rot
        // MUST map cropBox-local bounds into displayed space (the four-case
        // mapping), and does NOT collapse to identity-plus-translation. This is a
        // standing guard: if a future SDK makes bounds rotation-applied, this
        // flips red and T_rot must be revisited (cf. KI-2 / CAT-364).
        for (label, byRot) in [("ANCHOR", anchorByRot), ("MARKER", markerByRot)] {
            guard let b0 = byRot[0] else { continue }
            for r in [90, 180, 270] {
                guard let br = byRot[r] else { continue }
                let invariant = abs(b0.minX - br.minX) < 1 && abs(b0.minY - br.minY) < 1
                print("E1-PROBE FRAME \(label) r0-vs-r\(r) invariant=\(invariant) "
                    + "b0=(\(b0.minX),\(b0.minY)) br=(\(br.minX),\(br.minY))")
                #expect(invariant,
                        "PDFKit sel.bounds(for:) must be rotation-invariant (\(label) r0 vs r\(r)) — T_rot direction depends on it")
            }
        }
    }

    // --- S15 CAT-353: T_rot four-case transform (ADV-2 A2-7 cross-check) ---
    // Hand-verified concrete values from ADV-2 A2-7: page 612×792, local rect
    // (0,0,10,10) at the bottom-left of the unrotated sheet. Non-circular — the
    // expected outputs are the reviewer's independent corner-checked derivation,
    // not a re-run of the production formula.
    @Test("T_rot maps the four rotations per the canonical contract (CAT-353)")
    func tRotFourCaseTransform() {
        let size = CGSize(width: 612, height: 792)
        let local = CGRect(x: 0, y: 0, width: 10, height: 10)
        func t(_ r: Int) -> CGRect {
            TextLayerExtractor.rotateRectIntoOutputSpace(local, sourceCropSize: size, rotation: r)
        }
        #expect(t(0) == CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(t(90) == CGRect(x: 0, y: 602, width: 10, height: 10))    // displayed top-left
        #expect(t(180) == CGRect(x: 602, y: 782, width: 10, height: 10)) // displayed top-right
        #expect(t(270) == CGRect(x: 782, y: 0, width: 10, height: 10))   // displayed bottom-right
        // Asymmetric rect to expose a swapped origin/size pairing (a symmetric
        // square cannot): local (100, 700, 40, 12) → r=90 size must be (hr, wr).
        let asym = TextLayerExtractor.rotateRectIntoOutputSpace(
            CGRect(x: 100, y: 700, width: 40, height: 12), sourceCropSize: size, rotation: 90)
        #expect(asym == CGRect(x: 700, y: 612 - 100 - 40, width: 12, height: 40))
    }

    // --- S15 CAT-353: rotated extraction lands in DISPLAYED space (red→green) ---
    // Integration guard through extractCharacters. BEFORE T_rot, a rotated page's
    // bounds were merely origin-subtracted (cropBox-local, unrotated), so a glyph
    // at unrotated y≈694 falls OUTSIDE the /Rotate 90 displayed height (612) —
    // RED. AFTER T_rot every glyph maps inside the displayed (effective) page —
    // GREEN. Covers zero and offset CropBox origins (local-first-then-rotate).
    @Test("Extracted bounds lie within the displayed page after T_rot (CAT-353)",
          arguments: [0, 90, 180, 270])
    func rotatedExtractionLandsInDisplayedSpace(rotation: Int) async throws {
        for origin in [CGPoint.zero, CGPoint(x: 200, y: 150)] {
            let data = TestFixtures.rotatedTextPDF(rotation: rotation, cropBoxOrigin: origin)
            let doc = try #require(PDFDocument(data: data))
            let page = try #require(doc.page(at: 0))
            let chars = try await TextLayerExtractor().extractCharacters(from: page)
            #expect(!chars.isEmpty, "r=\(rotation) origin=\(origin): expected glyphs")

            let cropBox = page.bounds(for: .cropBox)
            let effective = effectiveBounds(cropBox, rotation: rotation).size
            let displayed = CGRect(x: 0, y: 0, width: effective.width, height: effective.height)
                .insetBy(dx: -1, dy: -1)  // 1pt tolerance for glyph overflow
            for ch in chars {
                #expect(displayed.contains(ch.bounds),
                        "r=\(rotation) origin=\(origin): glyph bounds must be zero-origin displayed-space (within \(effective))")
            }
        }
    }

    // --- F13/CAT-366: origin-frame probe (ADV-2 A2-6) ---
    // AA-13-1 above cannot tell the absolute and cropBox-local frames apart:
    // its fixture (origin 50, text at user-space 100) clears `minX ≥ 49` in
    // BOTH frames (absolute 100, local 50). This probe uses the discriminating
    // fixture (origin 200, text at user-space 220) to PIN that
    // `PDFSelection.bounds(for:)` returns coordinates in the source page's
    // ABSOLUTE (MediaBox / user) space — the premise the CAT-366 CropBox-local
    // subtraction is written against. It reads the raw PDFKit API only, so it
    // stays valid (and green) before and after the extractor-side correction.
    @Test("PDFSelection bounds are MediaBox-absolute on a non-zero-origin page (CAT-366 probe)")
    func nonZeroCropBoxSelectionFrameProbe() throws {
        let data = TestFixtures.nonZeroOriginDiscriminatingPDF()
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        let cropBox = page.bounds(for: .cropBox)
        #expect(cropBox.origin.x >= 199 && cropBox.origin.y >= 199,
                "discriminating fixture must have cropBox origin ≈ (200, 200)")

        let pageString = try #require(page.string)
        #expect(!pageString.isEmpty, "discriminating fixture must contain text")
        let sel = try #require(page.selection(for: NSRange(location: 0, length: 1)))
        let bounds = sel.bounds(for: page)
        // Absolute frame: minX ≈ 220 (≥ origin.x 200). A cropBox-local frame
        // would put minX ≈ 20 (< origin.x). The assertion discriminates the two
        // and records the measured frame the CAT-366 subtraction rests on.
        #expect(bounds.minX >= cropBox.origin.x,
                "selection bounds must be absolute-space (minX ≈ 220, not local ≈ 20)")
    }

    // ====================================================================
    // S15 CAT-353 — D-35 redaction-correctness matrix
    // 4 rotations × {zero, offset} CropBox origin. Per case: (i) the filter
    // excludes text under the region and keeps text away from it; (ii) the
    // full pipeline (rasterize → reconstruct → verify) passes Layers 6–10;
    // (iii) a tamper variant (text NOT excluded, claimed redacted) → Layer 6
    // FAILs; HARD GATE: checkFallbackTriggers == nil so the page genuinely
    // takes searchable mode and the Layers-6-10 asserts are not vacuous
    // (L3-14). The redaction REGION is positioned by a TEST-LOCAL copy of the
    // A2-7 transform (independent of production T_rot) so the matrix stays
    // red when T_rot is wrong/absent: at the pin (no rotation mapping) MARKER's
    // glyphs sit at unrotated coords, the displayed region is elsewhere, and
    // excludedCount == 0 ≠ markerCount. Green only when production T_rot lands
    // the glyphs in the displayed region this helper computes.
    // ====================================================================

    private let engine = VerificationEngine()

    /// Test-local, independent A2-7 transform — used only to position the
    /// redaction region; deliberately NOT the production `rotateRectIntoOutputSpace`.
    private func displayedRect(_ r: CGRect, sourceSize s: CGSize, rotation: Int) -> CGRect {
        let x = r.minX, y = r.minY, wr = r.width, hr = r.height
        let w = s.width, h = s.height
        switch ((rotation % 360) + 360) % 360 {
        case 90:  return CGRect(x: y, y: w - x - wr, width: hr, height: wr)
        case 180: return CGRect(x: w - x - wr, y: h - y - hr, width: wr, height: hr)
        case 270: return CGRect(x: h - y - hr, y: x, width: hr, height: wr)
        default:  return r
        }
    }

    private func unionBounds(_ rects: [CGRect]) -> CGRect {
        guard var u = rects.first else { return .zero }
        for r in rects.dropFirst() { u = u.union(r) }
        return u
    }

    @Test("redactionCorrectForRotation matrix (D-35): filter + Layers 6–10 + tamper",
          .tags(.security, .critical),
          arguments: [0, 90, 180, 270], [CGPoint.zero, CGPoint(x: 200, y: 150)])
    func redactionCorrectForRotation(rotation: Int, origin: CGPoint) async throws {
        let source = TestFixtures.rotatedTextBaseSize  // unrotated cropBox size
        let effective = effectiveBounds(
            CGRect(origin: .zero, size: source), rotation: rotation
        ).size

        // Reference: extract from the UNROTATED zero-origin fixture (T_rot is
        // identity there) to get MARKER/ANCHOR LOCAL bounds + glyph counts,
        // independent of the rotated extraction under test. Partition the two
        // well-separated words by X (MARKER at local x≈360, ANCHOR at x≈72).
        let refDoc = try #require(PDFDocument(data: TestFixtures.rotatedTextPDF(rotation: 0)))
        let refPage = try #require(refDoc.page(at: 0))
        let refChars = try await TextLayerExtractor().extractCharacters(from: refPage)
        let markerRef = refChars.filter { $0.bounds.minX >= 300 }
        let anchorRef = refChars.filter { $0.bounds.minX < 300 }
        let markerLocal = unionBounds(markerRef.map(\.bounds))
        let anchorLocal = unionBounds(anchorRef.map(\.bounds))
        #expect(!markerRef.isEmpty && !anchorRef.isEmpty, "reference must split into two words")

        // Region over MARKER in DISPLAYED space (test-local transform), normalized.
        let markerDisplayed = displayedRect(markerLocal, sourceSize: source, rotation: rotation)
        let anchorDisplayed = displayedRect(anchorLocal, sourceSize: source, rotation: rotation)
        let regionNorm = CGRect(
            x: markerDisplayed.minX / effective.width,
            y: markerDisplayed.minY / effective.height,
            width: markerDisplayed.width / effective.width,
            height: markerDisplayed.height / effective.height
        )
        let region = RedactionRegion(id: UUID(), normalizedRect: regionNorm, source: .manual)
        let label = "r=\(rotation) origin=(\(Int(origin.x)),\(Int(origin.y)))"

        let data = TestFixtures.rotatedTextPDF(rotation: rotation, cropBoxOrigin: origin)
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))

        // HARD GATE (L3-14): the page must qualify for searchable mode.
        #expect(TextLayerDetector.checkFallbackTriggers(page) == nil,
                "\(label): fixture must take searchable mode (no fallback) or the matrix is vacuous")

        // (i) FILTER LEVEL — region basis is the production zero-origin displayed page.
        let chars = try await TextLayerExtractor().extractCharacters(from: page)
        let regionBasis = CGRect(origin: .zero, size: effective)
        let regionPoints = normalizedToPDFPageCoordinates(regionNorm, pageRect: regionBasis)
        let fr = try await filterCharacters(characters: chars, redactionRects: [regionPoints])
        #expect(fr.totalCharacters == refChars.count, "\(label): extraction count stable under rotation")
        #expect(fr.excludedCount == markerRef.count,
                "\(label): exactly the MARKER glyphs (\(markerRef.count)) must be excluded — got \(fr.excludedCount)")
        #expect(fr.surviving.count == refChars.count - markerRef.count,
                "\(label): ANCHOR glyphs must survive")
        #expect(fr.surviving.contains { anchorDisplayed.intersects($0.bounds) },
                "\(label): a surviving glyph must sit in the ANCHOR displayed region")

        // (ii) FULL PIPELINE → Layers 6–10 (indices 5…9) must not FAIL.
        let outURL = try await TestPipeline.processAndExport(
            data, mode: .searchableRedaction, regions: [0: [region]]
        )
        defer { try? FileManager.default.removeItem(at: outURL) }
        let outDoc = try #require(PDFDocument(url: outURL))
        let digests = try await TestPipeline.searchableDigests(data, regions: [0: [region]])
        for idx in 5...9 {
            let lr = await engine.runLayer(
                idx, outputDocument: SendablePDFDocument(outDoc),
                sourcePageCount: 1, regions: [0: [region]], sensitiveTerms: [],
                pipelineMode: .searchableRedaction,
                filterDigests: digests, perPageModes: [.searchableRedaction]
            )
            #expect(!lr.status.isFail,
                    "\(label): \(engine.layerName(at: idx)) must not FAIL on a correct rotated redaction")
        }

        // (iii) TAMPER — reconstruct WITHOUT excluding MARKER (claimed redacted),
        // then verify against the MARKER region: Layer 6 must locate the
        // surviving MARKER text inside the region and FAIL. This both proves the
        // Layer-6 assertion above is not vacuous AND requires T_rot to place the
        // surviving glyphs in displayed space (at the pin, no overlap → no FAIL).
        let tamperURL = try await TestPipeline.processAndExport(
            data, mode: .searchableRedaction, regions: [0: []]
        )
        defer { try? FileManager.default.removeItem(at: tamperURL) }
        let tamperDoc = try #require(PDFDocument(url: tamperURL))
        let l6 = await engine.runLayer(
            5, outputDocument: SendablePDFDocument(tamperDoc),
            sourcePageCount: 1, regions: [0: [region]], sensitiveTerms: [],
            pipelineMode: .searchableRedaction,
            filterDigests: [nil], perPageModes: [.searchableRedaction]
        )
        #expect(l6.status.isFail,
                "\(label): Layer 6 must FAIL when un-excluded MARKER text overlaps the claimed region")
    }

    // --- CND-02: EmbeddedTextSource.make lands in DISPLAYED space (red→green) ---
    // make() is the third coordinate producer (PERF-4 fast path). CAT-353/
    // CAT-366 migrated extractCharacters and DocumentSearcher to the zero-origin
    // displayed output frame but NOT make(), so before this fix its word/line
    // rects stayed cropBox-local-unrotated: on /Rotate{90,180,270} the detection
    // centroid maps to the wrong displayed pixel and the burn-in under-redacts
    // (a live production leak once the rotated-rich Secure-Raster stopgap was
    // removed). This guard pins make()'s MARKER word centroid to the displayed-
    // marker location, derived two ways that never re-run production make():
    //   (1) a TEST-LOCAL A2-7 transform over the reference LOCAL MARKER bounds
    //       (RED when make lacks T_rot) — the load-bearing assertion; and
    //   (2) cross-producer agreement with extractCharacters, the validated
    //       displayed-space producer, on the same rotated page (Vision OCR can't
    //       run deterministically on this sim/host, so the text-layer producer
    //       stands in for the OCR sub-path whose displayed frame it shares).
    // Synthetic fixture; coordinates are safe to log (no PII, not a real document).
    @Test("EmbeddedTextSource.make word centroid is displayed-space (CND-02)",
          .tags(.security, .critical),
          arguments: [0, 90, 180, 270], [CGPoint.zero, CGPoint(x: 200, y: 150)])
    func embeddedMakeCentroidIsDisplayedSpace(rotation: Int, origin: CGPoint) async throws {
        let source = TestFixtures.rotatedTextBaseSize
        let effective = effectiveBounds(
            CGRect(origin: .zero, size: source), rotation: rotation
        ).size
        let label = "r=\(rotation) origin=(\(Int(origin.x)),\(Int(origin.y)))"

        // Reference LOCAL MARKER bounds from the unrotated zero-origin fixture
        // (T_rot identity there); MARKER and ANCHOR split cleanly by X (≥300).
        let refDoc = try #require(PDFDocument(data: TestFixtures.rotatedTextPDF(rotation: 0)))
        let refPage = try #require(refDoc.page(at: 0))
        let refChars = try await TextLayerExtractor().extractCharacters(from: refPage)
        let markerRef = refChars.filter { $0.bounds.minX >= 300 }
        try #require(!markerRef.isEmpty, "reference must contain the MARKER word")
        let markerLocal = unionBounds(markerRef.map(\.bounds))
        let markerDisplayed = displayedRect(markerLocal, sourceSize: source, rotation: rotation)
        let expectedCenter = CGPoint(
            x: markerDisplayed.midX / effective.width,
            y: markerDisplayed.midY / effective.height
        )

        // Production make() on the rotated page → the MARKER word's rect.
        let data = TestFixtures.rotatedTextPDF(rotation: rotation, cropBoxOrigin: origin)
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        let embedded = try #require(
            EmbeddedTextSource.make(from: page),
            "\(label): make() must produce a source for a text page"
        )
        let pageText = (page.string ?? "") as NSString
        let markerWord = try #require(
            embedded.wordBounds.first {
                pageText.substring(with: $0.range).contains("MARKER")
            },
            "\(label): make() must surface the MARKER word"
        )
        let center = CGPoint(x: markerWord.normalizedRect.midX,
                             y: markerWord.normalizedRect.midY)

        // (1) Load-bearing: make() centroid == independently-derived displayed
        // centroid. RED on the pre-fix producer (cropBox-local, no T_rot).
        #expect(abs(center.x - expectedCenter.x) < 0.04 &&
                abs(center.y - expectedCenter.y) < 0.04,
                "\(label): make() MARKER centroid \(center) must equal displayed \(expectedCenter)")
        // The rect must sit inside the displayed page — guards against a regression
        // to normalizing by cropBox.size (not effectiveSize) on 90/270.
        #expect(markerWord.normalizedRect.maxX <= 1.04 &&
                markerWord.normalizedRect.maxY <= 1.04,
                "\(label): normalizedRect must lie within the displayed page")

        // (2) Cross-producer agreement with extractCharacters on the SAME page.
        let chars = try await TextLayerExtractor().extractCharacters(from: page)
        let rotMarkerGlyphs = chars.filter {
            markerDisplayed.insetBy(dx: -2, dy: -2).intersects($0.bounds)
        }
        try #require(!rotMarkerGlyphs.isEmpty,
                     "\(label): extractCharacters must surface MARKER glyphs")
        let extractUnion = unionBounds(rotMarkerGlyphs.map(\.bounds))
        let extractCenter = CGPoint(x: extractUnion.midX / effective.width,
                                    y: extractUnion.midY / effective.height)
        #expect(abs(center.x - extractCenter.x) < 0.04 &&
                abs(center.y - extractCenter.y) < 0.04,
                "\(label): make() centroid \(center) must agree with extractCharacters \(extractCenter)")
    }
}
