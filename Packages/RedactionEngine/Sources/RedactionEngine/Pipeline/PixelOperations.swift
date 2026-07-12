import CoreGraphics
import PDFKit
#if canImport(UIKit)
import UIKit
#endif
import os

// ENGINE §2.1, §2.2, §2.5, §2.6, §3.1–§3.4 — Bitmap context, coordinate
// conversion, fill application, and pixel verification.

// MARK: - Signpost (SEC-5 zeroize instrumentation)

/// Shared signposter for zeroize-overhead measurement. The signpost
/// interval covers a single `memset_s` call so test fixtures can
/// derive p95 cost. See plan §3 SEC-5.
private let zeroizeSignposter = OSSignposter(
    subsystem: "app.resecta.engine",
    category: "Zeroize"
)

// MARK: - Bitmap Context (ENGINE §2.1)

/// Create a bitmap context with sRGB color space and BGRA pixel layout.
/// Returns nil if non-premultiplied alpha is requested (iOS restriction).
/// See ENGINE §2.1 for rationale on each setting.
public func createBitmapContext(width: Int, height: Int) -> CGContext? {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
                   | CGImageAlphaInfo.premultipliedFirst.rawValue
    let bytesPerRow = ((width * 4) + 0x0F) & ~0x0F  // 16-byte SIMD alignment
    return CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: bytesPerRow,
        space: colorSpace, bitmapInfo: bitmapInfo
    )
}

// MARK: - Pixel Buffer Zeroize (SEC-5, ENGINE §3.3)

/// Namespace for pixel-buffer routines that are not naturally part of
/// fill / verify / render. Caseless enum (Swift idiomatic namespace).
public enum PixelOperations {

    /// Canonical helper for clearing a bitmap context's backing pixel
    /// buffer. Uses `memset_s` so the compiler cannot elide the wipe
    /// even when the context is about to be freed (C11 §K.3.7.4.1
    /// mandates the call is performed). Called from `PageRasterizer`
    /// after `makeImage()` returns and from `BitmapContextPool.checkIn`;
    /// the latter is the canonical guard intended to prevent pixel
    /// data from surviving a pool reuse cycle. See plan §3 SEC-5.
    ///
    /// Mechanism: zeroes `bytesPerRow * height` bytes — the full
    /// backing allocation including any SIMD-alignment padding
    /// (ENGINE §2.1).
    ///
    /// SECURITY: this routine is designed to reduce the risk of source
    /// pixel data persisting in heap memory after fill/verify
    /// completes; it does not address copies CoreGraphics may have
    /// made into image caches during `makeImage()`.
    public static func zeroizeBitmapBuffer(_ context: CGContext) {
        guard let data = context.data else { return }
        let byteCount = context.bytesPerRow * context.height
        guard byteCount > 0 else { return }

        let signpostID = zeroizeSignposter.makeSignpostID()
        let interval = zeroizeSignposter.beginInterval(
            "Zeroize", id: signpostID, "bytes=\(byteCount)"
        )
        // memset_s — C11 K.3.7.4.1 mandates the call is performed (cannot
        // be optimized away even when the buffer is about to be released).
        memset_s(data, byteCount, 0, byteCount)
        zeroizeSignposter.endInterval("Zeroize", interval)
    }
}

// MARK: - Coordinate Conversion (ENGINE §2.2, §3.1a)

/// Compute post-rotation visual dimensions.
/// bounds(for:) returns raw/un-rotated dimensions (R-1 confirmed, Experiment D).
/// See ENGINE §2.2.
///
/// TRUST-pdf-rotation-non-90-multiples: PDFKit normalizes the page's
/// `/Rotate` entry to one of {0, 90, 180, 270} per ISO 32000 §8.3.2 —
/// non-multiple-of-90 values are clamped on parse, so this switch
/// covers every rotation the engine can observe via `PDFPage.rotation`.
public func effectiveBounds(_ rawBounds: CGRect, rotation: Int) -> CGRect {
    switch rotation {
    case 90, 270:
        return CGRect(x: rawBounds.origin.x, y: rawBounds.origin.y,
                      width: rawBounds.height, height: rawBounds.width)
    default:
        return rawBounds
    }
}

