import Foundation
import CoreGraphics
import Testing
@testable import RedactionEngine

// PART A — S3 adversarial battery, PURE probes (no Vision, no PDF): the
// formula-independence, canary, wiring, property-floor, and S2-reviewer
// residual probes. Split from `Layer2FillGuardBatteryTests` (the on-device
// half + the shared harness) to respect the new-file LOC cap (M-6); read that
// file's header for the battery map and probe philosophy.

@Suite("Part A — S3 fill-guard battery (pure probes)", .serialized)
struct Layer2FillGuardBatteryPureTests {

    /// The on-device battery suite hosts the shared harness (samples, mirrors,
    /// production-sampler probes, report lines).
    typealias Battery = Layer2FillGuardBatteryTests

    /// Hand-built full-RGB raster for the rider probes (no PDF, no Vision):
    /// bottom-left CG coordinates, so normalized rects map directly.
    private static func flatImage(width: Int, height: Int, draw: (CGContext, Int, Int) -> Void) throws -> CGImage {
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw Battery.BatteryError.contextFailed }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(ctx, width, height)
        guard let img = ctx.makeImage() else { throw Battery.BatteryError.contextFailed }
        return img
    }

    // MARK: - F-CHROMA-FORMULA (pure; formula-independence per channel)

    /// Exclusion is forbidden when ANY single RGB channel deviates at/over the
    /// contrast band on at least the recall floor's share of pixels — no channel
    /// weighting (Chebyshev) can hide single-channel ink.
    @Test("F-CHROMA-FORMULA: any single-channel deviation ≥ Δ_contrast on ≥10% of pixels blocks exclusion")
    func chromaFormula_perChannel() {
        // 20% ink rows on a black fill; the ink deviates on exactly one channel.
        for (label, ink) in [("R", (CGFloat(0.13), CGFloat(0), CGFloat(0))),
                             ("G", (CGFloat(0), CGFloat(0.45), CGFloat(0))),
                             ("B", (CGFloat(0), CGFloat(0), CGFloat(1.0)))] {
            var buf = [UInt8](repeating: 0, count: 10 * 10 * 4)
            for y in 0..<10 {
                for x in 0..<10 {
                    let off = (y * 10 + x) * 4
                    if y < 2 {   // BGRA byte order
                        buf[off + 0] = UInt8(ink.2 * 255)
                        buf[off + 1] = UInt8(ink.1 * 255)
                        buf[off + 2] = UInt8(ink.0 * 255)
                    }
                    buf[off + 3] = 255
                }
            }
            let s = buf.withUnsafeBufferPointer {
                VerificationEngine.boxFillSample(
                    box: CGRect(x: 0, y: 0, width: 1, height: 1),
                    rgba: $0.baseAddress!, width: 10, height: 10, bytesPerRow: 40,
                    fill: (0, 0, 0))
            }
            #expect(s.contrastFraction >= Battery.shipped.recallFloor,
                    "\(label)-only deviation must land in the contrast band (\(Battery.fmt(s)))")
            #expect(!VerificationEngine.isFillConsistent(s),
                    "\(label)-only ink must block exclusion (\(Battery.fmt(s)))")
        }
    }

    // MARK: - F-MIDBAND (pure canary)

    /// Sparse mid-gray ink (dev 0.188, 6% of the box): under the SHIPPED floors
    /// the fill floor refuses it (0.94 < 0.97) — under a loosened tuning
    /// (fillFloor 0.90 / contrastCeil 0.10) the same sample WOULD be excluded.
    /// The canary pins which floor is load-bearing for the sparse-midband class,
    /// so any future loosening trips this test.
    @Test("F-MIDBAND: sparse mid-gray is refused by the shipped fill floor; a loosened mirror would exclude it (canary)")
    func midbandCanary_pure() {
        var buf = [UInt8](repeating: 0, count: 100 * 100 * 4)
        for y in 0..<100 {
            for x in 0..<100 {
                let off = (y * 100 + x) * 4
                let v: UInt8 = y < 6 ? 48 : 0   // 6 ink rows of gray-48 (dev 0.188)
                buf[off + 0] = v; buf[off + 1] = v; buf[off + 2] = v; buf[off + 3] = 255
            }
        }
        let s = buf.withUnsafeBufferPointer {
            VerificationEngine.boxFillSample(
                box: CGRect(x: 0, y: 0, width: 1, height: 1),
                rgba: $0.baseAddress!, width: 100, height: 100, bytesPerRow: 400,
                fill: (0, 0, 0))
        }
        Battery.report("F-MIDBAND", Battery.fmt(s))
        #expect(abs(s.contrastFraction - 0.06) < 0.005, "the fixture is built to 6% contrast (\(Battery.fmt(s)))")
        #expect(!VerificationEngine.isFillConsistent(s),
                "sparse mid-gray must be refused under the shipped floors (\(Battery.fmt(s)))")
        #expect(Battery.mirrorConsistent(s, fillFloor: 0.90, contrastCeil: 0.10),
                "the loosened mirror (fillFloor .90 / ceil .10) WOULD exclude this sample — the canary demonstrating the shipped fill floor is the load-bearing floor here")
    }

    // MARK: - F-STRADDLE-WIRING (pure classifier)

    /// Demote-never-silence at the fold: (a) a demoted in-region box with an
    /// out-of-region inked sibling folds to the fill-artifact WARN — the sibling
    /// signal survives, the page is never clean; (b) the single-box Option-A
    /// straddle residual (box ≥0.5 over the bar, in-rect sample solid) demotes
    /// to the WARN — never `.none`.
    @Test("F-STRADDLE-WIRING: a fill-excluded box never silences, and the straddle residual is WARN-bounded")
    func straddleWiring_pure() {
        let region = Battery.manualRegion(CGRect(x: 0.40, y: 0.40, width: 0.20, height: 0.20))

        // (a) demoted box + inked out-of-region sibling word box.
        let siblings = VerificationEngine.OCRHit(
            box: CGRect(x: 0.10, y: 0.40, width: 0.80, height: 0.20),
            wordBoxes: [CGRect(x: 0.42, y: 0.42, width: 0.16, height: 0.16),
                        CGRect(x: 0.05, y: 0.80, width: 0.15, height: 0.05)],
            text: "x", confidence: 0.9,
            boxFill: [Battery.sample(1.0, 0.0, 0.01), Battery.sample(0.0, 1.0, 1.0)])
        let a = VerificationEngine.classifyPageOCR(hits: [siblings], pageRegions: [region], sensitiveTerms: [])
        #expect(a == .fillArtifactInRegion, "the fold must carry the WARN — got \(a)")
        #expect(a != PageOCRFindingNone.none, "never .none while any box is on the page")

        // (b) the single-box Option-A residual: a straddle box ≥0.5 over the bar
        // whose in-rect sample is solid fill (the out-of-rect ink is not sampled
        // under box∩rect). Locked expectation: demotes to WARN, never a clean PASS.
        let straddle = VerificationEngine.OCRHit(
            box: CGRect(x: 0.38, y: 0.45, width: 0.28, height: 0.10),   // ~64% over the region
            wordBoxes: [], text: "tail", confidence: 0.9,
            boxFill: [Battery.sample(1.0, 0.0, 0.005)])
        let b = VerificationEngine.classifyPageOCR(hits: [straddle], pageRegions: [region], sensitiveTerms: [])
        #expect(b == .fillArtifactInRegion,
                "the Option-A straddle residual is bounded at the fill-artifact WARN — got \(b)")
    }
    // Typed helper so the `.none` comparison reads unambiguously above.
    private typealias PageOCRFindingNone = VerificationEngine.PageOCRFinding

    // MARK: - F-PROPERTY-RECALL-FLOOR (pure; floors + band pins)

    /// The structural floors hold over the sample grid, the shipped constants
    /// are pinned at their exact boundaries, and the band distances are pinned
    /// through the production sampler (including the no-dead-zone overlap).
    @Test("F-PROPERTY-RECALL-FLOOR: recall/outlier floors hold over the grid; constants + bands pinned at their boundaries")
    func propertyFloors_pure() throws {
        // Recall floor: contrast ≥ 0.10 is never excluded, at ANY fill/outlier.
        for contrast in [CGFloat(0.10), 0.12, 0.30, 1.0] {
            for fill in [CGFloat(0.0), 0.90, 0.97, 1.0] {
                for maxDev in [CGFloat(0.0), 0.50, 1.0] {
                    #expect(!VerificationEngine.isFillConsistent(Battery.sample(fill, contrast, maxDev)),
                            "recall floor: (\(fill), \(contrast), \(maxDev)) must never be excluded")
                }
            }
        }
        // Outlier floor: one strong-ink pixel blocks exclusion at ANY fill.
        for maxDev in [CGFloat(0.501), 0.70, 1.0] {
            for contrast in [CGFloat(0.0), 0.02] {
                for fill in [CGFloat(0.97), 1.0] {
                    #expect(!VerificationEngine.isFillConsistent(Battery.sample(fill, contrast, maxDev)),
                            "outlier floor: (\(fill), \(contrast), \(maxDev)) must never be excluded")
                }
            }
        }
        // Boundary pins (inclusive/exclusive edges of the shipped constants).
        #expect(VerificationEngine.isFillConsistent(Battery.sample(0.97, 0.03, 0.50)),
                "the demotion region's corner (fill .97, contrast .03, maxDev .50) is inside")
        #expect(!VerificationEngine.isFillConsistent(Battery.sample(0.9699, 0.03, 0.50)), "fill floor pins at 0.97")
        #expect(!VerificationEngine.isFillConsistent(Battery.sample(0.97, 0.0301, 0.50)), "contrast ceiling pins at 0.03")
        #expect(!VerificationEngine.isFillConsistent(Battery.sample(0.97, 0.03, 0.5001)), "outlier floor pins at 0.50")
        #expect(VerificationEngine.isFillConsistent(Battery.sample(1.0, 0.0, 0.0)), "byte-exact fill demotes")

        // Band pins through the production sampler: uniform-deviation buffers.
        // dev 0.1098 → fill only; 0.1294/0.1490 → BOTH bands (the no-dead-zone
        // overlap: Δ_contrast ≤ Δ_fill); 0.1725 → contrast only. Pins
        // Δ_contrast ∈ (0.1098, 0.1294] and Δ_fill ∈ [0.1490, 0.1725) around
        // the shipped 0.12 / 0.16.
        let bandProbes: [(byte: UInt8, expectFill: CGFloat, expectContrast: CGFloat)] = [
            (28, 1.0, 0.0), (33, 1.0, 1.0), (38, 1.0, 1.0), (44, 0.0, 1.0)
        ]
        for probe in bandProbes {
            var buf = [UInt8](repeating: 0, count: 8 * 8 * 4)
            for i in 0..<(8 * 8) {
                buf[i * 4 + 0] = probe.byte; buf[i * 4 + 1] = probe.byte
                buf[i * 4 + 2] = probe.byte; buf[i * 4 + 3] = 255
            }
            let s = buf.withUnsafeBufferPointer {
                VerificationEngine.boxFillSample(
                    box: CGRect(x: 0, y: 0, width: 1, height: 1),
                    rgba: $0.baseAddress!, width: 8, height: 8, bytesPerRow: 32,
                    fill: (0, 0, 0))
            }
            #expect(s.fillFraction == probe.expectFill && s.contrastFraction == probe.expectContrast,
                    "band pin at dev \(probe.byte)/255: expected fill=\(probe.expectFill) contrast=\(probe.expectContrast), got \(Battery.fmt(s))")
        }

        // Mirror equivalence at the shipped values, over the grid + boundaries —
        // the sweep mirrors cannot drift from production while this holds.
        var mismatches = 0
        for fill in stride(from: CGFloat(0.90), through: 1.0, by: 0.01) {
            for contrast in stride(from: CGFloat(0.0), through: 0.15, by: 0.01) {
                for maxDev in [CGFloat(0.0), 0.3, 0.5, 0.51, 1.0] {
                    let s = Battery.sample(fill, contrast, maxDev)
                    if VerificationEngine.isFillConsistent(s) != Battery.mirrorConsistent(s) { mismatches += 1 }
                }
            }
        }
        #expect(mismatches == 0, "the test-local predicate mirror must match production at the shipped constants")
    }

    // MARK: - S2 reviewer residual 1: calibrated-subset region argmax

    /// A box whose true region fails calibration (a sub-pixel strip that
    /// survives the >0.001 snapshot gate) while overlapping a calibrated solid
    /// bar MORE by area: the argmax samples the bar's geometry, the strip's ink
    /// never enters the sample, and the box demotes. Locked bound (S2 review,
    /// adjudicated non-blocking): FAIL→WARN, never a clean PASS. This probe
    /// pins that bound through the production sampler + classifier.
    @Test("residual-1: calibration-nil strip + calibrated-bar argmax stays WARN-bounded (never clean)")
    func rider_calibrationSubsetArgmax() throws {
        let width = 500, height = 500
        // Bottom half: solid black painted bar (region B — calibrates to black).
        // Strip region A (h = 0.0011 → 0.55px at 500px: survives the snapshot
        // gate, collapses to a zero-pixel calibration probe → nil) sits over
        // black "ink" rows drawn at y ∈ [0.50, 0.58] on the white top half.
        let regionB = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 0.50)
        let regionA = CGRect(x: 0.10, y: 0.55, width: 0.50, height: 0.0011)
        let image = try Self.flatImage(width: width, height: height) { ctx, w, h in
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h / 2))                      // bar B
            ctx.fill(CGRect(x: Int(0.12 * CGFloat(w)), y: Int(0.52 * CGFloat(h)),
                            width: Int(0.25 * CGFloat(w)), height: Int(0.04 * CGFloat(h))))  // "ink"
        }
        let regions = [Battery.manualRegion(regionA), Battery.manualRegion(regionB)]
        // Both regions survive the production snapshot (the classifier and the
        // sampler see the same set).
        #expect(VerificationEngine.layer2RegionSnapshot(regions).count == 2,
                "the strip must survive the >0.001 snapshot gate for this trigger")

        // The box straddles: ∩B = its lower 62.5% (area argmax → B, and the
        // whole-box coverage in B clears the ≥0.5 in-region threshold with
        // margin); the ink sits in its top part, outside B.
        let box = CGRect(x: 0.10, y: 0.40, width: 0.30, height: 0.16)
        let hit = VerificationEngine.OCRHit(box: box, wordBoxes: [], text: "ink", confidence: 0.9)
        let enriched = VerificationEngine.enrichWithFillSamples([hit], image: image, regions: regions)
        let s = try #require(enriched.first?.boxFill.first)

        // The argmax picked B: the sample is the solid bar (the ink is out of
        // sample) — this is the residual, demonstrated concretely.
        #expect(VerificationEngine.isFillConsistent(s),
                "the residual's trigger: the box samples the calibrated bar, not its ink (\(Battery.fmt(s)))")
        let wholeBox = try Battery.productionSample(image: image, box: CGRect(x: 0.10, y: 0.51, width: 0.30, height: 0.06),
                                                 regions: [Battery.manualRegion(CGRect(x: 0, y: 0.5, width: 1, height: 0.5))])
        #expect(wholeBox.contrastFraction > 0, "the ink is real — a sample over it reads contrast (\(Battery.fmt(wholeBox)))")

        // The BOUND: the verdict is the fill-artifact WARN — never .none/clean.
        let verdict = VerificationEngine.classifyPageOCR(hits: enriched, pageRegions: regions, sensitiveTerms: [])
        Battery.report("RESIDUAL-1", "sample=\(Battery.fmt(s)) verdict=\(verdict)")
        #expect(verdict == .fillArtifactInRegion,
                "the residual folds to the fill-artifact WARN — never a clean PASS — got \(verdict)")
    }

    // MARK: - S2 reviewer residual 2: the 2px sample inset on tiny strips

    /// Thin-strip sample geometry through the PRODUCTION sampler: (a) ink 2px
    /// inside a 12px strip's sample survives the 2px inset → KEPT; (b) a 3px
    /// strip's inset collapses → the un-inset fallback samples the ink → KEPT;
    /// (c) ink hugging the strip's edge is trimmed by the inset → demotes —
    /// the documented WARN-bounded residual, pinned here.
    @Test("residual-2: the 2px inset keeps interior hairline ink on tiny strips; edge-hugging ink is WARN-bounded")
    func rider_insetTinyStrips() throws {
        let width = 800, height = 800
        let stripHeightPx: CGFloat = 12
        let strip = CGRect(x: 0.10, y: 0.50, width: 0.60, height: stripHeightPx / CGFloat(height))

        func stripImage(inkRowOffset: Int) throws -> CGImage {
            try Self.flatImage(width: width, height: height) { ctx, w, h in
                ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                ctx.fill(CGRect(x: Int(strip.minX * CGFloat(w)), y: Int(strip.minY * CGFloat(h)),
                                width: Int(strip.width * CGFloat(w)), height: Int(stripHeightPx)))
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))   // 1px white hairline "ink"
                ctx.fill(CGRect(x: Int(0.15 * CGFloat(w)), y: Int(strip.minY * CGFloat(h)) + inkRowOffset,
                                width: Int(0.20 * CGFloat(w)), height: 1))
            }
        }
        // The box covers the ink's stretch of the strip (box∩rect = that stretch).
        let box = CGRect(x: 0.15, y: strip.minY, width: 0.20, height: strip.height)

        // (a) ink 2px above the strip's bottom edge: the 2px inset trims rows
        // 0–1 and the ink row survives → outlier floor keeps it.
        let interior = try Battery.productionSample(image: try stripImage(inkRowOffset: 2),
                                                 box: box, regions: [Battery.manualRegion(strip)])
        Battery.report("RESIDUAL-2", "interior-ink \(Battery.fmt(interior))")
        #expect(!VerificationEngine.isFillConsistent(interior),
                "interior hairline ink must survive the 2px inset (\(Battery.fmt(interior)))")

        // (b) a 3px strip: the inset collapses, the un-inset fallback samples
        // the ink → KEPT.
        let tiny = CGRect(x: 0.10, y: 0.30, width: 0.60, height: 3.0 / CGFloat(height))
        let tinyImage = try Self.flatImage(width: width, height: height) { ctx, w, h in
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: Int(tiny.minX * CGFloat(w)), y: Int(tiny.minY * CGFloat(h)),
                            width: Int(tiny.width * CGFloat(w)), height: 3))
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: Int(0.15 * CGFloat(w)), y: Int(tiny.minY * CGFloat(h)) + 1,
                            width: Int(0.20 * CGFloat(w)), height: 1))
        }
        let tinyBox = CGRect(x: 0.15, y: tiny.minY, width: 0.20, height: tiny.height)
        let collapsed = try Battery.productionSample(image: tinyImage, box: tinyBox, regions: [Battery.manualRegion(tiny)])
        Battery.report("RESIDUAL-2", "collapsed-inset \(Battery.fmt(collapsed))")
        #expect(!VerificationEngine.isFillConsistent(collapsed),
                "the collapsed-inset fallback must still see the ink (\(Battery.fmt(collapsed)))")

        // (c) edge-hugging ink (row 0): the inset trims it → the sample is the
        // solid strip → demotes. The documented residual bound: FAIL→WARN via
        // the fill-artifact fold, never a clean PASS (see straddleWiring_pure).
        let edge = try Battery.productionSample(image: try stripImage(inkRowOffset: 0),
                                             box: box, regions: [Battery.manualRegion(strip)])
        let edgeVerdict = VerificationEngine.classifyPageOCR(
            hits: [VerificationEngine.OCRHit(box: box, wordBoxes: [], text: "ink", confidence: 0.9,
                                             boxFill: [edge])],
            pageRegions: [Battery.manualRegion(strip)], sensitiveTerms: [])
        Battery.report("RESIDUAL-2", "edge-ink \(Battery.fmt(edge)) verdict=\(edgeVerdict)")
        if VerificationEngine.isFillConsistent(edge) {
            #expect(edgeVerdict == .fillArtifactInRegion,
                    "edge-trimmed ink demotes to the WARN — never a clean PASS — got \(edgeVerdict)")
        } else {
            // JPEG-free flat raster can keep a residual edge pixel in sample —
            // then the ink is simply KEPT (stronger than the bound requires).
            #expect(edgeVerdict == .textInRegion, "edge ink kept → textInRegion — got \(edgeVerdict)")
        }
    }
}
