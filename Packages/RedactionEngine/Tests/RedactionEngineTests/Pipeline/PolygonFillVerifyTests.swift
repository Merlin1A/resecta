import Testing
import Foundation
import CoreGraphics
@testable import RedactionEngine

// DRAW-1 — Polygon fill + scanline-mask verify.
//
// Pins the polygon rendering path on `applyRedactionFills` (CGMutablePath
// + .evenOdd) and the polygon-aware verify on `verifyPolygonFill`
// (1-bit mask + memcmp over mask-set spans). The hexagon fixture
// exercises both convex and adjacent-edge interactions; the inverted-pixel
// test pins the verify contract end-to-end.
//
// SECURITY: polygon fill correctness is a redaction-engine invariant.
// Pixels reported as inside the polygon must match the fill color
// exactly under blend mode `.copy` with anti-aliasing disabled. The
// mask path verifies only inside pixels — pixels outside the polygon
// are excluded by `Layer 6` (sandwich spatial exclusion) rather than
// pixel verify.

@Suite("Polygon Fill + Verify (DRAW-1)")
struct PolygonFillVerifyTests {

    // MARK: - Helpers

    private enum FixtureError: Error { case contextFailed }

    private static func makeContext(_ size: Int) throws -> CGContext {
        guard let ctx = createBitmapContext(width: size, height: size) else {
            throw FixtureError.contextFailed
        }
        // Paint non-fill (red) so verifyPolygonFill must observe the
        // black fill — a contextually-empty buffer would falsely pass.
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return ctx
    }

    /// Hexagon in normalized coordinates centred on (0.5, 0.5) with
    /// "radius" ~0.4. Vertices go counter-clockwise in normalized
    /// space; concrete winding is fine because the engine fills with
    /// even-odd.
    private static let normalizedHexagon: [CGPoint] = {
        let cx: CGFloat = 0.5
        let cy: CGFloat = 0.5
        let r: CGFloat = 0.4
        var verts: [CGPoint] = []
        for i in 0..<6 {
            let theta = (CGFloat(i) / 6.0) * 2 * .pi
            verts.append(CGPoint(
                x: cx + r * cos(theta),
                y: cy + r * sin(theta)
            ))
        }
        return verts
    }()