/// Convert normalized coordinates (0–1, bottom-left origin) to pixel
/// coordinates in the fill bitmap context (bottom-left origin).
///
/// SECURITY NOTE: Correctness depends entirely on renderPage() producing
/// a bitmap where visual content fills the full width and height.
/// See ENGINE §3.1a.
public func normalizedToFillPixels(
    _ normalized: CGRect,
    bitmapWidth: Int,
    bitmapHeight: Int
) -> CGRect {
    let clamped = normalized.clampedToNormalized()
    return CGRect(
        x: clamped.minX * CGFloat(bitmapWidth),
        y: clamped.minY * CGFloat(bitmapHeight),
        width: clamped.width * CGFloat(bitmapWidth),
        height: clamped.height * CGFloat(bitmapHeight)
    ).pixelAligned()
}

// MARK: - Pixel Alignment (ENGINE §3.2)

extension CGRect {
    /// Expand to integer pixel boundaries. Prevents partial-pixel fills
    /// that could leak original content through anti-aliased edges.
    /// See ENGINE §3.2.
    public func pixelAligned() -> CGRect {
        CGRect(x: floor(minX), y: floor(minY),
               width: ceil(maxX) - floor(minX),
               height: ceil(maxY) - floor(minY))
    }
}

// MARK: - Fill Application (ENGINE §3.1, §3.4 — PERF-8 cancellation bands)

/// Width of a scanline band for cooperative cancellation checks.
/// Locked at 256 rows by PERF-8: large enough that the per-band overhead is
/// negligible relative to fill/verify work, small enough that the worst-case
/// cancellation latency on a 5000×5000 region stays inside the 50 ms p95
/// budget on iPhone 17 simulator. Do not change without re-running
/// `CancellationLatencyTests` and the engine performance baseline.
internal let cancellationBandRows: Int = 256

/// Apply opaque fills over redaction regions. Uses bitmap dimensions only —
/// no PDF page geometry needed because the bitmap already contains the
/// correctly-rendered visual content. See ENGINE §3.1.
///
/// PERF-8: each region's pixel rect is split into 256-row scanline bands so
/// `Task.checkCancellation()` can run between bands. The bands tile exactly
/// across pixel-aligned integer rows, so there is no overlap, no gap, and no
/// anti-aliasing seam between adjacent bands (blend mode is `.copy` and
/// anti-aliasing is disabled — see ENGINE §3.1, §3.2).
///
/// DRAW-1: regions with non-nil `vertices` are filled via `CGMutablePath`
/// with even-odd winding. The rectangle path (vertices == nil) keeps the
/// fast scanline-band fill route. Anti-aliasing is disabled across both
/// paths so polygon edges are pixel-exact and verify can use the same
/// mask-equality check.
public func applyRedactionFills(
    context: CGContext,
    regions: [RedactionRegion],
    fillColor: FillColor
) throws {
    context.setBlendMode(.copy)           // R = S, regardless of destination
    context.setShouldAntialias(false)     // No edge blending
    context.setFillColor(fillColor.cgColor)

    for region in regions {
        // DRAW-1: polygon path. Build a CGPath and fill with even-odd
        // winding. Even-odd is the locked rule for self-intersecting paths
        // (a deliberately-tuned freeform stroke that loops back is still
        // filled in the visible interior region under even-odd).
        if let vertices = region.vertices, vertices.count >= 3 {
            try fillPolygonRegion(
                context: context,
                vertices: vertices,
                bitmapWidth: context.width,
                bitmapHeight: context.height
            )
            continue
        }

        let pixelRect = normalizedToFillPixels(
            region.normalizedRect,
            bitmapWidth: context.width,
            bitmapHeight: context.height
        )
        // PERF-8: fill in 256-row bands with a cancellation check between
        // bands. Region rects are already pixel-aligned (see
        // normalizedToFillPixels → pixelAligned), so integer banding is safe.
        let minY = Int(pixelRect.minY)
        let maxY = Int(pixelRect.maxY)
        guard maxY > minY else { continue }

        var bandStart = minY
        while bandStart < maxY {
            try Task.checkCancellation()
            let bandEnd = min(bandStart + cancellationBandRows, maxY)
            let band = CGRect(
                x: pixelRect.minX,
                y: CGFloat(bandStart),
                width: pixelRect.width,
                height: CGFloat(bandEnd - bandStart)
            )
            context.fill(band)
            bandStart = bandEnd
        }
    }
}

