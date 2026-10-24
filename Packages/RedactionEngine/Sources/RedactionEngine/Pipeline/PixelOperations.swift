import CoreGraphics
import PDFKit
#if canImport(UIKit)
import UIKit
#endif
import os

// Bitmap context, coordinate
// conversion, fill application, and pixel verification.

// MARK: - Signpost (Zeroize Instrumentation)

/// Shared signposter for zeroize-overhead measurement. The signpost
/// interval covers a single `memset_s` call so test fixtures can
/// derive p95 cost.
private let zeroizeSignposter = OSSignposter(
    subsystem: "app.resecta.engine",
    category: "Zeroize"
)

// MARK: - Bitmap Context

/// Create a bitmap context with sRGB color space and BGRA pixel layout.
/// Returns nil if non-premultiplied alpha is requested (iOS restriction).
func createBitmapContext(width: Int, height: Int) -> CGContext? {
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

// MARK: - Pixel Buffer Zeroize

/// Namespace for pixel-buffer routines that are not naturally part of
/// fill / verify / render. Caseless enum (Swift idiomatic namespace).
public enum PixelOperations {

    /// Canonical helper for clearing a bitmap context's backing pixel
    /// buffer. Uses `memset_s` so the compiler cannot elide the wipe
    /// even when the context is about to be freed (C11 §K.3.7.4.1
    /// mandates the call is performed). Called from `PageRasterizer`
    /// after `makeImage()` returns and from `BitmapContextPool.checkIn`;
    /// the latter is the canonical guard intended to prevent pixel
    /// data from surviving a pool reuse cycle.
    ///
    /// Mechanism: zeroes `bytesPerRow * height` bytes — the full
    /// backing allocation including any SIMD-alignment padding.
    ///
    /// SECURITY: this routine is designed to reduce the risk of source
    /// pixel data persisting in heap memory after fill/verify
    /// completes; it does not address copies CoreGraphics may have
    /// made into image caches during `makeImage()`.
    static func zeroizeBitmapBuffer(_ context: CGContext) {
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

// MARK: - Coordinate Conversion

/// Compute post-rotation visual dimensions.
/// bounds(for:) returns raw/un-rotated dimensions (R-1 confirmed, Experiment D).
///
/// `PDFPage.rotation` is always one of {0, 90, 180, 270}: PDFKit rounds a
/// `/Rotate` that is not a right angle to the nearest quarter turn, while
/// CoreGraphics (`CGPDFPage.rotationAngle`) keeps the raw value. The
/// pre-flight (`validatePageGeometry`) refuses a page on which the two
/// disagree, so every rendered page is in the frame this switch covers.
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
func normalizedToFillPixels(
    _ normalized: CGRect,
    bitmapWidth: Int,
    bitmapHeight: Int
) -> CGRect {
    let clamped = normalized.clampedToNormalized()
    let aligned = CGRect(
        x: clamped.minX * CGFloat(bitmapWidth),
        y: clamped.minY * CGFloat(bitmapHeight),
        width: clamped.width * CGFloat(bitmapWidth),
        height: clamped.height * CGFloat(bitmapHeight)
    ).pixelAligned()
    // Expand 1 px outward beyond pixel alignment. The rendered
    // content spans points × dpi/72 while the bitmap is ceil() of that, so a
    // rect scaled by the bitmap dimension can sit up to 1 px off the content
    // basis; the extra pixel covers the boundary row/column in the shifted
    // direction. Strictly over-redacting (the safe direction). Page
    // edges need no special case — fills clip at the bitmap and verifyFill
    // clamps. Empty aligned rects stay empty so degenerate regions
    // remain no-ops. Do NOT shrink the bitmap instead: floor() would crop a
    // column of real page content out of the output.
    return aligned.isEmpty ? aligned : aligned.insetBy(dx: -1, dy: -1)
}

// MARK: - Pixel Alignment

extension CGRect {
    /// Expand to integer pixel boundaries. Prevents partial-pixel fills
    /// that could leak original content through anti-aliased edges.
    func pixelAligned() -> CGRect {
        CGRect(x: floor(minX), y: floor(minY),
               width: ceil(maxX) - floor(minX),
               height: ceil(maxY) - floor(minY))
    }
}

// MARK: - Fill Application (cancellation bands)

/// Width of a scanline band for cooperative cancellation checks.
/// Locked at 256 rows: large enough that the per-band overhead is
/// negligible relative to fill/verify work, small enough that the worst-case
/// cancellation latency on a 5000×5000 region stays inside the 50 ms p95
/// budget on iPhone 17 simulator. Do not change without re-running
/// `CancellationLatencyTests` and the engine performance baseline.
internal let cancellationBandRows: Int = 256

/// Apply opaque fills over redaction regions. Uses bitmap dimensions only —
/// no PDF page geometry needed because the bitmap already contains the
/// correctly-rendered visual content.
///
/// Each region's pixel rect is split into 256-row scanline bands so
/// `Task.checkCancellation()` can run between bands. The bands tile exactly
/// across pixel-aligned integer rows, so there is no overlap, no gap, and no
/// anti-aliasing seam between adjacent bands (blend mode is `.copy` and
/// anti-aliasing is disabled).
func applyRedactionFills(
    context: CGContext,
    regions: [RedactionRegion],
    fillColor: FillColor
) throws {
    context.setBlendMode(.copy)           // R = S, regardless of destination
    context.setShouldAntialias(false)     // No edge blending
    context.setFillColor(fillColor.cgColor)

    for region in regions {
        let pixelRect = normalizedToFillPixels(
            region.normalizedRect,
            bitmapWidth: context.width,
            bitmapHeight: context.height
        )
        // Fill in 256-row bands with a cancellation check between
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

// MARK: - Post-Fill Pixel Verification

/// Read back raw pixels to confirm fill is complete. Uses memcmp with
/// NEON SIMD for ARM64 (283x faster than pixel-by-pixel per Experiment J1.1).
/// Accounts for Y-flip between context coordinates and memory layout.
///
/// A cooperative `Task.checkCancellation()` runs every
/// `cancellationBandRows` (256) rows so a long verify on a large region
/// surrenders within the 50 ms p95 cancellation budget. Throws
/// `CancellationError` on cancel; returns `Bool` for the verification result
/// itself.
func verifyFill(
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

    // Clamp to bitmap bounds. pixelAligned() can produce rects exceeding
    // bitmap dimensions when normalizedRect extends slightly past 1.0.
    let minX = max(0, Int(aligned.minX))
    let minY = max(0, Int(aligned.minY))
    let maxX = min(bitmapWidth, Int(aligned.maxX))
    let maxY = min(bitmapHeight, Int(aligned.maxY))
    guard minX < maxX, minY < maxY else { return false }

    let fillWidth = maxX - minX
    let compareBytes = fillWidth * 4

    // Build reference row buffer using memset_pattern4.
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
        // Cooperative cancellation every 256 rows. We check at the top
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
