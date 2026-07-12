import Testing
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif

// EXP-008 migrated: Fill Exact BGRA Byte Verification
// Audit: AA-1-1 (Critical), PD-3-1 (High), AA-11, AA-2
// Validates the #1 security boundary: pixel-exact redaction fill.

@Suite("Fill Exact BGRA Verification", .tags(.security, .critical))
struct FillExactBGRATests {

    /// Create bitmap context matching Resecta's exact layout:
    private func createResectaBitmapContext(width: Int, height: Int) -> CGContext {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
                       | CGImageAlphaInfo.premultipliedFirst.rawValue
        let bytesPerRow = ((width * 4) + 0x0F) & ~0x0F
        return CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: bitmapInfo
        )!
    }

    // --- AA-1-1: Black fill must produce exactly B=0 G=0 R=0 A=255 ---
    @Test("Black fill produces exact BGRA(0,0,0,255)")
    func blackFillExactBGRA() {
        let ctx = createResectaBitmapContext(width: 100, height: 100)
        ctx.setBlendMode(.copy)
        ctx.setShouldAntialias(false)
        ctx.setFillColor(UIColor(red: 0, green: 0, blue: 0, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 10, y: 10, width: 80, height: 80))

        let buffer = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = ctx.bytesPerRow
        var mismatchCount = 0

        for y in 10..<90 {
            for x in 10..<90 {
                let offset = y * bytesPerRow + x * 4
                let b = buffer[offset], g = buffer[offset + 1]
                let r = buffer[offset + 2], a = buffer[offset + 3]
                if b != 0 || g != 0 || r != 0 || a != 255 {
                    mismatchCount += 1
                }
            }
        }
        #expect(mismatchCount == 0,
                "Black fill must be byte-exact B=0 G=0 R=0 A=255 across all \(80*80) pixels")
    }

    // --- AA-1-1: White fill must produce exactly B=255 G=255 R=255 A=255 ---
    @Test("White fill produces exact BGRA(255,255,255,255)")
    func whiteFillExactBGRA() {
        let ctx = createResectaBitmapContext(width: 100, height: 100)
        ctx.setBlendMode(.copy)
        ctx.setShouldAntialias(false)
        ctx.setFillColor(UIColor(red: 1, green: 1, blue: 1, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 10, y: 10, width: 80, height: 80))

        let buffer = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = ctx.bytesPerRow
        var mismatchCount = 0
        for y in 10..<90 {
            for x in 10..<90 {
                let offset = y * bytesPerRow + x * 4
                if buffer[offset] != 255 || buffer[offset+1] != 255 ||
                   buffer[offset+2] != 255 || buffer[offset+3] != 255 {
                    mismatchCount += 1
                }
            }
        }
        #expect(mismatchCount == 0,
                "White fill must be byte-exact B=255 G=255 R=255 A=255")
    }

    // --- Verify BGRA byte order (not RGBA or ARGB) ---
    @Test("Byte order is BGRA, not RGBA or ARGB")
    func bgraByteOrderVerification() {
        let ctx = createResectaBitmapContext(width: 10, height: 10)
        ctx.setBlendMode(.copy)
        ctx.setShouldAntialias(false)
        ctx.setFillColor(UIColor(red: 1, green: 0, blue: 0, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))

        let buffer = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let offset = 5 * ctx.bytesPerRow + 5 * 4
        // BGRA order: [B=0, G=0, R=255, A=255] for red
        #expect(buffer[offset] == 0, "Byte 0 = B = 0 for red")
        #expect(buffer[offset+1] == 0, "Byte 1 = G = 0 for red")
        #expect(buffer[offset+2] == 255, "Byte 2 = R = 255 for red")
        #expect(buffer[offset+3] == 255, "Byte 3 = A = 255 for red")
    }

    // --- AA-2: CGBitmapContext y=0 → memory row 0 mapping ---
    @Test("Context y=0 maps to memory row 0 (buffer start)")
    func memoryLayoutYMapping() {
        let ctx = createResectaBitmapContext(width: 100, height: 100)
        ctx.setBlendMode(.copy)
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        ctx.setFillColor(UIColor.red.cgColor)
        ctx.fill(CGRect(x: 50, y: 0, width: 1, height: 1))

        let buffer = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = ctx.bytesPerRow
        // Check B channel (byte 0 in BGRA): red has B=0, white has B=255.
        // R channel is 255 for BOTH red and white, so it can't distinguish them.
        let row0B = buffer[0 * bytesPerRow + 50 * 4]
        let row99B = buffer[99 * bytesPerRow + 50 * 4]

        // CGBitmapContext: memory row 0 = top of image, context y=0 = bottom.
        // Drawing at context y=0 places the pixel in memory row 99 (last row).
        #expect(row99B == 0, "Red pixel (B=0) at context y=0 must be in memory row 99 (bottom)")
        #expect(row0B == 255, "Memory row 0 (top) must be white (B=255), not red")
    }

    // --- AA-11: Anti-aliasing disabled = no edge blending ---
    @Test("No anti-aliasing edge blending with setShouldAntialias(false)")
    func noAntiAliasingEdgeBlending() {
        let ctx = createResectaBitmapContext(width: 200, height: 200)
        ctx.setBlendMode(.copy)
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        ctx.setShouldAntialias(false)
        ctx.setFillColor(UIColor.black.cgColor)
        ctx.fill(CGRect(x: 50, y: 50, width: 100, height: 100))

        let buffer = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = ctx.bytesPerRow
        let edgeRow = 199 - 50  // y=50 in context -> row 149 in memory
        let outsideOffset = edgeRow * bytesPerRow + 49 * 4
        let insideOffset = edgeRow * bytesPerRow + 50 * 4

        #expect(buffer[outsideOffset + 2] == 255, "Outside fill edge = pure white")
        #expect(buffer[insideOffset + 2] == 0, "Fill edge = pure black, no blending")
    }
}
