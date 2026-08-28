import Testing
import Foundation
import CoreGraphics
@testable import RedactionEngine

// Fill coverage when the raster dimension is not an integer multiple
// of the page's point size. `renderPageFromCGPage` sizes the bitmap
// `ceil(points × dpi/72)` while the content is drawn spanning exactly
// `points × dpi/72`, so a rect scaled by the BITMAP dimension can sit up to
// 1 px off the CONTENT basis. `normalizedToFillPixels`' 1-px outward
// expansion covers that boundary row/column. This suite reproduces the basis
// split directly: content drawn on the content basis, regions mapped through
// the production fill path, coverage asserted on the content basis.
//
// A4 at 150/200/300 DPI has a non-integral raster dimension at every tier
// (595.2756 × 841.8898 pt), so all three tiers exercise the mismatch.
//
// Fill color is WHITE on a white background with black bars: any bar pixel
// the fill misses stays black and the assert sees it — a black fill would
// render the residue invisible against the bar's own ink.

@Suite("Fill coverage across raster bases")
struct FillCoverageBasisTests {

    private enum FixtureError: Error { case contextFailed }

    /// A4 in PostScript points.
    private static let pageWidthPt: CGFloat = 595.2756
    private static let pageHeightPt: CGFloat = 841.8898

    /// Bars in point coordinates (non-integral placements — the mismatch is
    /// coordinate-dependent, so several placements are checked per tier).
    /// Each bar's redaction region equals the bar extent exactly.
    private static let barsPt: [CGRect] = [
        CGRect(x: 101.3, y: 200.7, width: 150.4, height: 20.6),
        CGRect(x: 320.9, y: 455.1, width: 180.2, height: 14.3),
        CGRect(x: 55.5, y: 700.2, width: 240.8, height: 30.1),
        CGRect(x: 402.6, y: 90.4, width: 120.7, height: 22.9),
    ]

    @Test("A4 bar extents are fully covered at 150/200/300 DPI",
          arguments: [150, 200, 300])
    func a4BarExtentsFullyCovered(dpi: Int) throws {
        let scale = CGFloat(dpi) / 72.0
        // The production bitmap sizing: ceil of the content extent.
        let pw = Int(ceil(Self.pageWidthPt * scale))
        let ph = Int(ceil(Self.pageHeightPt * scale))
        guard let ctx = createBitmapContext(width: pw, height: ph) else {
            throw FixtureError.contextFailed
        }

        // White page background.
        ctx.setShouldAntialias(false)
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))

        // Draw the bars BLACK on the CONTENT basis: point coordinates under
        // a dpi/72 CTM scale, exactly how page content reaches the raster.
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        for bar in Self.barsPt {
            ctx.fill(bar)
        }
        ctx.restoreGState()

        // Regions equal the bar extents exactly, in normalized page space.
        let regions = Self.barsPt.map { bar in
            RedactionRegion(
                id: UUID(),
                normalizedRect: CGRect(
                    x: bar.minX / Self.pageWidthPt,
                    y: bar.minY / Self.pageHeightPt,
                    width: bar.width / Self.pageWidthPt,
                    height: bar.height / Self.pageHeightPt
                ),
                source: .manual
            )
        }

        // The production fill path (maps normalized × BITMAP dimensions).
        try applyRedactionFills(context: ctx, regions: regions, fillColor: .white)

        // Assert on the CONTENT basis: every pixel the bar's ink could
        // occupy must now be white. Content pixel extent = the bar's point
        // extent × scale, floor/ceil to cover its antialiasing-free edges.
        let data = try #require(ctx.data)
        let buf = data.assumingMemoryBound(to: UInt8.self)
        let bpr = ctx.bytesPerRow
        for (barIndex, bar) in Self.barsPt.enumerated() {
            let minX = max(0, Int(floor(bar.minX * scale)))
            let maxX = min(pw, Int(ceil(bar.maxX * scale)))
            let minY = max(0, Int(floor(bar.minY * scale)))
            let maxY = min(ph, Int(ceil(bar.maxY * scale)))
            var residue = 0
            var firstResidue: (Int, Int)?
            for y in minY..<maxY {
                let memoryRow = ph - 1 - y
                for x in minX..<maxX {
                    let off = memoryRow * bpr + x * 4
                    // BGRA — white is (255, 255, 255, 255).
                    if buf[off] != 255 || buf[off + 1] != 255 || buf[off + 2] != 255 {
                        residue += 1
                        if firstResidue == nil { firstResidue = (x, y) }
                    }
                }
            }
            #expect(residue == 0,
                    "bar \(barIndex) at \(dpi) DPI: \(residue) non-fill pixel(s) inside the bar extent, first at \(String(describing: firstResidue))")
        }
    }
}