// MARK: - Polygon Fill (DRAW-1)

/// Convert a normalized point (0–1, bottom-left origin) into the pixel
/// coordinate space of a fill bitmap context (same bottom-left origin).
/// Mirrors the per-axis scaling in `normalizedToFillPixels` but for a
/// single point — no pixel alignment, because polygon vertices are not
/// integer-aligned and Core Graphics rasterises the closed path itself.
///
/// This is now a pure scale — the previous per-axis clamp to
/// `[0, 1]` is removed. Out-of-unit vertices are handled at the polygon
/// level instead: the fill path clips the polygon to the unit square with
/// `clipPolygonToUnitRect` (boundary crossings, no notch) and the verify
/// path's `buildPolygonMask` already clamps its scanline spans to the bitmap
/// rect. Clamping a single vertex pulled it inward and notched the fill away
/// from the true page edge (under-redaction); polygon clipping does not.
@inlinable
internal func normalizedVertexToPixels(
    _ point: CGPoint,
    bitmapWidth: Int,
    bitmapHeight: Int
) -> CGPoint {
    let x = point.x * CGFloat(bitmapWidth)
    let y = point.y * CGFloat(bitmapHeight)
    return CGPoint(x: x, y: y)
}

/// Clip a polygon (normalized 0–1 coordinates, any winding) against the unit
/// square [0,1]² with the Sutherland–Hodgman algorithm. A vertex outside the
/// square is replaced by the point(s) where its incident edges cross the
/// boundary, so a fill built from the result reaches the true page-edge span
/// rather than notching inward at a clamped vertex. Returns `[]`
/// when the polygon lies entirely outside the square (nothing to fill).
///
/// The clip region is convex, so the result is a valid even-odd fill region
/// equal to `polygon ∩ [0,1]²` (for concave subjects, coincident zero-area
/// boundary seams may appear; they do not change the filled area). SECURITY:
/// over-redaction is safe, under-redaction is a breach — clipping never pulls
/// the boundary inside the true polygon. See ENGINE §3.1 / DRAW-1.
internal func clipPolygonToUnitRect(_ vertices: [CGPoint]) -> [CGPoint] {
    guard vertices.count >= 3 else { return [] }

    enum Edge { case left, right, bottom, top }
    func inside(_ p: CGPoint, _ e: Edge) -> Bool {
        switch e {
        case .left:   return p.x >= 0
        case .right:  return p.x <= 1
        case .bottom: return p.y >= 0
        case .top:    return p.y <= 1
        }
    }
    // Intersection of segment a→b with the boundary line of `e`.
    func crossing(_ a: CGPoint, _ b: CGPoint, _ e: Edge) -> CGPoint {
        let dx = b.x - a.x
        let dy = b.y - a.y
        switch e {
        case .left:
            let t = dx == 0 ? 0 : (0 - a.x) / dx
            return CGPoint(x: 0, y: a.y + t * dy)
        case .right:
            let t = dx == 0 ? 0 : (1 - a.x) / dx
            return CGPoint(x: 1, y: a.y + t * dy)
        case .bottom:
            let t = dy == 0 ? 0 : (0 - a.y) / dy
            return CGPoint(x: a.x + t * dx, y: 0)
        case .top:
            let t = dy == 0 ? 0 : (1 - a.y) / dy
            return CGPoint(x: a.x + t * dx, y: 1)
        }
    }

    var output = vertices
    for e in [Edge.left, .right, .bottom, .top] {
        guard !output.isEmpty else { break }
        let input = output
        output = []
        output.reserveCapacity(input.count + 1)
        var prev = input[input.count - 1]
        for curr in input {
            let currIn = inside(curr, e)
            if currIn {
                if !inside(prev, e) { output.append(crossing(prev, curr, e)) }
                output.append(curr)
            } else if inside(prev, e) {
                output.append(crossing(prev, curr, e))
            }
            prev = curr
        }
    }
    return output
}

