import CoreGraphics
import Foundation

// Heuristic signature detector. Triage-only — never auto-applied.
//
// Algorithm (four steps, in `detect(in:ocrBlocks:)`):
//   1. Consume OCR text-block bboxes already produced by the engine's
//      `OCREngine` / orchestrator path. Caller passes `[OCREngine.TextLine]`.
//   2. Identify "labeled signature regions" — OCR blocks matching
//      `/^(signature|sign here|signed|authorized signature)$/i`, allowing a
//      trailing colon or period.
//   3. Define a candidate rectangle as the area to the right of the label
//      (or directly below it when the label sits at the right margin),
//      bounded by half a page width and the next OCR block in reading order.
//   4. Compute an ink-density curvature score on the candidate region:
//      - Render the candidate at a small fixed working size (128×64) in
//        grayscale.
//      - Apply a 3×3 Sobel filter.
//      - Count edge pixels above the magnitude threshold.
//      - Compute a curvature score by counting 3×3 neighborhoods where the
//        edge density rises above a second threshold (a proxy for handwriting
//        strokes which curve, vs. printed text which has high-density
//        horizontal/vertical edges only).
//      - Emit a `DetectionResult(kind: .pii(.signatureCandidate))` iff both
//        density and curvature exceed empirically-tuned thresholds.
//
// I7 escape hatch: This adds NO new `PipelineError` cases and NO new
// dependency. Accelerate / vImage is intentionally avoided to keep the
// implementation inline; the working raster is 128×64 = 8 192 pixels so the
// pure-Swift Sobel pass is ~µs per region. The "skip the Sobel pass entirely
// if no labeled regions are found" hard-stop is honored by the orchestrator
// gate; this detector also returns early on `ocrBlocks.isEmpty`.
//
// Confidence is heuristic. The reported score is a normalized blend of
// density and curvature ratios — calibration is intentionally out of scope
// (see `PIICategory(piiKind:)` returning nil for `.signatureCandidate`).
public struct SignatureHeuristicDetector: Sendable {

    // MARK: - Empirical thresholds
    //
    // Surfaced as static constants so the handoff summary can record them.
    // V1 values; not runtime-configurable per plan hard-stop.
    //
    // densityThreshold — fraction of pixels in the candidate raster whose
    // Sobel magnitude exceeds `edgeMagnitudeThreshold`. Above this fraction
    // the region has enough ink to be "more than blank".
    //
    // curvatureThreshold — fraction of 3×3 windows where edge density (count
    // of edge pixels in the window) exceeds `windowEdgeMin`. Designed to
    // discriminate handwriting (clusters of curved strokes) from printed
    // text (high horizontal/vertical density but few curved windows). The
    // working raster is 128×64; we count windows over the interior.
    //
    // The two thresholds compose: a region must clear both, which reduces
    // the risk of false positives on either dense print or sparse marks.
    public static let densityThreshold: Double = 0.05
    public static let curvatureThreshold: Double = 0.03
    static let edgeMagnitudeThreshold: Int = 96  // 0–~1020 Sobel magnitude
    static let windowEdgeMin: Int = 5            // edge pixels per 5×5 window
    /// Minimum edge-pixel count required in each vertical-third band of
    /// the candidate raster. Designed to reduce the risk of treating a
    /// printed phrase that lives on a single baseline (and therefore
    /// leaves the top and bottom thirds nearly empty) as a signature.
    static let bandMinPerThird: Int = 40

    /// Working raster size for the Sobel pass. Constant per task hard-stop
    /// ("resize to a fixed working size before filtering").
    static let workingWidth = 128
    static let workingHeight = 64

    public init() {}