    private static func hexagonRegion() -> RedactionRegion {
        let verts = normalizedHexagon
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for v in verts {
            if v.x < minX { minX = v.x }
            if v.x > maxX { maxX = v.x }
            if v.y < minY { minY = v.y }
            if v.y > maxY { maxY = v.y }
        }
        return RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(
                x: minX, y: minY,
                width: maxX - minX, height: maxY - minY
            ),
            source: .manual,
            vertices: verts
        )
    }

    /// Read a pixel at (x, y) in context coordinates (bottom-left origin)
    /// from a BGRA bitmap context and return (B, G, R, A).
    private static func readPixel(
        _ ctx: CGContext, x: Int, y: Int
    ) -> (UInt8, UInt8, UInt8, UInt8)? {
        guard let data = ctx.data else { return nil }
        let buf = data.assumingMemoryBound(to: UInt8.self)
        let bpr = ctx.bytesPerRow
        let memoryRow = ctx.height - 1 - y
        let off = memoryRow * bpr + x * 4
        return (buf[off], buf[off + 1], buf[off + 2], buf[off + 3])
    }

    // MARK: - Tests

    @Test("Hexagon fills every pixel inside the polygon mask")
    func testHexagonFillsInterior() throws {
        let size = 200
        let ctx = try Self.makeContext(size)
        let region = Self.hexagonRegion()

        try applyRedactionFills(
            context: ctx, regions: [region], fillColor: .black
        )

        // Build the expected mask using the same routine the verifier
        // uses. Walk it: every "inside" pixel must read as (0, 0, 0, 255)
        // in BGRA. Pixel verify alone is the production check; this
        // assertion adds belt-and-suspenders by reading the raw bitmap.
        let pixelVerts = Self.normalizedHexagon.map { v in
            normalizedVertexToPixels(
                v, bitmapWidth: size, bitmapHeight: size
            )
        }
        guard let mask = buildPolygonMask(
            pixelVertices: pixelVerts,
            bitmapWidth: size, bitmapHeight: size
        ) else {
            Issue.record("expected polygon mask, got nil")
            return
        }
        #expect(mask.insidePixelCount > 0,
                "hexagon mask must have non-zero interior")

        var checkedInside = 0
        for row in 0..<mask.height {
            for col in 0..<mask.width {
                guard mask.bits[row * mask.width + col] != 0 else { continue }
                let cx = mask.originX + col
                let cy = mask.originY + row
                guard let (b, g, r, a) = Self.readPixel(ctx, x: cx, y: cy)
                else {
                    Issue.record("pixel read failed at (\(cx), \(cy))")
                    return
                }
                #expect(b == 0 && g == 0 && r == 0 && a == 255,
                        "inside pixel (\(cx), \(cy)) BGRA=\(b),\(g),\(r),\(a) — expected (0,0,0,255)")
                checkedInside += 1
            }
        }
        #expect(checkedInside == mask.insidePixelCount)
    }

    @Test("Hexagon leaves pixels outside the bounding rect unchanged")
    func testHexagonLeavesOutsideUnchanged() throws {
        let size = 200
        let ctx = try Self.makeContext(size)
        let region = Self.hexagonRegion()

        try applyRedactionFills(
            context: ctx, regions: [region], fillColor: .black
        )

        // Pixels at the four corners of the page are well outside the
        // hexagon's bounding rect (the hexagon spans ~[0.1, 0.9] × [0.1,
        // 0.9]). They should still read as the pre-fill colour
        // (red, BGRA = (0, 0, 255, 255)).
        let corners = [
            (0, 0),
            (size - 1, 0),
            (0, size - 1),
            (size - 1, size - 1),
        ]
        for (x, y) in corners {
            guard let (b, g, r, a) = Self.readPixel(ctx, x: x, y: y) else {
                Issue.record("pixel read failed at (\(x), \(y))")
                return
            }
            #expect(b == 0 && g == 0 && r == 255 && a == 255,
                    "outside corner (\(x), \(y)) BGRA=\(b),\(g),\(r),\(a) — expected (0,0,255,255)")
        }
    }

    @Test("verifyPolygonFill detects a single missed pixel inside the polygon")
    func testPolygonVerifyCatchesMissedPixel() throws {
        let size = 200
        let ctx = try Self.makeContext(size)
        let region = Self.hexagonRegion()

        try applyRedactionFills(
            context: ctx, regions: [region], fillColor: .black
        )

        let pixelVerts = Self.normalizedHexagon.map { v in
            normalizedVertexToPixels(
                v, bitmapWidth: size, bitmapHeight: size
            )
        }

        // Sanity gate — full fill should pass.
        #expect(try verifyPolygonFill(
            context: ctx,
            pixelVertices: pixelVerts,
            expectedColor: FillColor.black.expectedPixel
        ))

        // Flip a single mask-set pixel back to the background colour
        // (red BGRA = (0, 0, 255, 255)). Pick the polygon centre — a
        // point that always lies inside the even-odd interior. // LegalPhrases:safe
        let centreX = size / 2
        let centreY = size / 2
        guard let data = ctx.data else {
            Issue.record("ctx.data nil")
            return
        }
        let buf = data.assumingMemoryBound(to: UInt8.self)
        let memoryRow = size - 1 - centreY
        let off = memoryRow * ctx.bytesPerRow + centreX * 4
        buf[off] = 0       // B
        buf[off + 1] = 0   // G
        buf[off + 2] = 255 // R — tampered back to red
        buf[off + 3] = 255 // A

        let stillPasses = try verifyPolygonFill(
            context: ctx,
            pixelVertices: pixelVerts,
            expectedColor: FillColor.black.expectedPixel
        )
        #expect(!stillPasses,
                "verifyPolygonFill must detect the tampered centre pixel")
    }

    @Test("Mask interior count matches a closed-form area approximation")
    func testHexagonMaskAreaSanity() throws {
        // Regular hexagon area ≈ (3√3/2) × r²; converted into pixels at
        // 200×200 with r=0.4 (in normalized space) ≈ 200×200×0.4² ×
        // (3√3/2) ÷ 1 ≈ 8313 pixels. The mask uses scanline pixel-centre
        // inclusion so the actual count drifts a few percent; assert a
        // generous ±15% band so a future even-odd refactor that doubles
        // or halves the interior would still fail loudly.
        let size = 200
        let pixelVerts = Self.normalizedHexagon.map { v in
            normalizedVertexToPixels(
                v, bitmapWidth: size, bitmapHeight: size
            )
        }
        guard let mask = buildPolygonMask(
            pixelVertices: pixelVerts,
            bitmapWidth: size, bitmapHeight: size
        ) else {
            Issue.record("mask nil"); return
        }
        let r: Double = 0.4 * Double(size)
        let analyticArea = 1.5 * sqrt(3.0) * r * r  // ~8313 px²
        let lower = Int(analyticArea * 0.85)
        let upper = Int(analyticArea * 1.15)
        #expect(
            mask.insidePixelCount >= lower && mask.insidePixelCount <= upper,
            "hexagon mask area=\(mask.insidePixelCount) outside [\(lower), \(upper)]"
        )
    }

    // MARK: - Degenerate polygon early-exit (CAT-388)

    @Test("Degenerate collinear polygon verifies as a pass via the interior-pixel early-exit (CAT-388)")
    func testDegenerateCollinearPolygonVerifyPasses() throws {
        let size = 200
        let ctx = try Self.makeContext(size)

        // Three collinear vertices on the diagonal y = x. The bounding rect is
        // non-degenerate (width and height > 0), so buildPolygonMask returns a
        // mask, but the even-odd fill marks no interior pixels — a zero-area
        // polygon. verifyPolygonFill takes the no-interior-pixels early-exit and
        // reports a pass: nothing was filled, so there is nothing to verify.
        let pixelVerts = [
            CGPoint(x: 40, y: 40),
            CGPoint(x: 100, y: 100),
            CGPoint(x: 160, y: 160),
        ]

        guard let mask = buildPolygonMask(
            pixelVertices: pixelVerts, bitmapWidth: size, bitmapHeight: size
        ) else {
            Issue.record("expected a non-nil mask for a diagonal collinear triple")
            return
        }
        // The new boolean guard must agree with the popcount on the empty mask.
        #expect(mask.insidePixelCount == 0,
                "a zero-area collinear polygon must mark no interior pixels")
        #expect(!mask.hasInteriorPixels,
                "hasInteriorPixels must agree with insidePixelCount == 0")

        let passes = try verifyPolygonFill(
            context: ctx,
            pixelVertices: pixelVerts,
            expectedColor: FillColor.black.expectedPixel
        )
        #expect(passes,
                "degenerate (no-interior) polygon takes the early-exit pass")
    }

    // MARK: - Unit-square clipping (CAT-360)

    @Test("CAT-360: clipPolygonToUnitRect replaces an out-of-bounds vertex with boundary crossings")
    func clipPolygonToUnitRectReplacesClampWithCrossings() {
        // Triangle whose left apex sits just outside the unit square.
        let triangle = [
            CGPoint(x: -0.01, y: 0.5),
            CGPoint(x: 0.5, y: 0.0),
            CGPoint(x: 0.5, y: 1.0),
        ]
        let clipped = clipPolygonToUnitRect(triangle)
        #expect(clipped.count >= 3, "clip must keep a fillable polygon")
        #expect(clipped.allSatisfy { $0.x >= -1.0e-9 },
                "clipped polygon must not extend past the left edge")
        // A per-axis clamp would collapse the apex to one point (0, 0.5);
        // clipping replaces it with TWO crossings on x = 0 straddling y = 0.5.
        let onLeftEdge = clipped.filter { abs($0.x) < 1.0e-6 }
        #expect(onLeftEdge.count >= 2,
                "apex must become two x=0 crossings, not one clamped point")
        #expect(onLeftEdge.contains { $0.y < 0.5 } && onLeftEdge.contains { $0.y > 0.5 },
                "the two crossings must straddle the apex's y")
    }

    @Test("CAT-360: a vertex just outside the unit square fills the true edge span with no notch")
    func polygonVertexOutsideUnitRect_noNotch() throws {
        let size = 600
        let ctx = try Self.makeContext(size)
        // Wide triangle with its left apex 0.01 outside the page box. A clamp
        // pins the apex to (0, 0.5) so the near-left column fills only a sliver
        // around y = 0.5; clipping fills the full boundary-crossing span.
        let triangle = [
            CGPoint(x: -0.01, y: 0.5),
            CGPoint(x: 0.5, y: 0.0),
            CGPoint(x: 0.5, y: 1.0),
        ]
        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0, y: 0, width: 0.5, height: 1),
            source: .manual,
            vertices: triangle
        )
        try applyRedactionFills(context: ctx, regions: [region], fillColor: .black)

        // Near-left column: clipped fill spans ~rows 293–307; a clamped apex
        // fills only ~rows 299–301. Rows 295 and 305 lie in the notch a clamp
        // leaves un-filled. BGRA: black fill (0,0,0,255); background (0,0,255,255).
        func isBlack(_ x: Int, _ y: Int) -> Bool {
            guard let (b, g, r, a) = Self.readPixel(ctx, x: x, y: y) else { return false }
            return b == 0 && g == 0 && r == 0 && a == 255
        }
        #expect(isBlack(1, 300), "polygon centre row must be filled")
        #expect(isBlack(1, 295), "row above centre must be filled — no notch (CAT-360)")
        #expect(isBlack(1, 305), "row below centre must be filled — no notch (CAT-360)")
        // A pixel far from the triangle keeps the background, proving the
        // buffer is not uniformly filled.
        guard let (_, _, rFar, _) = Self.readPixel(ctx, x: 1, y: 80) else {
            Issue.record("pixel read failed"); return
        }
        #expect(rFar == 255, "a pixel far outside the polygon stays background")
    }
}