/// Apply a polygon fill into `context` using the even-odd rule.
/// Vertices are in normalized PDF coordinates (0–1, bottom-left origin).
/// Inserts a `Task.checkCancellation()` before the (single) fill call so
/// the polygon path participates in the same cooperative cancellation
/// discipline as the rectangle path. The Core Graphics rasteriser owns
/// the per-scanline loop; we do not subdivide the path itself.
internal func fillPolygonRegion(
    context: CGContext,
    vertices: [CGPoint],
    bitmapWidth: Int,
    bitmapHeight: Int
) throws {
    guard vertices.count >= 3 else { return }
    try Task.checkCancellation()

    // Clip to the unit square before scaling. A vertex outside
    // [0,1]² was previously clamped per-axis in normalizedVertexToPixels,
    // which pinched the polygon inward and left a notch of un-filled page at
    // the boundary (under-redaction). Sutherland–Hodgman replaces the clamped
    // vertex with its boundary crossings so the fill reaches the true edge.
    let clipped = clipPolygonToUnitRect(vertices)
    guard clipped.count >= 3 else { return }  // entirely outside the page box

    let path = CGMutablePath()
    let first = normalizedVertexToPixels(
        clipped[0], bitmapWidth: bitmapWidth, bitmapHeight: bitmapHeight
    )
    path.move(to: first)
    for i in 1..<clipped.count {
        let p = normalizedVertexToPixels(
            clipped[i], bitmapWidth: bitmapWidth, bitmapHeight: bitmapHeight
        )
        path.addLine(to: p)
    }
    path.closeSubpath()

    context.saveGState()
    context.addPath(path)
    context.fillPath(using: .evenOdd)
    context.restoreGState()
}

// MARK: - Post-Fill Pixel Verification (ENGINE §3.4)

/// Read back raw pixels to confirm fill is complete. Uses memcmp with
/// NEON SIMD for ARM64 (283x faster than pixel-by-pixel per Experiment J1.1).
/// Accounts for Y-flip between context coordinates and memory layout.
/// See ENGINE §3.4.
///
/// PERF-8: a cooperative `Task.checkCancellation()` runs every
/// `cancellationBandRows` (256) rows so a long verify on a large region
/// surrenders within the 50 ms p95 cancellation budget. Throws
/// `CancellationError` on cancel; returns `Bool` for the verification result
/// itself.
public func verifyFill(
    context: CGContext,
    rect: CGRect,
    expectedColor: ExpectedPixelBGRA
) throws -> Bool {
    guard let data = context.data else { return false }
    let buffer = data.assumingMemoryBound(to: UInt8.self)
    let bpr = context.bytesPerRow
    let bitmapHeight = context.height
    let bitmapWidth = context.width
    let aligned = rect.pixelAligned()

    // PD-4-1: Clamp to bitmap bounds. pixelAligned() can produce rects exceeding
    // bitmap dimensions when normalizedRect extends slightly past 1.0.
    let minX = max(0, Int(aligned.minX))
    let minY = max(0, Int(aligned.minY))
    let maxX = min(bitmapWidth, Int(aligned.maxX))
    let maxY = min(bitmapHeight, Int(aligned.maxY))
    guard minX < maxX, minY < maxY else { return false }

    let fillWidth = maxX - minX
    let compareBytes = fillWidth * 4

    // Build reference row buffer using memset_pattern4 (ENGINE §3.4a).
    // Pattern byte order matches BGRA layout: [B, G, R, A].
    var pattern: (UInt8, UInt8, UInt8, UInt8) = (
        expectedColor.b, expectedColor.g, expectedColor.r, expectedColor.a
    )
    let expectedRow = UnsafeMutablePointer<UInt8>.allocate(capacity: compareBytes)
    defer { expectedRow.deallocate() }
    withUnsafePointer(to: &pattern) { patternPtr in
        memset_pattern4(expectedRow, patternPtr, compareBytes)
    }

    var rowsSinceCheck = 0
    for contextY in minY..<maxY {
        // PERF-8: cooperative cancellation every 256 rows. We check at the top
        // of each band so a freshly cancelled task surrenders before doing
        // another 256-row scan.
        if rowsSinceCheck == 0 {
            try Task.checkCancellation()
        }
        // Experiment B: CGBitmapContext memory row 0 = top of image,
        // but context coordinate y=0 = bottom of image.
        let memoryRow = bitmapHeight - 1 - contextY
        let rowPtr = buffer + memoryRow * bpr + minX * 4

        if memcmp(rowPtr, expectedRow, compareBytes) != 0 {
            return false
        }
        rowsSinceCheck += 1
        if rowsSinceCheck >= cancellationBandRows {
            rowsSinceCheck = 0
        }
    }
    return true
}

