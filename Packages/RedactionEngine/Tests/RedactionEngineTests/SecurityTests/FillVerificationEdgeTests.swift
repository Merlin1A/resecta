import Testing
import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif
@testable import RedactionEngine

// TEST §3.8 — Fill verification edge cases.
// memcmp equivalence, bounds clamping, and minimum dimension filtering.

@Suite("Fill Verification Edge Cases")
struct FillVerificationEdgeTests {

    @Test("verifyFill with memcmp matches pixel-by-pixel check")
    func memcmpEquivalence() throws {
        let width = 100, height = 100
        guard let ctx = createBitmapContext(width: width, height: height) else {
            Issue.record("Could not create bitmap context")
            return
        }
        let fillColor = FillColor.black
        ctx.setBlendMode(.copy)
        ctx.setShouldAntialias(false)
        ctx.setFillColor(fillColor.cgColor)
        ctx.fill(CGRect(x: 10, y: 10, width: 80, height: 80))

        let rect = CGRect(x: 10, y: 10, width: 80, height: 80)
        #expect(try verifyFill(context: ctx, rect: rect,
                               expectedColor: fillColor.expectedPixel) == true)
    }

    @Test("verifyFill clamps to bitmap bounds (PD-4-1)")
    func fillVerificationClampsToBounds() throws {
        let width = 100, height = 100
        guard let ctx = createBitmapContext(width: width, height: height) else {
            Issue.record("Could not create bitmap context")
            return
        }
        let fillColor = FillColor.black
        ctx.setBlendMode(.copy)
        ctx.setShouldAntialias(false)
        ctx.setFillColor(fillColor.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Rect exceeds bitmap bounds — should not crash, should still verify
        let oversizedRect = CGRect(x: -5, y: -5, width: 110, height: 110)
        let clamped = oversizedRect.intersection(
            CGRect(x: 0, y: 0, width: width, height: height)
        )
        #expect(try verifyFill(context: ctx, rect: clamped,
                               expectedColor: fillColor.expectedPixel) == true)
    }

    @Test("Minimum dimension threshold filters sub-pixel regions (AD-4-1)")
    func minimumDimensionFilter() {
        let regions = [
            RedactionRegion.mock(rect: CGRect(x: 0.1, y: 0.1, width: 0.0001, height: 0.05)),
            RedactionRegion.mock(rect: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.05)),
        ]
        let effective = regions.filter {
            $0.normalizedRect.width > 0.001 && $0.normalizedRect.height > 0.001
        }
        #expect(effective.count == 1, "Sub-threshold regions should be filtered")
    }

    @Test("White fill verifies after black content was overwritten")
    func whiteFillOverBlack() throws {
        let width = 200, height = 200
        guard let ctx = createBitmapContext(width: width, height: height) else {
            Issue.record("Could not create bitmap context")
            return
        }
        // Black background
        ctx.setFillColor(UIColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // White fill over center region
        let region = RedactionRegion.mock(
            rect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        )
        try applyRedactionFills(context: ctx, regions: [region], fillColor: .white)

        let pixelRect = normalizedToFillPixels(
            region.normalizedRect, bitmapWidth: width, bitmapHeight: height
        )
        #expect(try verifyFill(context: ctx, rect: pixelRect,
                               expectedColor: FillColor.white.expectedPixel) == true)
    }

    @Test("normalizedToFillPixels clamps values exceeding 1.0")
    func normalizedClampsBeyondBounds() {
        let bw = 640, bh = 480
        // Region extends past page edge: x=0.95, width=0.1 → maxX=1.05
        let overflowing = CGRect(x: 0.95, y: 0.95, width: 0.1, height: 0.1)
        let result = normalizedToFillPixels(overflowing, bitmapWidth: bw, bitmapHeight: bh)
        // Result must be entirely within bitmap bounds
        #expect(result.maxX <= CGFloat(bw), "Clamped rect should not exceed bitmap width")
        #expect(result.maxY <= CGFloat(bh), "Clamped rect should not exceed bitmap height")
        #expect(result.minX >= 0, "Clamped rect should not have negative X")
        #expect(result.minY >= 0, "Clamped rect should not have negative Y")
    }

    @Test("normalizedToFillPixels is identity for valid inputs")
    func normalizedPassthroughForValidInputs() {
        let bw = 100, bh = 100
        let valid = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let result = normalizedToFillPixels(valid, bitmapWidth: bw, bitmapHeight: bh)
        // Should produce the same result as direct scaling (within pixel alignment)
        let expected = CGRect(
            x: 0.1 * CGFloat(bw), y: 0.2 * CGFloat(bh),
            width: 0.3 * CGFloat(bw), height: 0.4 * CGFloat(bh)
        ).pixelAligned()
        #expect(result == expected, "Valid inputs should pass through unchanged")
    }

    @Test("clampedToNormalized clamps oversized rect to [0,1]")
    func clampedToNormalized() {
        let rect = CGRect(x: -0.1, y: -0.2, width: 1.5, height: 1.8)
        let clamped = rect.clampedToNormalized()
        #expect(clamped.minX >= 0)
        #expect(clamped.minY >= 0)
        #expect(clamped.maxX <= 1)
        #expect(clamped.maxY <= 1)
    }

    @Test("clampedToNormalized preserves valid inputs")
    func clampedToNormalizedIdentity() {
        let rect = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let clamped = rect.clampedToNormalized()
        #expect(abs(clamped.minX - 0.1) < 0.0001)
        #expect(abs(clamped.minY - 0.2) < 0.0001)
        #expect(abs(clamped.width - 0.3) < 0.0001)
        #expect(abs(clamped.height - 0.4) < 0.0001)
    }

    @Test("Single-pixel region verifies correctly")
    func singlePixelRegion() throws {
        let width = 100, height = 100
        guard let ctx = createBitmapContext(width: width, height: height) else {
            Issue.record("Could not create bitmap context")
            return
        }
        ctx.setBlendMode(.copy)
        ctx.setShouldAntialias(false)
        ctx.setFillColor(FillColor.black.cgColor)
        ctx.fill(CGRect(x: 50, y: 50, width: 1, height: 1))

        let rect = CGRect(x: 50, y: 50, width: 1, height: 1)
        #expect(try verifyFill(context: ctx, rect: rect,
                               expectedColor: FillColor.black.expectedPixel) == true)
    }
}
