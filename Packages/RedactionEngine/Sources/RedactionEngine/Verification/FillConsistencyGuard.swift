import Foundation
import PDFKit
import Vision
import ImageIO
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// The Layer-2 fill-consistency guard (Part A, chroma-aware, demote-never-silence): the
// thresholds, the per-box fill statistics, the self-calibrated fill colour and the
// enrichment of OCR hits with fill samples. Moved whole from VerificationEngine.swift; no
// line inside a moved body changes.

extension VerificationEngine {

    // MARK: - Layer-2 fill-consistency guard (Part A — chroma-aware, demote-never-silence)
    //
    // Secure Rasterization paints solid, `verifyFill`-proven fill bars (black OR
    // white). Vision, OCRing the rasterized output with the frozen preset,
    // hallucinates short tokens OUT OF the bars; their boxes sit ≥ 0.5 inside the
    // (correct) region rect → a secure-raster FAIL with no surviving PII. This
    // guard tells such a fill artifact (near-uniform fill, no readable contrast)
    // from genuine in-region ink, and DEMOTES the false FAIL to an informational
    // note. It can never silence a real leak: real readable ink — including
    // coloured ink whose luminance ≈ the fill — necessarily lands in the contrast
    // band or trips the outlier floor, so it is KEPT; and a demoted box still
    // yields at least an informational note in Verification Details (it can never
    // produce a silent clean PASS). Thresholds were landed at the original
    // strict values and finalized unchanged by an adversarial battery
    // (`Layer2FillGuardBatteryTests`, iOS 26.4): the real drivers measure
    // byte-exact fill (1.000 / 0.000 / maxDev ≤ 0.012) while every readable-leak
    // class the battery could surface through Vision holds a wide margin on at
    // least one floor (per-constant margins below). Demotion tier (updated
    // 2026-07-09): the demotion folds to an informational note — visible in
    // Verification Details, never affecting pass/fail — on BOTH page modes; any
    // further promotion of provable tier-1 boxes (e.g. suppressing the note
    // entirely) would be a policy change, not a tuning.