// MARK: - Polygon Verification (DRAW-1)

/// Build a 1-bit (per-pixel) inclusion mask for a closed polygon defined in
/// the bitmap's pixel coordinate system (bottom-left origin). The mask uses
/// the same coordinate convention as the rendering context — bit 1 at
/// `(x, y)` means the pixel at context coordinate `(x, y)` lies inside the
/// even-odd-rule interior of the polygon.
///
/// The mask is sized to the polygon's pixel-bounding rect, not the full
/// bitmap, so cost scales with the polygon (not the page). Returned as a
/// flat row-major `[UInt8]` buffer where bit `(y - maskOriginY) * width +
/// (x - maskOriginX)` is set iff inside.
///
/// Used by `verifyPolygonFill`; not part of the production fill pipeline.
/// Polygon rendering itself goes through Core Graphics' `fillPath` which
/// owns its own scanline rasteriser; this helper produces an *independent*
/// inclusion test so verification is not circular (defense-in-depth).
internal struct PolygonMask {
    /// Inclusive bottom-left pixel coordinate of the mask, in context space.
    let originX: Int
    let originY: Int
    /// Mask width / height in pixels.
    let width: Int
    let height: Int
    /// Per-pixel inclusion: 1 if pixel is inside the polygon, 0 otherwise.
    /// Row-major; row 0 = bottom row (context y == originY).
    var bits: [UInt8]

    /// Number of pixels inside the polygon — equals popcount of `bits`.
    var insidePixelCount: Int {
        var count = 0
        for b in bits where b != 0 { count += 1 }
        return count
    }

    /// True when any pixel is inside the polygon. The degenerate
    /// guard in `verifyPolygonFill` needs only an any-bit-set test, so this
    /// short-circuits on the first set byte instead of the full O(width×height)
    /// popcount `insidePixelCount` walks.
    var hasInteriorPixels: Bool { bits.contains { $0 != 0 } }
}