    /// Detect heuristic signature candidates on the supplied page raster,
    /// using OCR text-line bboxes to constrain the search.
    ///
    /// - Parameters:
    ///   - image: Full page raster in CGImage form (origin at top-left as
    ///     usual for CGImage). All math is performed in normalized PDF
    ///     coordinates (0–1, bottom-left origin) to match the rest of the
    ///     detection pipeline.
    ///   - ocrBlocks: Per-line OCR results from the engine's text recognizer.
    ///     Empty array short-circuits the Sobel pass (cost guardrail).
    /// - Returns: Zero or more `DetectionResult`s with kind
    ///   `.pii(.signatureCandidate)`. Confidence is heuristic — the caller
    ///   must route these to the triage sheet (the engine package has no
    ///   knowledge of the app's triage flow; the contract is enforced at the
    ///   state layer via `RedactionState.applyDetectionResults`).
    @concurrent
    public func detect(
        in image: CGImage,
        ocrBlocks: [OCREngine.TextLine]
    ) async throws -> [DetectionResult] {
        // PERF-8 / CANCEL-012: entry-level cooperative cancellation.
        try Task.checkCancellation()
        // Step 1: short-circuit when no OCR is available — without text
        // labels the heuristic has no candidate regions to score.
        guard !ocrBlocks.isEmpty else { return [] }

        // Step 2: identify labeled signature regions.
        let labels = ocrBlocks.filter { Self.isSignatureLabel($0.text) }
        guard !labels.isEmpty else { return [] }

        var results: [DetectionResult] = []

        for label in labels {
            try Task.checkCancellation()
            // Step 3: define the candidate region adjacent to the label.
            guard let candidate = Self.candidateRect(
                for: label,
                in: ocrBlocks
            ) else { continue }

            // Step 4: render the candidate at a fixed working size and run
            // the Sobel-based density + curvature check.
            guard let analysis = try Self.analyze(
                candidate: candidate,
                in: image
            ) else { continue }

            guard analysis.density >= Self.densityThreshold,
                  analysis.curvature >= Self.curvatureThreshold,
                  analysis.bandSpread.passes(min: Self.bandMinPerThird) else { continue }

            // Blend the two ratios into a heuristic confidence. Capped at
            // 0.85 to communicate "this is a suggestion, not a structured
            // match" (mechanism-description discipline).
            let confidence = min(0.85, 0.4 + analysis.density * 4.0 + analysis.curvature * 6.0)

            results.append(DetectionResult(
                id: UUID(),
                normalizedRect: candidate,
                kind: .pii(.signatureCandidate),
                confidence: confidence,
                matchedText: nil,
                recognitionLevel: .fast,
                provenance: .ocrRan
            ))
        }

        return results
    }

    // MARK: - Step 2: Label matching

