import Foundation
import CoreGraphics
import CoreText
import PDFKit
import Testing
@testable import RedactionEngine

// PART A — S3: the adversarial recall-safety battery for the Layer-2
// fill-consistency guard (chroma-aware, box∩rect Option A, demote-never-silence).
// See plans/resecta-partA-verifier-guard-2026-06-27/ (RUN-ORDER §2/§4/§6 and
// session-03-*). The S1/S2 suite `Layer2FillHallucinationGuardTests` carries the
// fixtures, builders, regression pair, and the guard's unit tests; this suite is
// the S3 probe set:
//
//   F-CHROMA-BLACK / F-CHROMA-FORMULA — coloured ink whose luminance ≈ the fill
//   F-EDGE-STRADDLE — leak + hallucination variants (Option-A expectations)
//   F-LOW-CONTRAST — dim ink at/below the contrast band's lower edge
//   F-THIN-HIGH-CONTRAST — hairline glyphs under the outlier floor
//   F-WEBER-MARGIN — pale-but-readable ink on WHITE fill + the Δ_contrast sweep
//   F-MIDBAND — sparse mid-gray canary against future floor loosening
//   F-REVERSE-VIDEO — knockout/outline glyphs (fill-coloured body, thin rim)
//   F-STRADDLE-WIRING — demote-never-silence fold wiring (pure)
//   F-PARTA-REPLAY — the real fixture demotes to the fill-artifact INFO note
//   F-PROPERTY-RECALL-FLOOR — recall/outlier floors + band pins under sweeps
//   + the two S2-reviewer residual probes (calibrated-subset region argmax;
//     2px sample inset on tiny strips)
//   + the demotion-tier separation measurement (tier updated 2026-07-09:
//     the demotion folds to an informational note; suppressing the note
//     entirely is a maintainer decision).
//
// Probe philosophy (RUN-ORDER §4, the precision-only bar): every probe carrying
// genuinely readable PII asserts the leak is still SURFACED — FAIL for clear
// in-region ink, at minimum WARN for the Option-A boundary cases. A clean PASS
// on readable ink is the one unacceptable outcome. Vision-dependent probes
// assert their own non-vacuity through a control variant Vision must read; any
// leg Vision cannot read on iOS 26.4 is asserted at the production-sampler
// level instead and reported `[S3-BATTERY] … e2e=UNREAD` (documented UNVERIFIED
// in the PR body, never silently dropped). All on-device probes pin iOS 26.4.
//
// Synthetic-fixture logging exemption as in the S1/S2 suite: every fixture here
// is built at test time from fictional text; production logging rules unchanged.
//
// This file carries the ON-DEVICE (Vision) probes + the shared harness; the
// pure probes (F-CHROMA-FORMULA, F-MIDBAND, F-STRADDLE-WIRING,
// F-PROPERTY-RECALL-FLOOR, the two reviewer residuals) live in the sibling
// `Layer2FillGuardBatteryPureTests` (new-file LOC cap, M-6).

@Suite("Part A — S3 adversarial fill-guard battery", .serialized)
struct Layer2FillGuardBatteryTests {

    /// The S1/S2 suite hosts the fixture loaders + raster builders (TestHelpers
    /// on the fixture side; `makeSecureRasterPage` and the OCR probes there).
    typealias Host = Layer2FillHallucinationGuardTests

    // MARK: - shared harness (internal — the pure sibling suite
    // `Layer2FillGuardBatteryPureTests` reuses these)