/// Build a polygon inclusion mask for a closed polygon in pixel coordinates.
/// Even-odd rule: for each scanline, sort the X intersections with polygon
/// edges, then mark pixels strictly between consecutive pairs as inside.
/// Edges parallel to the scan direction (horizontal) are skipped (their
/// intersections are undefined and accumulating them produces double-counts
/// at edge-corner vertices). Returns nil if the polygon has fewer than 3
/// vertices or the bounding rect is degenerate.
internal func buildPolygonMask(
    pixelVertices: [CGPoint],
    bitmapWidth: Int,
    bitmapHeight: Int
) -> PolygonMask? {
    guard pixelVertices.count >= 3 else { return nil }

    // Bounding rect in pixel coordinates, clamped to bitmap bounds.
    var minXf = CGFloat.greatestFiniteMagnitude
    var minYf = CGFloat.greatestFiniteMagnitude
    var maxXf = -CGFloat.greatestFiniteMagnitude
    var maxYf = -CGFloat.greatestFiniteMagnitude
    for v in pixelVertices {
        if v.x < minXf { minXf = v.x }
        if v.x > maxXf { maxXf = v.x }
        if v.y < minYf { minYf = v.y }
        if v.y > maxYf { maxYf = v.y }
    }
    let originX = max(0, Int(floor(minXf)))
    let originY = max(0, Int(floor(minYf)))
    let endX = min(bitmapWidth, Int(ceil(maxXf)))
    let endY = min(bitmapHeight, Int(ceil(maxYf)))
    let width = endX - originX
    let height = endY - originY
    guard width > 0, height > 0 else { return nil }

    var bits = [UInt8](repeating: 0, count: width * height)

    // Even-odd scanline fill. For each integer scan-y we test the line at
    // the *pixel centre* (y + 0.5). For each polygon edge that crosses this
    // y, we compute the x-intersection. Sort ascending; mark pixels in pairs
    // as inside.
    let n = pixelVertices.count
    for row in 0..<height {
        let scanY = CGFloat(originY + row) + 0.5
        var xIntersections: [CGFloat] = []
        xIntersections.reserveCapacity(n)
        var j = n - 1
        for i in 0..<n {
            let vi = pixelVertices[i]
            let vj = pixelVertices[j]
            j = i
            // Edge straddles the scan line iff one endpoint is above and the
            // other is at-or-below. The half-open convention prevents
            // double-counting at shared vertex Y values.
            let aboveI = vi.y > scanY
            let aboveJ = vj.y > scanY
            if aboveI != aboveJ {
                // Parametric x at scanY:
                //   x = vj.x + (scanY - vj.y) * (vi.x - vj.x) / (vi.y - vj.y)
                let dy = vi.y - vj.y
                guard dy != 0 else { continue }
                let t = (scanY - vj.y) / dy
                let x = vj.x + t * (vi.x - vj.x)
                xIntersections.append(x)
            }
        }
        guard xIntersections.count >= 2 else { continue }
        xIntersections.sort()

        // Pair up — fill pixels between successive pairs.
        var k = 0
        while k + 1 < xIntersections.count {
            let xa = xIntersections[k]
            let xb = xIntersections[k + 1]
            // Pixel x is inside if its centre (px + 0.5) falls in [xa, xb).
            let pxStart = max(originX, Int(ceil(xa - 0.5)))
            let pxEndExclusive = min(endX, Int(ceil(xb - 0.5)))
            if pxEndExclusive > pxStart {
                let rowOffset = row * width
                for px in pxStart..<pxEndExclusive {
                    bits[rowOffset + (px - originX)] = 1
                }
            }
            k += 2
        }
    }

    return PolygonMask(
        originX: originX, originY: originY,
        width: width, height: height,
        bits: bits
    )
}