    /// Δ_fill — full-RGB (per-channel Chebyshev) distance within which a pixel is
    /// "essentially the fill colour"; generous enough to absorb JPEG q0.92 noise
    /// on a solid bar. 0…1. Measured: a uniform dev-0.149 field still counts
    /// as fill, dev-0.1725 does not (battery `propertyFloors_pure`).
    private static let fillDistance: CGFloat = 0.16
    /// Δ_contrast — distance at/over which a pixel counts as readable contrast.
    /// MUST be ≤ `fillDistance` (asserted in `isFillConsistent`) so the bands are
    /// complementary — no dead zone a pale-but-readable stroke can hide in. Set
    /// below the readability JND and above JPEG noise. 0…1. Measured: the
    /// palest Vision-readable ink the battery measured deviates ≥ 0.176
    /// (gray-45 on black; pale-on-white F-WEBER ink deviates ≈ 0.18 with its
    /// loose-band break only at a hypothetical Δ_contrast ≥ 44/255 ≈ 0.173 —
    /// unreachable while Δ_contrast ≤ Δ_fill = 0.16 holds). Band pin: dev
    /// 0.1098 is fill-only; dev 0.1294 already counts as contrast.
    private static let contrastDistance: CGFloat = 0.12
    /// F_min — minimum in-region-portion fill fraction for a box to be a demotion
    /// candidate (efficacy floor). Because `contrastFraction >= 1 - fillFraction`
    /// (every non-fill pixel is a contrast pixel, given Δ_contrast ≤ Δ_fill),
    /// demotion already implies `fillFraction >= 1 - contrastCeil`. Measured:
    /// real drivers fill = 1.000 (margin 0.03 above); the fullest readable-leak
    /// box measured 0.938 (gray-45) — 0.032 below the floor. The battery's
    /// chroma×hairline probe (blue-115 ultralight, below Vision's `.fast`
    /// sensor floor) starves BOTH the recall floor (contrast 0.076) and the
    /// outlier floor (maxDev 0.470) at once — this fill floor is what refuses
    /// it, at 0.934 (margin 0.036): the tightest measured approach to the
    /// demotion region by any ink class.
    private static let fillFloor: CGFloat = 0.97
    /// C_max — maximum readable-contrast fraction for a demotion candidate
    /// (≤ 0.03 by charter). The binding safety constraint. Measured: drivers
    /// contrast = 0.000; the faintest readable-leak contrast measured 0.096
    /// (hairline ultralight digits) — 3.2× the ceiling, and that box is also
    /// refused by the fill floor (0.906) and the outlier floor (maxDev 0.986).
    private static let contrastCeil: CGFloat = 0.03
    /// Recall-floor invariant: a box with at least this much readable contrast is
    /// NEVER excluded, regardless of `fillFraction`. Structural — it holds even if
    /// `contrastCeil` were later loosened past it. Cannot be tuned away. The
    /// battery's readable-leak contrast spans 0.096–0.995; the 0.096 hairline
    /// row rides the composed fill/outlier floors (see `contrastCeil`), every
    /// other class clears this floor outright.
    private static let recallFloor: CGFloat = 0.10
    /// Outlier floor: a single pixel this far (full-RGB) from the fill is
    /// "definitely ink" (the dark/contrasting core of a real glyph, including
    /// coloured ink whose luminance ≈ the fill) and blocks exclusion. 0…1.
    /// Measured: drivers maxDev ≤ 0.012 (0.488 below); hairline/reverse-video
    /// rims measure 0.867–1.000 (≥ 0.367 above); navy-on-black chroma ink
    /// (dev 0.338–0.455) sits under this floor and is carried by the recall
    /// floor instead — the floors compose per class.
    private static let strongInkDistance: CGFloat = 0.50
    /// Inset fraction (per side) for self-calibrating a region's fill colour —
    /// samples the rect's central interior, away from JPEG ringing at the edges.
    private static let fillCalibrationInset: CGFloat = 0.25
    /// Pixel margin trimmed from each edge of the in-region sample rect (box ∩
    /// region-rect, Option A) before sampling, to clear JPEG ringing / anti-alias
    /// overshoot at the bar↔rect boundary. Ringing is a fixed-WIDTH band, so a
    /// pixel inset — not a fraction of the (often tiny) box — is the correct shape;
    /// it leaves every numeric floor intact (preferred over loosening the outlier
    /// floor). Measured necessary on iOS 26.4: without it, boundary ringing spikes
    /// maxDeviation to ~1.0 on the narrow drivers (box flush with the rect edge,
    /// no overhang to clip) and blocks their demotion; with a 2 px trim every
    /// fixture driver demotes and the recall ink is still KEPT. Tiny-strip
    /// probes (battery `rider_insetTinyStrips`): interior hairline ink 2 px
    /// inside the sample edge survives the trim (contrast 0.125, maxDev 1.0 →
    /// KEPT); a 3 px strip collapses the inset and the un-inset fallback keeps
    /// the ink; ink hugging the strip's outer edge is trimmed and demotes —
    /// bounded at the fill-artifact WARN, never a clean PASS.
    private static let fillSampleInsetPixels: CGFloat = 2

    /// The candidate boxes an OCR hit contributes to the in-region decision: the
    /// per-word boxes when obtainable, else the conservative line box. SHARED by
    /// `classifyPageOCR` and the fill-sampling site so `OCRHit.boxFill` stays
    /// index-parallel to the boxes the classifier walks.
    static func inRegionCandidateBoxes(of hit: OCRHit) -> [CGRect] {
        hit.wordBoxes.isEmpty ? [hit.box] : hit.wordBoxes
    }

    /// A box is FILL-CONSISTENT — near-uniform fill carrying no readable contrast,
    /// i.e. a Vision hallucination off the solid bar rather than surviving ink —
    /// when it is overwhelmingly fill AND has negligible contrast AND has no
    /// strong-ink outlier. The recall- and outlier-floor branches make "never
    /// suppress readable ink" structural, not a function of threshold luck. PURE
    /// and unit-tested. The classifier may only ever DEMOTE such a box (FAIL →
    /// informational note); it can never silence it to a clean PASS.
    static func isFillConsistent(_ s: BoxFillSample) -> Bool {
        // Enforced no-dead-zone invariant: the contrast band must reach down to at
        // least the fill band's edge, so a readable-but-pale stroke cannot fall in
        // a gap between the bands. Not tunable past this point.
        precondition(contrastDistance <= fillDistance,
                     "Layer-2 fill guard: Δ_contrast must be ≤ Δ_fill (no dead zone)")
        if s.contrastFraction >= recallFloor { return false }   // recall floor — invariant
        if s.maxDeviation > strongInkDistance { return false }  // outlier floor — invariant
        return s.fillFraction >= fillFloor && s.contrastFraction <= contrastCeil
    }