    static func manualRegion(_ r: CGRect) -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: r, source: .manual)
    }
    static func sample(_ fill: CGFloat, _ contrast: CGFloat, _ maxDev: CGFloat) -> VerificationEngine.BoxFillSample {
        VerificationEngine.BoxFillSample(fillFraction: fill, contrastFraction: contrast, maxDeviation: maxDev)
    }

    /// Run the REAL Layer-2 path (index 1) over a built page and return the layer
    /// status — the battery's end-to-end observable.
    static func layer2Status(
        pdf: Data,
        regions: [Int: [RedactionRegion]],
        sensitiveTerms: [String] = [],
        mode: PipelineMode = .secureRasterization
    ) async throws -> VerificationStatus {
        let doc = try #require(PDFDocument(data: pdf))
        let engine = VerificationEngine()
        let result = await engine.runLayer(
            1,
            outputDocument: SendablePDFDocument(doc),
            sourcePageCount: doc.pageCount,
            regions: regions,
            sensitiveTerms: sensitiveTerms,
            pipelineMode: mode,
            filterDigests: Array(repeating: nil, count: doc.pageCount),
            perPageModes: Array(repeating: mode, count: doc.pageCount))
        return result.status
    }

    /// In-region OCR word boxes of a built one-page PDF, run through the
    /// PRODUCTION sampler (`enrichWithFillSamples`) — the battery's measurement
    /// observable. Returns (text, box, sample) triples; empty when Vision reads
    /// nothing ≥0.5 inside the region (the caller decides whether that is a
    /// non-vacuity failure or an `e2e=UNREAD` report line).
    static func measuredInRegionSamples(
        pdf: Data,
        region: CGRect,
        regions: [RedactionRegion]
    ) throws -> [(text: String, box: CGRect, sample: VerificationEngine.BoxFillSample)] {
        let provider = try #require(CGDataProvider(data: pdf as CFData))
        let doc = try #require(CGPDFDocument(provider))
        let cg = try #require(doc.page(at: 1))
        let image = try #require(Host.embeddedOrRendered(cgPage: cg))
        let boxes = Host.inRegionOCRBoxes(cgPage: cg, region: region)
        let hits = boxes.map {
            VerificationEngine.OCRHit(box: $0.box, wordBoxes: [], text: $0.text, confidence: 0.9)
        }
        let enriched = VerificationEngine.enrichWithFillSamples(hits, image: image, regions: regions)
        return zip(boxes, enriched).compactMap { box, hit in
            hit.boxFill.first.map { (box.text, box.box, $0) }
        }
    }

    /// Sample an EXPLICIT box (no Vision) through the PRODUCTION sampler over a
    /// built page's embedded image — for legs Vision cannot read (chroma /
    /// reverse-video fallbacks) and for the rider probes.
    static func productionSample(
        pdf: Data,
        box: CGRect,
        regions: [RedactionRegion]
    ) throws -> VerificationEngine.BoxFillSample {
        let provider = try #require(CGDataProvider(data: pdf as CFData))
        let doc = try #require(CGPDFDocument(provider))
        let cg = try #require(doc.page(at: 1))
        let image = try #require(Host.embeddedOrRendered(cgPage: cg))
        return try productionSample(image: image, box: box, regions: regions)
    }

    /// Same, over an already-built CGImage (the hand-built rider rasters).
    static func productionSample(
        image: CGImage,
        box: CGRect,
        regions: [RedactionRegion]
    ) throws -> VerificationEngine.BoxFillSample {
        let hit = VerificationEngine.OCRHit(box: box, wordBoxes: [], text: "probe", confidence: 0.9)
        let enriched = VerificationEngine.enrichWithFillSamples([hit], image: image, regions: regions)
        return try #require(enriched.first?.boxFill.first)
    }

    // MARK: - shared harness: test-local mirrors (threshold sweeps)
    //
    // The shipped constants are private by design; the battery pins them
    // EMPIRICALLY (band-pin buffer + boundary probes in the pure sibling
    // suite) and sweeps hypothetical values through these mirrors. The
    // mirror-equivalence probe there asserts mirror ≡ production at the
    // shipped values, so the mirrors cannot drift silently if a constant is
    // ever retuned.

    /// Shipped values, pinned by `propertyFloors_pure` + `mirrorEquivalence`.
    static let shipped = (fillFloor: CGFloat(0.97), contrastCeil: CGFloat(0.03),
                          recallFloor: CGFloat(0.10), strongInk: CGFloat(0.50),
                          fillDistance: CGFloat(0.16), contrastDistance: CGFloat(0.12))

    /// Predicate mirror of `VerificationEngine.isFillConsistent` with tunable
    /// floors (band distances live in the SAMPLER, not here).
    static func mirrorConsistent(
        _ s: VerificationEngine.BoxFillSample,
        fillFloor: CGFloat = shipped.fillFloor,
        contrastCeil: CGFloat = shipped.contrastCeil,
        recallFloor: CGFloat = shipped.recallFloor,
        strongInk: CGFloat = shipped.strongInk
    ) -> Bool {
        if s.contrastFraction >= recallFloor { return false }
        if s.maxDeviation > strongInk { return false }
        return s.fillFraction >= fillFloor && s.contrastFraction <= contrastCeil
    }

    /// Sampler mirror of `VerificationEngine.boxFillSample` with tunable band
    /// distances, over a tightly-packed BGRA buffer (same byte order + BL→top
    /// flip as production). Used by the Δ_contrast sweep (F-WEBER-MARGIN) and
    /// the band-pin probes.
    static func mirrorSample(
        box: CGRect, bgra: [UInt8], width: Int, height: Int,
        fill: (r: CGFloat, g: CGFloat, b: CGFloat),
        fillDistance: CGFloat, contrastDistance: CGFloat
    ) -> VerificationEngine.BoxFillSample {
        let x0 = max(0, Int(box.minX * CGFloat(width)))
        let x1 = min(width, Int(box.maxX * CGFloat(width)))
        let y0 = max(0, Int((1 - box.maxY) * CGFloat(height)))
        let y1 = min(height, Int((1 - box.minY) * CGFloat(height)))
        guard x1 > x0, y1 > y0 else { return sample(0, 1, 1) }
        var fillCount = 0, contrastCount = 0, total = 0
        var maxDev: CGFloat = 0
        for y in y0..<y1 {
            let rowBase = y * width * 4
            for x in x0..<x1 {
                let off = rowBase + x * 4
                let b = CGFloat(bgra[off + 0]) / 255
                let g = CGFloat(bgra[off + 1]) / 255
                let r = CGFloat(bgra[off + 2]) / 255
                let dev = max(abs(r - fill.r), abs(g - fill.g), abs(b - fill.b))
                total += 1
                if dev <= fillDistance { fillCount += 1 }
                if dev >= contrastDistance { contrastCount += 1 }
                if dev > maxDev { maxDev = dev }
            }
        }
        guard total > 0 else { return sample(0, 1, 1) }
        return sample(CGFloat(fillCount) / CGFloat(total), CGFloat(contrastCount) / CGFloat(total), maxDev)
    }

    /// Decode a CGImage into the tightly-packed BGRA layout the mirrors sample
    /// (mirrors production's `createBitmapContext` byte order).
    static func bgraBuffer(of image: CGImage) throws -> (buf: [UInt8], width: Int, height: Int) {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        try buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                    | CGImageAlphaInfo.premultipliedFirst.rawValue
            ) else { throw BatteryError.contextFailed }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return (buf, w, h)
    }

    enum BatteryError: Error { case contextFailed }

    /// Uniform battery report line (grepped into the PR body's verdict table).
    static func report(_ probe: String, _ detail: String) {
        print("[S3-BATTERY] \(probe): \(detail)")
    }
    static func fmt(_ s: VerificationEngine.BoxFillSample) -> String {
        String(format: "fill=%.3f contrast=%.3f maxDev=%.3f", s.fillFraction, s.contrastFraction, s.maxDeviation)
    }

    // Shared probe geometry: a mid-page band region (bar) the on-device probes
    // paint and write into. Big enough that fitted text is comfortably within
    // Vision's readable size range at 200 dpi.
    static let bandRegion = CGRect(x: 0.15, y: 0.45, width: 0.50, height: 0.06)

    // MARK: - F-CHROMA-BLACK (on-device; e2e + production-sampler leg)

    /// Readable BLUE ink ON a black bar — luminance sits inside the fill band
    /// (the trap a luminance-only guard falls into); full-RGB reads the blue
    /// channel as contrast, so the box is KEPT and the page FAILs. The e2e leg
    /// depends on Vision reading low-luma ink at the frozen `.fast` preset; the
    /// production-sampler leg is asserted for EVERY blue regardless.
    @Test("F-CHROMA-BLACK: blue ink (luma ≈ fill) on a black bar is KEPT — never excluded (pin iOS 26.4)")
    func chromaBlack_onDevice() async throws {
        let region = Self.bandRegion
        // Rec.601 luma of (0,0,b): 0.114·(b/255) — 0.051 / 0.080 / 0.114, all
        // inside the fill band (< 0.16) on a black fill; blue-channel deviation
        // 0.451 / 0.706 / 1.000 — all ≥ the contrast band's edge. The two
        // ultralight variants cross chroma with hairline stroke weight (the S3
        // completeness review's top gap: a thin stroke caps the contrast SHARE
        // while chroma caps the PEAK deviation under the 0.50 outlier floor —
        // this measures whether both rescues can be starved at once).
        let ultralight = CTFontCreateWithName("HelveticaNeue-UltraLight" as CFString, 10, nil)
        let blues: [(name: String, b: CGFloat, font: CTFont?)] = [
            ("blue115", 115, nil), ("blue180", 180, nil), ("blue255", 255, nil),
            ("blue115-ultralight", 115, ultralight), ("blue255-ultralight", 255, ultralight)
        ]
        var e2eRead = false
        for blue in blues {
            let (pdf, regions) = try await Host.makeSecureRasterPage(
                text: "SABLEBROOK",
                textColor: CGColor(red: 0, green: 0, blue: blue.b / 255, alpha: 1),
                regionRects: [region],
                paintBars: true,
                font: blue.font,
                textOverBars: true)

            // Production-sampler leg (Vision-independent): a box over the glyph
            // band must NOT be fill-consistent — the blue deviation is contrast.
            let glyphBox = region.insetBy(dx: region.width * 0.10, dy: region.height * 0.15)
            let s = try Self.productionSample(pdf: pdf, box: glyphBox, regions: regions[0] ?? [])
            #expect(!VerificationEngine.isFillConsistent(s),
                    "\(blue.name): full-RGB sampling must read blue-on-black as contrast (\(Self.fmt(s)))")

            // e2e leg: if Vision reads the token, the page must FAIL (readable
            // in-region ink — the guard may not demote it).
            let status = try await Self.layer2Status(pdf: pdf, regions: regions)
            let pdfProvider = try #require(CGDataProvider(data: pdf as CFData))
            let pdfDoc = try #require(CGPDFDocument(pdfProvider))
            let page1 = try #require(pdfDoc.page(at: 1))
            let read = Host.inRegionOCRBoxes(cgPage: page1, region: region).count > 0
            if read {
                e2eRead = true
                #expect(status.isFail,
                        "\(blue.name): Vision read the blue token in-region — the page must FAIL, got \(status)")
            }
            Self.report("F-CHROMA-BLACK",
                        "\(blue.name) sampler=\(Self.fmt(s)) e2e=\(read ? "READ status=\(status)" : "UNREAD status=\(status)")")
        }
        // Non-vacuity is carried by the sampler leg for every blue; the e2e leg
        // is reported per blue (UNREAD legs go to the PR body as UNVERIFIED).
        Self.report("F-CHROMA-BLACK", "e2e coverage: \(e2eRead ? "at least one blue read by Vision" : "no blue read at .fast — e2e leg UNVERIFIED (sampler leg asserted)")")
    }

    // MARK: - F-EDGE-STRADDLE, leak variant (on-device)

    /// Readable ink poking PAST a correctly-painted bar. Option-A expectation,
    /// recalibrated with the out-of-region arm: the page is never a clean
    /// PASS — the visible tail surfaces through the out-of-region INFO note
    /// (readable non-redacted content is expected output for this mode, so the
    /// generic arm is informational; a tail matching a redacted term takes the
    /// term-specific WARN, and any readable box landing ≥0.5 in-region FAILs).
    /// Asserts surfaced-not-silent, NOT `isFail`.
    @Test("F-EDGE-STRADDLE (leak): ink past a painted bar surfaces (INFO floor), never a clean PASS (pin iOS 26.4)")
    func edgeStraddleLeak_onDevice() async throws {
        let region = CGRect(x: 0.10, y: 0.60, width: 0.42, height: 0.07)
        // Text spans the region's right edge: the in-region half is painted over
        // by the bar (draw-then-paint), the tail stays readable on the white page.
        let (pdf, regions) = try await Host.makeSecureRasterPage(
            text: "HARTWELL",
            regionRects: [region],
            paintBars: true,
            textRect: CGRect(x: 0.44, y: 0.60, width: 0.30, height: 0.07))

        let status = try await Self.layer2Status(pdf: pdf, regions: regions)
        Self.report("F-EDGE-STRADDLE-LEAK", "status=\(status)")
        #expect(status.isInfo || status.isWarn || status.isFail,
                "a readable straddle tail must surface (INFO note at minimum) — got \(status)")
        #expect(status != .pass, "never a clean PASS while readable ink is on the page")
    }

    // MARK: - F-EDGE-STRADDLE, hallucination variant == F-PARTA-REPLAY (on-device)

    /// The real driver boxes ARE edge-straddle hallucinations (they straddle the
    /// bar edge into white background — the Option-A motivation). The fixture
    /// must demote to the fill-artifact INFO note (tier updated 2026-07-09):
    /// the guard ENGAGED (not FAIL), and not a silent clean PASS either (the
    /// note stays visible in Verification Details — see
    /// `measure_separationTable_onDevice` for the measured separation).
    @Test("F-PARTA-REPLAY: the real fixture folds to the fill-artifact INFO note — guard engaged, not FAIL, not clean (pin iOS 26.4)")
    func edgeStraddleHallucination_replay() async throws {
        let data = try TestFixtures.fillHallucinationRedactedPDF()
        let regions = try Host.committedRegions()
        let status = try await Self.layer2Status(pdf: data, regions: regions)
        Self.report("F-PARTA-REPLAY", "status=\(status)")
        #expect(status.isInfo, "the fixture must fold to the INFO note — got \(status)")
        if case .info(let message) = status {
            #expect(message.contains("fill artifacts"),
                    "the note must be the fill-artifact demotion, not another INFO path — got \"\(message)\"")
        }
    }

    // MARK: - F-LOW-CONTRAST (on-device sweep)

    /// Dim gray ink ON the black bar, swept across the contrast band's lower
    /// edge (dev 0.118 / 0.176 / 0.220) + a white control. Every variant Vision
    /// reads must surface: dev ≥ Δ_contrast → KEPT → FAIL; dev inside the fill
    /// band (gray-30) may demote → WARN, never a clean PASS. Which dim variants
    /// Vision actually reads at `.fast` is MEASURED and reported — the design
    /// bet is that sub-Δ_contrast ink is not Vision-readable; a READ gray-30
    /// line in the report falsifies that bet and goes straight to the PR body.
    @Test("F-LOW-CONTRAST: dim in-region ink sweep — every read variant surfaces, no clean PASS (pin iOS 26.4)")
    func lowContrastSweep_onDevice() async throws {
        let region = Self.bandRegion
        let variants: [(name: String, gray: CGFloat, expectFailIfRead: Bool)] = [
            ("gray30(dev .118)", 30 / 255, false),   // inside the fill band — demote acceptable
            ("gray45(dev .176)", 45 / 255, true),    // contrast band — must be KEPT
            ("gray56(dev .220)", 56 / 255, true),    // contrast band — must be KEPT
            ("white(dev 1.0)", 1.0, true)            // control — must be read AND kept
        ]
        var controlRead = false
        for v in variants {
            let (pdf, regions) = try await Host.makeSecureRasterPage(
                text: "MERIDIAN",
                textColor: CGColor(gray: v.gray, alpha: 1),
                regionRects: [region],
                paintBars: true,
                textOverBars: true)
            let measured = try Self.measuredInRegionSamples(pdf: pdf, region: region, regions: regions[0] ?? [])
            let status = try await Self.layer2Status(pdf: pdf, regions: regions)
            let samplesText = measured.map { "\"\($0.text)\" \(Self.fmt($0.sample))" }.joined(separator: " · ")
            Self.report("F-LOW-CONTRAST", "\(v.name) read=\(measured.count) status=\(status) \(samplesText)")
            if !measured.isEmpty {
                #expect(status != .pass, "\(v.name): Vision read in-region ink — never a clean PASS, got \(status)")
                if v.expectFailIfRead {
                    #expect(status.isFail, "\(v.name): contrast-band ink must be KEPT → FAIL, got \(status)")
                }
            }
            if v.name.hasPrefix("white") {
                controlRead = !measured.isEmpty
                #expect(controlRead, "non-vacuity: Vision must read the white control on the bar")
                #expect(status.isFail, "white control must FAIL — got \(status)")
            }
        }
    }

    // MARK: - F-THIN-HIGH-CONTRAST (on-device sweep)

    /// Hairline white glyphs on the black bar across font weights + a bold
    /// control. A hairline's contrast share can sit under the recall floor —
    /// the OUTLIER floor (a single strong-ink pixel) is what keeps it. Every
    /// read variant must FAIL; the report shows which floor carried each verdict.
    @Test("F-THIN-HIGH-CONTRAST: hairline white glyphs on the bar are KEPT for every width Vision reads (pin iOS 26.4)")
    func thinHighContrast_onDevice() async throws {
        let region = Self.bandRegion
        let smallRegion = CGRect(x: 0.15, y: 0.30, width: 0.35, height: 0.025)
        let variants: [(name: String, font: CTFont, region: CGRect)] = [
            ("ultralight-large", CTFontCreateWithName("HelveticaNeue-UltraLight" as CFString, 10, nil), region),
            ("thin-large", CTFontCreateWithName("HelveticaNeue-Thin" as CFString, 10, nil), region),
            ("ultralight-small", CTFontCreateWithName("HelveticaNeue-UltraLight" as CFString, 10, nil), smallRegion),
            ("bold-control", CTFontCreateWithName("Helvetica-Bold" as CFString, 10, nil), region)
        ]
        var controlRead = false
        for v in variants {
            let (pdf, regions) = try await Host.makeSecureRasterPage(
                text: "1417 IlI",
                textColor: CGColor(gray: 1, alpha: 1),
                regionRects: [v.region],
                paintBars: true,
                font: v.font,
                textOverBars: true)
            let measured = try Self.measuredInRegionSamples(pdf: pdf, region: v.region, regions: regions[0] ?? [])
            let status = try await Self.layer2Status(pdf: pdf, regions: regions)
            let rows = measured.map { m in
                var floors: [String] = []
                if m.sample.contrastFraction >= Self.shipped.recallFloor { floors.append("recall") }
                if m.sample.maxDeviation > Self.shipped.strongInk { floors.append("outlier") }
                if m.sample.fillFraction < Self.shipped.fillFloor { floors.append("fill-floor") }
                if m.sample.contrastFraction > Self.shipped.contrastCeil { floors.append("ceil") }
                return "\"\(m.text)\" \(Self.fmt(m.sample)) refused-by=[\(floors.joined(separator: ","))]"
            }.joined(separator: " · ")
            Self.report("F-THIN", "\(v.name) read=\(measured.count) status=\(status) \(rows)")
            if !measured.isEmpty {
                #expect(status.isFail,
                        "\(v.name): readable white-on-bar ink must be KEPT → FAIL, got \(status)")
                for m in measured {
                    #expect(!VerificationEngine.isFillConsistent(m.sample),
                            "\(v.name) \"\(m.text)\": hairline ink must not be excluded (\(Self.fmt(m.sample)))")
                }
            }
            if v.name == "bold-control" {
                controlRead = !measured.isEmpty
                #expect(controlRead, "non-vacuity: Vision must read the bold control")
            }
        }
    }

    // MARK: - F-WEBER-MARGIN (on-device + the Δ_contrast band sweep)

    /// WHITE fill + pale-but-readable dark ink (Weber ~20%, dev ≈ 0.20), through
    /// JPEG q0.92. Under the shipped bands the pale ink is contrast (0.20 ≥
    /// 0.12) → KEPT. The sweep then shows WHY the no-dead-zone bound is the
    /// safety property: with the complementary bands capped at Δ_fill = 0.16
    /// the pale ink cannot be excluded; only a hypothetical loose Δ_contrast
    /// past the ink's own deviation (≥ ~0.17–0.25, the red-team's "FAILs at
    /// Δ_contrast ≥ 44/255" break) loses it.
    @Test("F-WEBER-MARGIN: pale ink on WHITE fill is KEPT under the shipped bands; the sweep locates the break (pin iOS 26.4)")
    func weberMargin_onDevice_andBandSweep() async throws {
        let region = Self.bandRegion
        let white = CGColor(gray: 1, alpha: 1)
        // dev from white fill: (255-204)/255 ≈ 0.200 (Weber ~20%).
        let (palePDF, paleRegions) = try await Host.makeSecureRasterPage(
            text: "WESTBROOK",
            textColor: CGColor(gray: 204 / 255, alpha: 1),
            fillColor: white,
            regionRects: [region],
            paintBars: true,
            textOverBars: true)
        // Control: dark ink on the white bar — must be read and KEPT.
        let (controlPDF, controlRegions) = try await Host.makeSecureRasterPage(
            text: "WESTBROOK",
            textColor: CGColor(gray: 40 / 255, alpha: 1),
            fillColor: white,
            regionRects: [region],
            paintBars: true,
            textOverBars: true)

        let controlMeasured = try Self.measuredInRegionSamples(pdf: controlPDF, region: region, regions: controlRegions[0] ?? [])
        let controlStatus = try await Self.layer2Status(pdf: controlPDF, regions: controlRegions)
        #expect(!controlMeasured.isEmpty, "non-vacuity: Vision must read the dark control on the white bar")
        #expect(controlStatus.isFail, "dark control on the white bar must FAIL — got \(controlStatus)")

        let paleMeasured = try Self.measuredInRegionSamples(pdf: palePDF, region: region, regions: paleRegions[0] ?? [])
        let paleStatus = try await Self.layer2Status(pdf: palePDF, regions: paleRegions)
        for m in paleMeasured {
            #expect(!VerificationEngine.isFillConsistent(m.sample),
                    "pale ink (dev ≈0.20) must be KEPT under the shipped bands (\(Self.fmt(m.sample)))")
        }
        if !paleMeasured.isEmpty {
            #expect(paleStatus.isFail, "Vision read the pale token — it must be KEPT → FAIL, got \(paleStatus)")
        }
        Self.report("F-WEBER", "control status=\(controlStatus) read=\(controlMeasured.count); pale status=\(paleStatus) read=\(paleMeasured.count) e2e=\(paleMeasured.isEmpty ? "UNREAD (sampler+sweep legs asserted)" : "READ")")

        // Band sweep over the pale ink's pixels (production layout mirror). The
        // sample box: measured word box when Vision read one, else the glyph band.
        let provider = try #require(CGDataProvider(data: palePDF as CFData))
        let doc = try #require(CGPDFDocument(provider))
        let cg = try #require(doc.page(at: 1))
        let image = try #require(Host.embeddedOrRendered(cgPage: cg))
        let (buf, w, h) = try Self.bgraBuffer(of: image)
        let sweepBox = paleMeasured.first?.box ?? region.insetBy(dx: region.width * 0.10, dy: region.height * 0.15)

        var keptAt: [CGFloat] = []
        var lostAt: [CGFloat] = []
        // Spec sweep {36,40,44,48,52,64}/255 + the shipped 0.12. Δ_fill rides at
        // max(Δ_contrast, 0.16) so the mirror stays complementary (no dead zone).
        for dc255 in [CGFloat(30.6), 36, 40, 44, 48, 52, 64] {
            let dc = dc255 / 255
            let s = Self.mirrorSample(box: sweepBox, bgra: buf, width: w, height: h,
                                      fill: (1, 1, 1),
                                      fillDistance: max(dc, Self.shipped.fillDistance),
                                      contrastDistance: dc)
            let kept = !Self.mirrorConsistent(s)
            if kept { keptAt.append(dc255) } else { lostAt.append(dc255) }
            Self.report("F-WEBER-SWEEP", String(format: "Δc=%.0f/255 %@ → %@", dc255, Self.fmt(s), kept ? "KEPT" : "EXCLUDED"))
        }
        // Shipped Δ_contrast (30.6/255 = 0.12) must keep the pale ink, and no
        // complementary band ≤ Δ_fill (36, 40/255 ≤ 0.16) may lose it. The break
        // may only appear past the no-dead-zone cap — the red-team's loose-band
        // regime (≥ 44/255).
        #expect(keptAt.contains(30.6), "the shipped Δ_contrast must keep the pale ink")
        #expect(!lostAt.contains(where: { $0 <= 40.8 }),
                "no Δ_contrast within the no-dead-zone cap (≤ Δ_fill = 0.16 ≈ 40.8/255) may lose the pale ink — lost at \(lostAt)")
        #expect(!lostAt.isEmpty,
                "the sweep must locate the loose-band break past the cap (red-team: ≥44/255) — measured keep=\(keptAt) lose=\(lostAt)")
    }

    // MARK: - F-REVERSE-VIDEO (on-device)

    /// Knockout glyphs: fill-coloured body, thin WHITE rim on the black bar.
    /// The rim's deviation is 1.0 → the outlier floor blocks exclusion even
    /// when the rim's pixel share sits under the recall floor.
    @Test("F-REVERSE-VIDEO: outline glyphs (fill-coloured body, contrasting rim) are KEPT (pin iOS 26.4)")
    func reverseVideo_onDevice() async throws {
        let region = Self.bandRegion
        let (pdf, regions) = try await Host.makeSecureRasterPage(
            text: "VOID 8250",
            textColor: CGColor(gray: 1, alpha: 1),
            regionRects: [region],
            paintBars: true,
            textOverBars: true,
            strokeWidth: 3,                       // positive = stroke-ONLY (body unpainted)
            strokeColor: CGColor(gray: 1, alpha: 1))

        // Production-sampler leg (Vision-independent): the rim is a strong-ink
        // outlier — a box over the glyph band must not be excluded.
        let glyphBox = region.insetBy(dx: region.width * 0.10, dy: region.height * 0.15)
        let s = try Self.productionSample(pdf: pdf, box: glyphBox, regions: regions[0] ?? [])
        #expect(!VerificationEngine.isFillConsistent(s),
                "the white rim must block exclusion (\(Self.fmt(s)))")

        let measured = try Self.measuredInRegionSamples(pdf: pdf, region: region, regions: regions[0] ?? [])
        let status = try await Self.layer2Status(pdf: pdf, regions: regions)
        if !measured.isEmpty {
            #expect(status.isFail, "Vision read the outline glyphs — must be KEPT → FAIL, got \(status)")
            for m in measured {
                #expect(!VerificationEngine.isFillConsistent(m.sample),
                        "outline glyph \"\(m.text)\" must be KEPT (\(Self.fmt(m.sample)))")
            }
        }
        Self.report("F-REVERSE-VIDEO", "sampler=\(Self.fmt(s)) e2e=\(measured.isEmpty ? "UNREAD (sampler leg asserted)" : "READ status=\(status)")")
    }

    // MARK: - demotion-tier separation measurement

    /// The measured separation between the real hallucination drivers and every
    /// readable-leak class this battery exercises, through the PRODUCTION
    /// sampler. Asserts the partition (drivers demote; leak ink is kept) and
    /// prints the table + margins for the PR body and the guard's doc comments.
    /// Demotion tier updated 2026-07-09: the fold is an informational note,
    /// visible in Verification Details; suppressing the note entirely stays a
    /// Maintainer decision, presented with this data, not decided here.
    @Test("measure: driver-vs-leak separation table + margins (pin iOS 26.4)")
    func measure_separationTable_onDevice() async throws {
        var driverSamples: [(String, VerificationEngine.BoxFillSample)] = []
        var leakSamples: [(String, VerificationEngine.BoxFillSample)] = []

        // Drivers: the real fixture's in-region hallucination boxes, production
        // sampler (the S2 measurement path, aggregated here for the table).
        let data = try TestFixtures.fillHallucinationRedactedPDF()
        let provider = try #require(CGDataProvider(data: data as CFData))
        let pdf = try #require(CGPDFDocument(provider))
        let regions = try Host.committedRegions()
        for pageIdx in [1, 2] {
            guard let cg = pdf.page(at: pageIdx + 1),
                  let image = Host.embeddedOrRendered(cgPage: cg) else { continue }
            let drivers = Host.fillDrivers(cgPage: cg)
            let hits = drivers.map { VerificationEngine.OCRHit(box: $0.box, wordBoxes: [], text: $0.text, confidence: 0.9) }
            let enriched = VerificationEngine.enrichWithFillSamples(hits, image: image, regions: regions[pageIdx] ?? [])
            for (d, h) in zip(drivers, enriched) {
                guard let s = h.boxFill.first else { continue }
                driverSamples.append(("p\(pageIdx + 1) \"\(d.text)\"", s))
            }
        }
        #expect(driverSamples.count >= 1, "the table needs ≥1 real driver (non-vacuous)")

        // Leak classes: recall raster (black ink, unpainted region) + blue-on-
        // black chroma + pale-on-white Weber + hairline white — via the same
        // production path (word boxes where Vision reads them, glyph-band boxes
        // where it does not; both sample real ink pixels).
        let recallRegion = CGRect(x: 0.12, y: 0.74, width: 0.70, height: 0.07)
        let (recallPDF, recallRegions) = try await Host.makeSecureRasterPage(
            text: "READABLE LEAK MARKER", regionRects: [recallRegion], paintBars: false)
        for m in try Self.measuredInRegionSamples(pdf: recallPDF, region: recallRegion, regions: recallRegions[0] ?? []) {
            leakSamples.append(("recall \"\(m.text)\"", m.sample))
        }
        #expect(!leakSamples.isEmpty, "the recall raster must contribute measured leak ink (non-vacuous)")

        let band = Self.bandRegion
        let glyphBox = band.insetBy(dx: band.width * 0.10, dy: band.height * 0.15)
        let leakBuilders: [(String, CGColor, CGColor)] = [
            ("chroma blue115", CGColor(red: 0, green: 0, blue: 115 / 255, alpha: 1), CGColor(gray: 0, alpha: 1)),
            ("pale gray204/white", CGColor(gray: 204 / 255, alpha: 1), CGColor(gray: 1, alpha: 1)),
            ("hairline white/black", CGColor(gray: 1, alpha: 1), CGColor(gray: 0, alpha: 1))
        ]
        // Ink classes Vision cannot read at the frozen `.fast` preset produce NO
        // OCR hits — Layer-2's sensor floor, identical before the guard (the
        // guard only acts on hits that exist). Their glyph-band samples are
        // reported in their own class: WARN-bounded when fill-consistent (a
        // hypothetical box demotes — never a clean PASS), KEPT when the sample
        // reads the ink's contrast.
        var sensorFloorSamples: [(String, VerificationEngine.BoxFillSample)] = []
        for (name, ink, fill) in leakBuilders {
            let font = name.hasPrefix("hairline")
                ? CTFontCreateWithName("HelveticaNeue-UltraLight" as CFString, 10, nil) : nil
            let (pdfData, regionMap) = try await Host.makeSecureRasterPage(
                text: "SABLEBROOK", textColor: ink, fillColor: fill,
                regionRects: [band], paintBars: true, font: font, textOverBars: true)
            let measured = try Self.measuredInRegionSamples(pdf: pdfData, region: band, regions: regionMap[0] ?? [])
            if measured.isEmpty {
                let s = try Self.productionSample(pdf: pdfData, box: glyphBox, regions: regionMap[0] ?? [])
                sensorFloorSamples.append(("\(name) [band, Vision-unread]", s))
            } else {
                for m in measured { leakSamples.append(("\(name) \"\(m.text)\"", m.sample)) }
            }
        }

        // The table + the partition assertions.
        for (name, s) in driverSamples {
            Self.report("SEPARATION", "driver \(name) \(Self.fmt(s))")
            #expect(VerificationEngine.isFillConsistent(s), "driver \(name) must demote (\(Self.fmt(s)))")
        }
        for (name, s) in leakSamples {
            Self.report("SEPARATION", "leak   \(name) \(Self.fmt(s))")
            #expect(!VerificationEngine.isFillConsistent(s), "readable leak \(name) must be KEPT (\(Self.fmt(s)))")
        }
        for (name, s) in sensorFloorSamples {
            // Below the sensor floor there is nothing for Layer-2 to keep; the
            // bound that must hold: a hypothetical in-region box over this ink
            // is at worst DEMOTED to the fill-artifact WARN — never a clean PASS.
            let hypothetical = VerificationEngine.classifyPageOCR(
                hits: [VerificationEngine.OCRHit(box: glyphBox, wordBoxes: [], text: "probe",
                                                 confidence: 0.9, boxFill: [s])],
                pageRegions: [Self.manualRegion(band)], sensitiveTerms: [])
            Self.report("SEPARATION", "sensor-floor \(name) \(Self.fmt(s)) hypothetical=\(hypothetical)")
            #expect(hypothetical == .fillArtifactInRegion || hypothetical == .textInRegion,
                    "a sensor-floor box is WARN-bounded or KEPT — never silent — got \(hypothetical)")
        }

        // Margins vs the shipped floors — the numbers quoted in the constants'
        // doc comments and the PR body. Readable-leak margins only; the
        // sensor-floor class is reported above.
        let dMaxContrast = driverSamples.map(\.1.contrastFraction).max() ?? 1
        let dMinFill = driverSamples.map(\.1.fillFraction).min() ?? 0
        let dMaxDev = driverSamples.map(\.1.maxDeviation).max() ?? 1
        let lMinContrast = leakSamples.map(\.1.contrastFraction).min() ?? 0
        let lMinFill = leakSamples.map(\.1.fillFraction).min() ?? 0
        Self.report("SEPARATION", String(
            format: "margins: drivers fill≥%.3f (floor .97) contrast≤%.3f (ceil .03) maxDev≤%.3f (outlier .50) | readable leaks contrast≥%.3f fill≥%.3f",
            dMinFill, dMaxContrast, dMaxDev, lMinContrast, lMinFill))
        #expect(dMinFill >= Self.shipped.fillFloor && dMaxContrast <= Self.shipped.contrastCeil
                && dMaxDev <= Self.shipped.strongInk,
                "every driver sits inside the demotion region with measurable margin")
        // Per-row keep already asserted above; the aggregate line documents the
        // separation (drivers contrast 0.000 vs the nearest readable leak).
        #expect(lMinContrast > dMaxContrast,
                "the readable-leak contrast distribution must sit strictly above the drivers'")
    }
}