/// Verify that every pixel inside a polygon region matches the expected
/// fill color. Allocates a 1-bit polygon inclusion mask sized to the
/// polygon's pixel-bounding rect, iterates scanlines in the bounding rect,
/// and runs `memcmp` only over the contiguous mask-set spans within each
/// row. Pixels outside the polygon are not inspected — verifying them
/// would expose bugs in the rect fill, not the polygon. Layer 6
/// (sandwich spatial exclusion) is the canonical check for character
/// content surviving outside the redaction.
///
/// PERF-8: cooperative `Task.checkCancellation()` runs at the top of every
/// 256-row band — same discipline as the rectangle `verifyFill`. Throws
/// `CancellationError` on cancel; returns `Bool` for the verification
/// result itself.
///
/// `pixelVertices` are in the same coordinate system as the bitmap context
/// (bottom-left origin, pixel units). Convert from normalized using
/// `normalizedVertexToPixels` upstream.
public func verifyPolygonFill(
    context: CGContext,
    pixelVertices: [CGPoint],
    expectedColor: ExpectedPixelBGRA
) throws -> Bool {
    guard let data = context.data else { return false }
    let buffer = data.assumingMemoryBound(to: UInt8.self)
    let bpr = context.bytesPerRow
    let bitmapHeight = context.height
    let bitmapWidth = context.width

    guard let mask = buildPolygonMask(
        pixelVertices: pixelVertices,
        bitmapWidth: bitmapWidth,
        bitmapHeight: bitmapHeight
    ) else { return false }

    // The mask has no interior pixels (degenerate polygon, e.g. collinear
    // vertices). Treat as a pass — there is nothing to verify and the fill
    // would have been a no-op on the bitmap. Any-bit-set early-exit,
    // not a full-mask popcount.
    if !mask.hasInteriorPixels { return true }

    // Build a 4-byte expected pixel pattern in BGRA layout. Used per-span
    // via memcmp against contiguous mask runs.
    let expectedBytes: [UInt8] = [
        expectedColor.b, expectedColor.g, expectedColor.r, expectedColor.a
    ]

    // Package H — PERF-verify-polygon-alloc-in-loop (`03-security-perf-audit.md
    // §2.6.a`). One allocation per call, sized to the widest possible run
    // (full mask width). The buffer is pre-filled with the BGRA pattern; each
    // memcmp consumes the first `compareBytes` bytes. Pattern is identical for
    // every run, so the prefix-equality of memcmp reads remains correct.
    let maxRunBytes = mask.width * 4
    let expectedRow = UnsafeMutablePointer<UInt8>
        .allocate(capacity: maxRunBytes)
    defer { expectedRow.deallocate() }
    expectedBytes.withUnsafeBufferPointer { srcBuf in
        guard let src = srcBuf.baseAddress else { return }
        memset_pattern4(expectedRow, src, maxRunBytes)
    }

    var rowsSinceCheck = 0
    // Iterate scanlines in mask row order (row 0 = bottom of mask).
    for row in 0..<mask.height {
        // PERF-8: cooperative cancellation at the top of each 256-row band.
        if rowsSinceCheck == 0 {
            try Task.checkCancellation()
        }
        let contextY = mask.originY + row
        guard contextY >= 0, contextY < bitmapHeight else {
            rowsSinceCheck += 1
            if rowsSinceCheck >= cancellationBandRows { rowsSinceCheck = 0 }
            continue
        }
        // Experiment B: same Y-flip as verifyFill.
        let memoryRow = bitmapHeight - 1 - contextY

        // Walk the row in mask space, collapsing contiguous "inside" runs
        // into one memcmp per run. Per Experiment J1.1, memcmp is 283× the
        // pixel-by-pixel route via NEON SIMD — keep runs as wide as
        // possible.
        let rowOffset = row * mask.width
        var col = 0
        while col < mask.width {
            // Skip "outside" pixels.
            while col < mask.width, mask.bits[rowOffset + col] == 0 {
                col += 1
            }
            // Collect a contiguous "inside" run.
            let runStart = col
            while col < mask.width, mask.bits[rowOffset + col] != 0 {
                col += 1
            }
            let runLen = col - runStart
            guard runLen > 0 else { continue }

            // Translate into context X coordinates and clip to bitmap.
            let ctxXStart = mask.originX + runStart
            let ctxXEndExclusive = ctxXStart + runLen
            let clippedStart = max(0, ctxXStart)
            let clippedEnd = min(bitmapWidth, ctxXEndExclusive)
            let clippedLen = clippedEnd - clippedStart
            guard clippedLen > 0 else { continue }

            // Compare against the hoisted `expectedRow` buffer; memcmp reads
            // the first `compareBytes` bytes of the pre-filled pattern.
            let compareBytes = clippedLen * 4
            let rowPtr = buffer + memoryRow * bpr + clippedStart * 4
            if memcmp(rowPtr, expectedRow, compareBytes) != 0 {
                return false
            }
        }

        rowsSinceCheck += 1
        if rowsSinceCheck >= cancellationBandRows {
            rowsSinceCheck = 0
        }
    }

    return true
}

