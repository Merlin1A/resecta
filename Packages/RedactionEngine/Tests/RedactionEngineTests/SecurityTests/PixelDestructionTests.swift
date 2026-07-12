import Testing
import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif
@testable import RedactionEngine

// ENGINE §3 — Pixel destruction security tests.
// This is the most security-critical test suite. Every fill must be verifiable.

@Suite("Pixel Destruction and Fill Verification")
struct PixelDestructionTests {

    // MARK: - Black Fill Verification

    @Test("Black fill produces exact BGRA(0,0,0,255) in filled region")
    func blackFillExactPixels() throws {
        let (ctx, width, height) = try makeTestContext(200, 200)

        // Draw non-black content first (simulate PDF content)
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Apply black fill over a region
        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            source: .manual
        )
        try applyRedactionFills(context: ctx, regions: [region], fillColor: .black)

        // Verify the fill
        let pixelRect = normalizedToFillPixels(
            region.normalizedRect, bitmapWidth: width, bitmapHeight: height
        )
        let verified = try verifyFill(
            context: ctx, rect: pixelRect,
            expectedColor: FillColor.black.expectedPixel
        )
        #expect(verified, "Black fill must produce exact BGRA(0,0,0,255)")
    }

    // MARK: - White Fill Verification

    @Test("White fill produces exact BGRA(255,255,255,255) in filled region")
    func whiteFillExactPixels() throws {
        let (ctx, width, height) = try makeTestContext(200, 200)

        // Draw non-white content first
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
            source: .manual
        )
        try applyRedactionFills(context: ctx, regions: [region], fillColor: .white)

        let pixelRect = normalizedToFillPixels(
            region.normalizedRect, bitmapWidth: width, bitmapHeight: height
        )
        let verified = try verifyFill(
            context: ctx, rect: pixelRect,
            expectedColor: FillColor.white.expectedPixel
        )
        #expect(verified, "White fill must produce exact BGRA(255,255,255,255)")
    }

    // MARK: - verifyFill Rejects Unfilled Region

    @Test("verifyFill returns false for region that was NOT filled")
    func verifyRejectsUnfilled() throws {
        let (ctx, width, height) = try makeTestContext(200, 200)

        // Draw red content, do NOT apply any fill
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let testRect = CGRect(x: 50, y: 50, width: 100, height: 100)
        let result = try verifyFill(
            context: ctx, rect: testRect,
            expectedColor: FillColor.black.expectedPixel
        )
        #expect(!result, "verifyFill must return false for unfilled region")
    }

    // MARK: - Multiple Regions

    @Test("Multiple regions on same page all verify independently")
    func multipleRegionsVerify() throws {
        let (ctx, width, height) = try makeTestContext(300, 400)

        // Draw varied content
        ctx.setFillColor(red: 0.5, green: 0.3, blue: 0.8, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let regions = [
            RedactionRegion(id: UUID(),
                normalizedRect: CGRect(x: 0.0, y: 0.0, width: 0.3, height: 0.3),
                source: .manual),
            RedactionRegion(id: UUID(),
                normalizedRect: CGRect(x: 0.5, y: 0.5, width: 0.4, height: 0.4),
                source: .detectedPII(kind: .ssn)),
            RedactionRegion(id: UUID(),
                normalizedRect: CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.2),
                source: .detectedFace),
        ]
        try applyRedactionFills(context: ctx, regions: regions, fillColor: .black)

        for region in regions {
            let pixelRect = normalizedToFillPixels(
                region.normalizedRect, bitmapWidth: width, bitmapHeight: height
            )
            let clamped = pixelRect.intersection(
                CGRect(x: 0, y: 0, width: width, height: height)
            )
            let verified = try verifyFill(
                context: ctx, rect: clamped,
                expectedColor: FillColor.black.expectedPixel
            )
            #expect(verified, "Region at \(region.normalizedRect) must verify")
        }
    }

    // MARK: - Pixel Alignment

    @Test("pixelAligned expands fractional coordinates to integer boundaries")
    func pixelAlignment() {
        let fractional = CGRect(x: 10.3, y: 20.7, width: 50.5, height: 30.2)
        let aligned = fractional.pixelAligned()

        // floor(minX) = 10, floor(minY) = 20
        #expect(aligned.minX == 10)
        #expect(aligned.minY == 20)
        // ceil(maxX) = ceil(60.8) = 61, ceil(maxY) = ceil(50.9) = 51
        #expect(aligned.maxX == 61)
        #expect(aligned.maxY == 51)
        // Width/height are integer
        #expect(aligned.width == 51)
        #expect(aligned.height == 31)
    }

    @Test("Fill covers full pixel-aligned area with no gaps")
    func fillCoversAlignedArea() throws {
        let (ctx, width, height) = try makeTestContext(100, 100)

        // Region with fractional coordinates
        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.103, y: 0.207, width: 0.505, height: 0.302),
            source: .manual
        )
        try applyRedactionFills(context: ctx, regions: [region], fillColor: .black)

        let pixelRect = normalizedToFillPixels(
            region.normalizedRect, bitmapWidth: width, bitmapHeight: height
        )
        let verified = try verifyFill(
            context: ctx, rect: pixelRect,
            expectedColor: FillColor.black.expectedPixel
        )
        #expect(verified, "Pixel-aligned fill must fully cover the expanded area")
    }

    // MARK: - Edge Cases

    @Test("Full-page fill (0,0,1,1) verifies correctly")
    func fullPageFill() throws {
        let (ctx, width, height) = try makeTestContext(100, 100)

        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            source: .manual
        )
        try applyRedactionFills(context: ctx, regions: [region], fillColor: .black)

        let verified = try verifyFill(
            context: ctx, rect: CGRect(x: 0, y: 0, width: width, height: height),
            expectedColor: FillColor.black.expectedPixel
        )
        #expect(verified)
    }

    @Test("verifyFill handles region at bitmap edge (PD-4-1 clamp)")
    func edgeRegionClamped() throws {
        let (ctx, width, height) = try makeTestContext(100, 100)

        // Region extends slightly past 1.0
        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.9, y: 0.9, width: 0.15, height: 0.15),
            source: .manual
        )
        try applyRedactionFills(context: ctx, regions: [region], fillColor: .white)

        let pixelRect = normalizedToFillPixels(
            region.normalizedRect, bitmapWidth: width, bitmapHeight: height
        )
        let clamped = pixelRect.intersection(
            CGRect(x: 0, y: 0, width: width, height: height)
        )
        let verified = try verifyFill(
            context: ctx, rect: clamped,
            expectedColor: FillColor.white.expectedPixel
        )
        #expect(verified, "Clamped edge region must verify")
    }

    // MARK: - DPI Selection

    @Test("selectDPI respects user max and memory budget")
    func dpiSelection() {
        // Plenty of memory, user wants 300
        #expect(selectDPI(availableMemory: 500_000_000, userMaxDPI: 300) == 300)

        // Plenty of memory, user capped at 200
        #expect(selectDPI(availableMemory: 500_000_000, userMaxDPI: 200) == 200)

        // Limited memory, user wants 300 but only 200 fits
        #expect(selectDPI(availableMemory: 200_000_000, userMaxDPI: 300) == 200)

        // Very limited memory, only 150 fits
        #expect(selectDPI(availableMemory: 175_000_000, userMaxDPI: 300) == 150)

        // Not enough memory for even 150
        #expect(selectDPI(availableMemory: 160_000_000, userMaxDPI: 300) == nil)
    }

    // MARK: - Coordinate Conversion

    @Test("normalizedToFillPixels maps 0-1 to full bitmap dimensions")
    func normalizedToPixels() {
        let fullPage = CGRect(x: 0, y: 0, width: 1, height: 1)
        let pixels = normalizedToFillPixels(fullPage, bitmapWidth: 2550, bitmapHeight: 3300)
        #expect(pixels == CGRect(x: 0, y: 0, width: 2550, height: 3300))
    }

    @Test("normalizedToFillPixels half-page region maps correctly")
    func normalizedHalfPage() {
        let halfPage = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let pixels = normalizedToFillPixels(halfPage, bitmapWidth: 200, bitmapHeight: 200)
        // 0.25 * 200 = 50, 0.5 * 200 = 100 → pixelAligned → same
        #expect(pixels == CGRect(x: 50, y: 50, width: 100, height: 100))
    }

    // MARK: - effectiveBounds

    @Test("effectiveBounds swaps dimensions for 90° and 270° rotation")
    func effectiveBoundsRotation() {
        let raw = CGRect(x: 0, y: 0, width: 612, height: 792)

        let r0 = effectiveBounds(raw, rotation: 0)
        #expect(r0.width == 612 && r0.height == 792)

        let r90 = effectiveBounds(raw, rotation: 90)
        #expect(r90.width == 792 && r90.height == 612)

        let r180 = effectiveBounds(raw, rotation: 180)
        #expect(r180.width == 612 && r180.height == 792)

        let r270 = effectiveBounds(raw, rotation: 270)
        #expect(r270.width == 792 && r270.height == 612)
    }

    // MARK: - Bitmap Context

    @Test("createBitmapContext returns non-nil with correct dimensions")
    func bitmapContextCreation() {
        let ctx = createBitmapContext(width: 100, height: 200)
        #expect(ctx != nil)
        #expect(ctx?.width == 100)
        #expect(ctx?.height == 200)
    }

    @Test("createBitmapContext uses 16-byte aligned bytesPerRow")
    func bitmapContextAlignment() {
        let ctx = createBitmapContext(width: 100, height: 100)!
        // 100 * 4 = 400, aligned: (400 + 15) & ~15 = 400 (already aligned)
        #expect(ctx.bytesPerRow % 16 == 0)

        let ctx2 = createBitmapContext(width: 101, height: 100)!
        // 101 * 4 = 404, aligned: (404 + 15) & ~15 = 416
        #expect(ctx2.bytesPerRow == 416)
        #expect(ctx2.bytesPerRow % 16 == 0)
    }

    // MARK: - Non-Gray Fill Discriminator (TEST §3.4)

    @Test("Non-gray fill discriminates channel swaps via per-channel verification")
    func nonGrayChannelDiscriminator() throws {
        let (ctx, width, height) = try makeTestContext(200, 200)
        let expected = ExpectedPixelBGRA(b: 0, g: 128, r: 255, a: 255)

        // Apply non-gray fill manually (not through applyRedactionFills since
        // that only supports black/white FillColor)
        ctx.setBlendMode(.copy)
        ctx.setShouldAntialias(false)
        ctx.setFillColor(UIColor(
            red: CGFloat(expected.r) / 255.0,
            green: CGFloat(expected.g) / 255.0,
            blue: CGFloat(expected.b) / 255.0,
            alpha: CGFloat(expected.a) / 255.0
        ).cgColor)
        ctx.fill(CGRect(x: 50, y: 50, width: 100, height: 100))

        // Manual pixel-by-pixel verification
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let bpr = ctx.bytesPerRow
        let memoryRow = height - 1 - 75  // Check row at context y=75
        let offset = memoryRow * bpr + 75 * 4  // pixel at (75, 75)
        #expect(data[offset]   == expected.b, "Blue channel mismatch")
        #expect(data[offset+1] == expected.g, "Green channel mismatch")
        #expect(data[offset+2] == expected.r, "Red channel mismatch")
        #expect(data[offset+3] == expected.a, "Alpha channel mismatch")
    }

    @Test("memcmp verification agrees with pixel-by-pixel check")
    func memcmpEquivalence() throws {
        let (ctx, width, height) = try makeTestContext(100, 100)
        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6),
            source: .manual)
        try applyRedactionFills(context: ctx, regions: [region], fillColor: .black)

        let pixelRect = normalizedToFillPixels(
            region.normalizedRect, bitmapWidth: width, bitmapHeight: height)

        // memcmp-based check
        let memcmpResult = try verifyFill(
            context: ctx, rect: pixelRect,
            expectedColor: FillColor.black.expectedPixel)

        // Manual pixel-by-pixel
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let bpr = ctx.bytesPerRow
        let aligned = pixelRect.pixelAligned()
        var allMatch = true
        for cy in Int(aligned.minY)..<min(height, Int(aligned.maxY)) {
            let memRow = height - 1 - cy
            for x in Int(aligned.minX)..<min(width, Int(aligned.maxX)) {
                let off = memRow * bpr + x * 4
                if data[off] != 0 || data[off+1] != 0 || data[off+2] != 0 || data[off+3] != 255 {
                    allMatch = false
                }
            }
        }
        #expect(memcmpResult == allMatch, "memcmp and pixel-by-pixel must agree")
    }

    @Test("verifyFill returns false for zero-area region")
    func zeroAreaRegion() throws {
        let (ctx, _, _) = try makeTestContext(100, 100)
        // Zero-width region
        let result = try verifyFill(
            context: ctx,
            rect: CGRect(x: 50, y: 50, width: 0, height: 50),
            expectedColor: FillColor.black.expectedPixel)
        #expect(result == false, "Zero-area region should fail verification")
    }

    @Test("Negative-origin rect is clamped correctly in verifyFill")
    func negativeOriginClamped() throws {
        let (ctx, width, height) = try makeTestContext(100, 100)
        // Fill entire page black
        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            source: .manual)
        try applyRedactionFills(context: ctx, regions: [region], fillColor: .black)

        // Verify with a rect that extends into negative
        let result = try verifyFill(
            context: ctx,
            rect: CGRect(x: -10, y: -10, width: 50, height: 50),
            expectedColor: FillColor.black.expectedPixel)
        #expect(result == true, "Clamped negative-origin rect should verify on fully filled page")
    }

    // MARK: - Helpers

    private func makeTestContext(_ width: Int, _ height: Int) throws -> (CGContext, Int, Int) {
        guard let ctx = createBitmapContext(width: width, height: height) else {
            Issue.record("Could not create test bitmap context")
            throw TestError.contextCreationFailed
        }
        // White background
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return (ctx, width, height)
    }

    private enum TestError: Error {
        case contextCreationFailed
    }
}