    /// Full-RGB fill statistics for one OCR box over a BGRA pixel buffer (the
    /// layout `createBitmapContext` produces: byteOrder32Little +
    /// premultipliedFirst ⇒ B,G,R,A in memory). `box` is normalized **bottom-left**
    /// (the OCRHit / region convention) while buffer row 0 is the TOP scanline, so
    /// y flips via `(1 - maxY)` — identical to the verifier's proven grayscale fill
    /// probe. `fill` is the calibrated fill colour in 0…1 per channel. Distance is
    /// the per-channel Chebyshev (max |Δ| over R,G,B), so a coloured glyph whose
    /// luminance ≈ the fill still reads as contrast. `static` + buffer-pointer
    /// based so the pixel math is directly unit-testable without Vision.
    static func boxFillSample(
        box: CGRect,
        rgba: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        fill: (r: CGFloat, g: CGFloat, b: CGFloat)
    ) -> BoxFillSample {
        let x0 = max(0, Int(box.minX * CGFloat(width)))
        let x1 = min(width, Int(box.maxX * CGFloat(width)))
        let y0 = max(0, Int((1 - box.maxY) * CGFloat(height)))   // BL → top-down
        let y1 = min(height, Int((1 - box.minY) * CGFloat(height)))
        guard x1 > x0, y1 > y0 else {
            // Degenerate / off-image box → treat as definitely-ink so the guard
            // NEVER demotes it (precision-only floor).
            return BoxFillSample(fillFraction: 0, contrastFraction: 1, maxDeviation: 1)
        }
        var fillCount = 0, contrastCount = 0, total = 0
        var maxDev: CGFloat = 0
        for y in y0..<y1 {
            let rowBase = y * bytesPerRow
            for x in x0..<x1 {
                let off = rowBase + x * 4
                let b = CGFloat(rgba[off + 0]) / 255   // BGRA byte order
                let g = CGFloat(rgba[off + 1]) / 255
                let r = CGFloat(rgba[off + 2]) / 255
                let dev = max(abs(r - fill.r), abs(g - fill.g), abs(b - fill.b))
                total += 1
                if dev <= fillDistance { fillCount += 1 }
                if dev >= contrastDistance { contrastCount += 1 }
                if dev > maxDev { maxDev = dev }
            }
        }
        guard total > 0 else { return BoxFillSample(fillFraction: 0, contrastFraction: 1, maxDeviation: 1) }
        return BoxFillSample(
            fillFraction: CGFloat(fillCount) / CGFloat(total),
            contrastFraction: CGFloat(contrastCount) / CGFloat(total),
            maxDeviation: maxDev)
    }