// MARK: - DPI Selection (ENGINE §2.5)

/// Select the effective DPI for a page, respecting both the user's
/// chosen maximum and the device's available memory.
/// Returns nil if even 150 DPI exceeds available memory (abort).
/// Page dimensions default to US Letter for backward compatibility;
/// callers should pass actual dimensions for large-format pages.
/// See ENGINE §2.5.
public func selectDPI(
    availableMemory: Int,
    userMaxDPI: Int,
    pageWidth: CGFloat = 612,
    pageHeight: CGFloat = 792
) -> Int? {
    let clampedMax = [150, 200, 300].filter { $0 <= userMaxDPI }.max() ?? 150
    // ENGINE §2.5: 150 MB headroom. Floor at 0 for constrained devices
    // where availableMemory <= 150 MB — the tier loop returns nil gracefully.
    let budget = max(0, availableMemory - 150_000_000)
    // Compute actual memory needed at each DPI tier based on page dimensions.
    // 2× multiplier accounts for concurrent render + fill bitmap contexts
    // during PageRasterizer.rasterize() (ENGINE §2.5).
    let tiers = [300, 200, 150].filter { $0 <= clampedMax }
    for dpi in tiers {
        let scale = CGFloat(dpi) / 72.0
        let bytes = Int(ceil(pageWidth * scale)) * Int(ceil(pageHeight * scale)) * 4
        if bytes * 2 < budget { return dpi }
    }
    return nil
}

// MARK: - Input Validation (ENGINE §2.6)

/// Validate a page before rendering. Checks dimensions, /UserUnit, and
/// memory budget at the effective DPI. See ENGINE §2.6.
public func validatePage(_ page: PDFPage, effectiveDPI: Int = 300) -> Bool {
    let box = page.bounds(for: .cropBox)
    guard box.width >= 10, box.height >= 10,
          box.width <= 5000, box.height <= 5000 else { return false }

    // H-16: Check for /UserUnit (Experiment N)
    if let pageRef = page.pageRef,
       let dict = pageRef.dictionary {
        var userUnit: CGPDFReal = 0
        if CGPDFDictionaryGetNumber(dict, "UserUnit", &userUnit),
           userUnit != 1.0 {
            return false
        }
    }

    // MP-3-1: Use effective DPI for memory budget check.
    let scale: CGFloat = CGFloat(effectiveDPI) / 72.0
    let bytes = Int(ceil(box.width * scale)) * Int(ceil(box.height * scale)) * 4

    // Measured 2026-06-13: `os_proc_available_memory()` is unusable
    // on the simulator — it reports well under 67 MB regardless of real
    // headroom, so a standard page's 300-DPI raster (~33.7 MB) fails the
    // half-available test and the validatePage wire-up would then refuse every page.
    // When the reading is at or below the §2.5 headroom (150 MB) — the same
    // floor at which `selectDPI` yields zero budget — treat it as unusable and
    // defer the memory decision to the runtime DPI cap + `selectDPI` (KI-5),
    // which are the effective memory defense. The dimension/UserUnit guards
    // above still run in every case, so the pre-flight keeps rejecting
    // oversized pages.
    #if canImport(UIKit)
    let available = os_proc_available_memory()
    guard available > 150_000_000 else { return true }
    return bytes < available / 2
    #else
    // macOS tooling destination: os_proc_available_memory() is iOS-only.
    // Treat the reading as unusable — the same outcome as the simulator
    // case above — and defer to the runtime DPI cap + `selectDPI`.
    _ = bytes
    return true
    #endif
}