    /// Match the four signature-label phrases case-insensitively, allowing
    /// a trailing colon or period. Internal trailing whitespace is trimmed
    /// before matching.
    static func isSignatureLabel(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip a single trailing colon or period after trimming (the most
        // common label punctuation in form templates).
        let stripped: String = {
            guard let last = trimmed.last, last == ":" || last == "." else {
                return trimmed
            }
            return String(trimmed.dropLast())
        }()
        let lowered = stripped.lowercased()
        switch lowered {
        case "signature", "sign here", "signed", "authorized signature":
            return true
        default:
            return false
        }
    }

    // MARK: - Step 3: Candidate region geometry

    /// Build the candidate rectangle adjacent to a label OCR block.
    ///
    /// Reading-order convention: OCR rects use normalized, bottom-left
    /// origin (Vision's coordinate system). "Right of" the label is
    /// `x in (label.maxX, label.maxX + halfWidth)`. "Below" the label is
    /// `y in (label.minY - someHeight, label.minY)`.
    ///
    /// Bounds:
    ///   - Width capped at half a page width.
    ///   - Trimmed back if the next OCR block in the same row is closer
    ///     than the half-width cap (to avoid swallowing the next field).
    ///   - When the label is in the rightmost ~30% of the page and no
    ///     useful right-side space exists, fall back to a band below.
    static func candidateRect(
        for label: OCREngine.TextLine,
        in blocks: [OCREngine.TextLine]
    ) -> CGRect? {
        let labelRect = label.normalizedRect
        guard labelRect.height > 0 else { return nil }

        let halfPageWidth: CGFloat = 0.5
        let rowTolerance = labelRect.height * 0.5

        // Right-of candidate: same row, right of the label.
        let rightStart = labelRect.maxX
        let rightAvailable = max(0, 1 - rightStart)

        // Identify the next OCR block on the same row, to the right of the label.
        let rowNeighbors = blocks
            .filter { neighbor in
                guard neighbor.text != label.text || neighbor.normalizedRect != labelRect else {
                    return false
                }
                let dy = abs(neighbor.normalizedRect.midY - labelRect.midY)
                return dy <= rowTolerance && neighbor.normalizedRect.minX > rightStart
            }
            .sorted { $0.normalizedRect.minX < $1.normalizedRect.minX }

        let rightCapFromNeighbor: CGFloat = rowNeighbors.first.map {
            max(0, $0.normalizedRect.minX - rightStart - 0.005)
        } ?? rightAvailable

        let rightWidth = min(halfPageWidth, rightCapFromNeighbor)

        // Prefer the right-of candidate when there is at least a label-width
        // of clear space. Otherwise drop to a "below" band.
        if rightWidth >= max(0.05, labelRect.width) {
            let rect = CGRect(
                x: rightStart,
                y: labelRect.minY,
                width: rightWidth,
                height: labelRect.height * 1.6
            )
            return rect.clampedToNormalized()
        }

        // Below candidate: same x-range as the label, bounded below by the
        // next OCR block in the column.
        let belowAvailableHeight: CGFloat = labelRect.minY
        guard belowAvailableHeight > 0 else { return nil }

        let columnTolerance = labelRect.width
        let columnNeighbors = blocks
            .filter { neighbor in
                guard neighbor.text != label.text || neighbor.normalizedRect != labelRect else {
                    return false
                }
                let dx = abs(neighbor.normalizedRect.midX - labelRect.midX)
                return dx <= columnTolerance && neighbor.normalizedRect.maxY < labelRect.minY
            }
            .sorted { $0.normalizedRect.maxY > $1.normalizedRect.maxY }

        let belowFloor: CGFloat = columnNeighbors.first.map {
            $0.normalizedRect.maxY + 0.005
        } ?? max(0, labelRect.minY - 0.1)

        let belowHeight = max(0, labelRect.minY - belowFloor)
        guard belowHeight >= labelRect.height * 0.5 else { return nil }

        let widthBelow = min(halfPageWidth, max(labelRect.width, 0.2))
        let rect = CGRect(
            x: labelRect.minX,
            y: belowFloor,
            width: widthBelow,
            height: belowHeight
        )
        return rect.clampedToNormalized()
    }

    // MARK: - Step 4: Sobel + curvature

    /// Result of the pixel-level analysis on a candidate region.
    struct CandidateAnalysis {
        let density: Double         // fraction of pixels with strong edges
        let curvature: Double       // fraction of 5×5 windows with split-half edges
        let bandSpread: BandSpread  // edge-pixel counts in top/middle/bottom thirds
    }

    /// Render the candidate rect from the source image into a fixed-size
    /// grayscale buffer, then run the Sobel + curvature pass.
    ///
    /// Returns nil if the rect is empty or the bitmap context could not be
    /// created (the pipeline treats that as "no signal" and emits no result).
    static func analyze(candidate: CGRect, in image: CGImage) throws -> CandidateAnalysis? {
        guard candidate.width > 0, candidate.height > 0 else { return nil }

        // Convert the candidate from normalized (bottom-left) to CGImage
        // pixel space (top-left). The orchestrator's normalized coordinates
        // share Vision's convention; CGImage is top-down so we invert y.
        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)
        let pixelRect = CGRect(
            x: candidate.minX * imageWidth,
            y: (1 - candidate.maxY) * imageHeight,
            width: candidate.width * imageWidth,
            height: candidate.height * imageHeight
        )

        guard let cropped = image.cropping(to: pixelRect) else { return nil }

        // Allocate an 8-bit grayscale working buffer.
        let w = workingWidth
        let h = workingHeight
        let bytesPerRow = w
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))

        guard let dataPtr = context.data else { return nil }
        let pixels = dataPtr.bindMemory(to: UInt8.self, capacity: w * h)

        return try sobelPass(pixels: pixels, width: w, height: h)
    }

    /// Result struct for the row-band check used to reject typed text
    /// (which clusters edges along a single baseline) without rejecting
    /// handwriting (which spreads strokes across the candidate height).
    /// Internal — exposed via the public `CandidateAnalysis` aggregate.
    struct BandSpread {
        let top: Int
        let middle: Int
        let bottom: Int
        /// True iff each of the three vertical bands carries at least
        /// `bandMin` edge pixels. Designed to reduce the risk of treating
        /// a single-baseline printed phrase as a signature.
        func passes(min: Int) -> Bool {
            top >= min && middle >= min && bottom >= min
        }
    }

    /// Run a 3×3 Sobel pass over the grayscale buffer, then compute density
    /// + curvature. Pure function; testable without rendering.
    static func sobelPass(
        pixels: UnsafePointer<UInt8>,
        width: Int,
        height: Int
    ) throws -> CandidateAnalysis {
        // Sobel kernels (Gx, Gy).
        // Gx = [[-1, 0, 1], [-2, 0, 2], [-1, 0, 1]]
        // Gy = [[-1, -2, -1], [0, 0, 0], [1, 2, 1]]
        // We compute |Gx| + |Gy| as a cheap approximation of the gradient
        // magnitude (the standard "Sobel magnitude" simplification).

        let interiorWidth = width - 2
        let interiorHeight = height - 2
        let interiorPixels = interiorWidth * interiorHeight
        let zeroBand = BandSpread(top: 0, middle: 0, bottom: 0)
        guard interiorPixels > 0 else {
            return CandidateAnalysis(density: 0, curvature: 0, bandSpread: zeroBand)
        }

        // Edge mask packed row-major into a UInt8 array (1 = edge, 0 = not).
        var edgeMask = [UInt8](repeating: 0, count: interiorPixels)
        var edgePixelCount = 0
        // Per-band edge counts. Bands split the interior height into thirds.
        let bandLowEnd = interiorHeight / 3
        let bandHighStart = (interiorHeight * 2) / 3
        var topBandEdges = 0
        var middleBandEdges = 0
        var bottomBandEdges = 0

        // PERF-8 / CANCEL-012: 256-row band counter over the Sobel pass.
        // Working buffer is workingWidth x workingHeight; the cancel check
        // amortizes to roughly one check per row-band of pixel work.
        var bandCounter = 0
        for y in 1..<(height - 1) {
            if bandCounter & 0xFF == 0 { try Task.checkCancellation() }
            bandCounter += 1
            for x in 1..<(width - 1) {
                let p00 = Int(pixels[(y - 1) * width + (x - 1)])
                let p01 = Int(pixels[(y - 1) * width + x])
                let p02 = Int(pixels[(y - 1) * width + (x + 1)])
                let p10 = Int(pixels[y * width + (x - 1)])
                // p11 — center — drops out of both kernels
                let p12 = Int(pixels[y * width + (x + 1)])
                let p20 = Int(pixels[(y + 1) * width + (x - 1)])
                let p21 = Int(pixels[(y + 1) * width + x])
                let p22 = Int(pixels[(y + 1) * width + (x + 1)])

                let gx = (-p00 + p02) + (-2 * p10 + 2 * p12) + (-p20 + p22)
                let gy = (-p00 - 2 * p01 - p02) + (p20 + 2 * p21 + p22)
                let magnitude = abs(gx) + abs(gy)

                if magnitude >= edgeMagnitudeThreshold {
                    let interiorY = y - 1
                    edgeMask[interiorY * interiorWidth + (x - 1)] = 1
                    edgePixelCount += 1
                    // Track which third of the candidate this edge falls in.
                    if interiorY < bandLowEnd {
                        topBandEdges += 1
                    } else if interiorY >= bandHighStart {
                        bottomBandEdges += 1
                    } else {
                        middleBandEdges += 1
                    }
                }
            }
        }

        let density = Double(edgePixelCount) / Double(interiorPixels)
        let bandSpread = BandSpread(
            top: topBandEdges,
            middle: middleBandEdges,
            bottom: bottomBandEdges
        )

        // Curvature proxy: count 5×5 windows of the edge mask that satisfy
        // BOTH (a) ≥ `windowEdgeMin` total edge pixels AND (b) edges present
        // in both the top half AND the bottom half of the window.
        //
        // Rationale: a curved stroke (handwriting) crosses multiple
        // baselines within a small spatial neighborhood — edges appear in
        // both the top and bottom of the window. Printed text glyph
        // outlines tend to live near a fixed baseline; their edge pixels
        // cluster vertically (top/bottom of a single glyph row) but their
        // 5×5 neighborhoods around the middle of a glyph either fall
        // entirely inside or entirely outside the glyph. The split-half
        // check designed to discriminate continuous curved strokes from
        // axis-aligned glyph contours.
        let windowSize = 5
        let halfPoint = windowSize / 2
        var clusteredWindowCount = 0
        let cwMax = interiorWidth - windowSize + 1
        let chMax = interiorHeight - windowSize + 1
        guard cwMax > 0, chMax > 0 else {
            return CandidateAnalysis(
                density: density, curvature: 0, bandSpread: bandSpread
            )
        }
        let totalWindows = cwMax * chMax
        // PERF-8 / CANCEL-012: 256-row band counter over the windowed pass.
        var windowBandCounter = 0
        for wy in 0..<chMax {
            if windowBandCounter & 0xFF == 0 { try Task.checkCancellation() }
            windowBandCounter += 1
            for wx in 0..<cwMax {
                var total = 0
                var topHalf = 0
                var bottomHalf = 0
                for dy in 0..<windowSize {
                    let rowBase = (wy + dy) * interiorWidth + wx
                    var rowEdges = 0
                    for dx in 0..<windowSize {
                        rowEdges += Int(edgeMask[rowBase + dx])
                    }
                    total += rowEdges
                    if dy < halfPoint { topHalf += rowEdges }
                    else if dy > halfPoint { bottomHalf += rowEdges }
                }
                if total >= windowEdgeMin, topHalf > 0, bottomHalf > 0 {
                    clusteredWindowCount += 1
                }
            }
        }
        let curvature = Double(clusteredWindowCount) / Double(totalWindows)

        return CandidateAnalysis(
            density: density,
            curvature: curvature,
            bandSpread: bandSpread
        )
    }
}