    /// Self-calibrate a region's fill colour by averaging the BGRA buffer over the
    /// region rect's inset interior — the `verifyFill`-proven fill for a painted
    /// region. Insetting avoids JPEG ringing / anti-aliasing at the bar edges.
    /// Handles `.black` AND `.white` fill for free (no `FillColor` threading into
    /// the public API). Returns 0…1 RGB, or nil if the inset interior is
    /// degenerate. For an UNPAINTED region (a paint miss) the interior is not fill,
    /// so calibration is "wrong" — but readable ink there has high dynamic range
    /// (a strong outlier vs whatever colour is calibrated), so the outlier floor
    /// keeps it regardless. `static` for direct unit testing.
    ///
    /// For a POLYGON region (`vertices` ≥ 3, normalized space) the rect
    /// interior is NOT all fill — a concave shape's inset bbox mixes fill with
    /// preserved page background, and the averaged "fill" then reads the bar's
    /// own pixels as contrast. The probe instead anchors at the polygon's area
    /// centroid and shrinks until it sits fully inside the polygon
    /// (`polygonCalibrationProbe`); when no interior rect emerges, fall back to
    /// the bbox inset — wrong calibration there stays fail-safe exactly as the
    /// paint-miss case above.
    static func calibrateFillColor(
        region: CGRect,
        vertices: [CGPoint]? = nil,
        rgba: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        let probe: CGRect
        if let vertices, vertices.count >= 3,
           let polygonProbe = polygonCalibrationProbe(
               vertices: vertices, bbox: region,
               marginX: fillSampleInsetPixels / CGFloat(width),
               marginY: fillSampleInsetPixels / CGFloat(height)) {
            probe = polygonProbe
        } else {
            let inset = region.insetBy(dx: region.width * fillCalibrationInset,
                                       dy: region.height * fillCalibrationInset)
            probe = (inset.isNull || inset.isEmpty || inset.width <= 0 || inset.height <= 0) ? region : inset
        }
        let x0 = max(0, Int(probe.minX * CGFloat(width)))
        let x1 = min(width, Int(probe.maxX * CGFloat(width)))
        let y0 = max(0, Int((1 - probe.maxY) * CGFloat(height)))   // BL → top-down
        let y1 = min(height, Int((1 - probe.minY) * CGFloat(height)))
        guard x1 > x0, y1 > y0 else { return nil }
        var sr = 0.0, sg = 0.0, sb = 0.0, n = 0.0
        for y in y0..<y1 {
            let rowBase = y * bytesPerRow
            for x in x0..<x1 {
                let off = rowBase + x * 4
                sb += Double(rgba[off + 0]); sg += Double(rgba[off + 1]); sr += Double(rgba[off + 2])
                n += 1
            }
        }
        guard n > 0 else { return nil }
        return (CGFloat(sr / n / 255), CGFloat(sg / n / 255), CGFloat(sb / n / 255))
    }

    /// Probe rect for calibrating a POLYGON region's fill colour, in
    /// normalized space. Anchored at the polygon's area centroid, starting at
    /// the same interior share the rect probe uses (1 − 2·`fillCalibrationInset`
    /// per side of the bbox) and halving until the rect — grown by the ringing
    /// margin so the sampled pixels keep their distance from the polygon edges,
    /// mirroring `fillSampleInsetPixels` — sits fully inside the polygon.
    /// Returns nil when no interior rect emerges within four attempts (centroid
    /// outside a U-shape's interior, degenerate area): the caller then falls
    /// back to the bbox-inset probe, whose wrong calibration is fail-safe
    /// (outlier/recall floors keep readable ink regardless).
    static func polygonCalibrationProbe(
        vertices: [CGPoint],
        bbox: CGRect,
        marginX: CGFloat,
        marginY: CGFloat
    ) -> CGRect? {
        guard let centroid = polygonCentroid(vertices) else { return nil }
        var scale: CGFloat = 1 - 2 * fillCalibrationInset
        for _ in 0..<4 {
            let candidate = CGRect(
                x: centroid.x - bbox.width * scale / 2,
                y: centroid.y - bbox.height * scale / 2,
                width: bbox.width * scale,
                height: bbox.height * scale)
            let grown = candidate.insetBy(dx: -marginX, dy: -marginY)
            if rectFullyInsidePolygon(grown, vertices: vertices) {
                return candidate
            }
            scale /= 2
        }
        return nil
    }

    /// Part A: attach a per-box, full-RGB `BoxFillSample` to each hit, index-
    /// PARALLEL to `inRegionCandidateBoxes(of:)`. The page image is drawn once into
    /// a BGRA buffer; each region's fill colour is self-calibrated from its
    /// verifyFill-proven interior; the IN-REGION PORTION of every candidate box
    /// (box ∩ region-rect, Option A — 2026-06-28) is sampled against the fill of
    /// the region it overlaps most (by area). Only the
    /// single coordinate-trusted page image is sampled. On any failure the hits are
    /// returned unchanged (empty boxFill ⇒ the classifier excludes nothing). The
    /// buffer is zeroized on exit so output pixels do not linger in heap.
    static func enrichWithFillSamples(
        _ hits: [OCRHit],
        image: CGImage,
        regions: [RedactionRegion]
    ) -> [OCRHit] {
        guard !hits.isEmpty, !regions.isEmpty else { return hits }
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let ctx = createBitmapContext(width: width, height: height) else { return hits }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = ctx.data else { return hits }
        defer { PixelOperations.zeroizeBitmapBuffer(ctx) }
        let rgba = data.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = ctx.bytesPerRow

        // Self-calibrate each region's fill colour once. A polygon
        // region's probe anchors inside the polygon (its bbox interior mixes
        // fill with preserved page background); the SAMPLE rect below stays
        // box ∩ region-rect — only the calibration probe moves (decision
        // pre-made 2026-07-05; Option A semantics unchanged).
        let calibrated: [(rect: CGRect, fill: (r: CGFloat, g: CGFloat, b: CGFloat))] =
            regions.compactMap { region in
                calibrateFillColor(region: region.normalizedRect, vertices: region.vertices,
                                   rgba: rgba,
                                   width: width, height: height, bytesPerRow: bytesPerRow)
                    .map { (region.normalizedRect, $0) }
            }
        guard !calibrated.isEmpty else { return hits }

        return hits.map { hit in
            let boxes = inRegionCandidateBoxes(of: hit)
            let samples = boxes.map { box -> BoxFillSample in
                // Pick the region this box overlaps most (by area); both its fill
                // colour AND its rect drive the in-region-portion sample below. A box
                // overlapping no region is never in-region, so its sample is never
                // consulted for demotion; emit a definitely-ink sentinel anyway.
                var best: (rect: CGRect, fill: (r: CGFloat, g: CGFloat, b: CGFloat))?
                var bestArea: CGFloat = 0
                for c in calibrated {
                    let inter = box.intersection(c.rect)
                    let area = inter.isNull ? 0 : inter.width * inter.height
                    if area > bestArea { bestArea = area; best = c }
                }
                guard let chosen = best else {
                    return BoxFillSample(fillFraction: 0, contrastFraction: 1, maxDeviation: 1)
                }
                // Fill-consistency is classified against the
                // verifyFill-proven IN-REGION portion (box ∩ region-rect), NOT the whole
                // box. On-device measurement (iOS 26.4) falsified the original whole-box
                // assumption — Vision's hallucination boxes STRADDLE the bar edge into
                // the white page background (whole-box fill+contrast = 1.000, every box
                // maxDeviation = 1.000 off a pure-white pixel), so a whole-box sample
                // reads that white sliver as contrast/outlier and the strict floors
                // refuse to demote the false positives. Clipping to the in-region portion
                // drops the out-of-rect sliver, so the solid bar demotes cleanly under
                // the ORIGINAL floors (no threshold loosening). The classifier still uses
                // the WHOLE box for the in-region COVERAGE decision; only this fill SAMPLE
                // is clipped. Residual: a contrived edge-straddle LEAK demotes to WARN,
                // never a clean PASS — the precision-only bar holds (the verifier may route the
                // out-of-rect portion to the out-of-region WARN).
                let raw = box.intersection(chosen.rect)
                guard !raw.isNull, !raw.isEmpty else {
                    return BoxFillSample(fillFraction: 0, contrastFraction: 1, maxDeviation: 1)
                }
                // Trim a fixed pixel margin so JPEG ringing at the rect↔bar boundary
                // does not spike maxDeviation and block demotion (see
                // `fillSampleInsetPixels`). Fall back to the un-inset in-region rect
                // if the inset would collapse a very thin box (then `boxFillSample`'s
                // own degenerate guard yields the definitely-ink sentinel — safe).
                let inset = raw.insetBy(dx: fillSampleInsetPixels / CGFloat(width),
                                        dy: fillSampleInsetPixels / CGFloat(height))
                let sampleRect = (inset.isNull || inset.isEmpty
                                  || inset.width <= 0 || inset.height <= 0) ? raw : inset
                return boxFillSample(box: sampleRect, rgba: rgba, width: width,
                                     height: height, bytesPerRow: bytesPerRow, fill: chosen.fill)
            }
            return OCRHit(box: hit.box, wordBoxes: hit.wordBoxes, text: hit.text,
                          confidence: hit.confidence, boxFill: samples)
        }
    }
}
