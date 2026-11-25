import CoreGraphics
import Foundation
@testable import RedactionEngine

// Pages painted for the box check: a white page, with lines of print where
// asked, and boxes painted by the rule's own lines at a chosen level, then
// encoded as the writer encodes a page and walked. No found document.

enum BoxCheckFixtures {
    typealias Lines = PixelPaintRule.Lines

    /// One mark on a page: a rectangle of pixel lines and its colour.
    struct Mark {
        let lines: Lines
        var gray: CGFloat = 0
        var rgb: (CGFloat, CGFloat, CGFloat)? = nil
    }

    /// A page `w` by `h` pixels, white or with lines of print, with the marks
    /// painted on it in order, as the writer would store it.
    static func picture(width w: Int, height h: Int, gray: Bool = false, print: Bool = false,
                        colourPatch: Lines? = nil, marks: [Mark]) -> CGImage {
        let base = PageImageFixtures.madePage(width: w, height: h, gray: gray, blank: !print)
        let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let info = gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)!
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        if let p = colourPatch, !gray {
            ctx.setFillColor(red: 0.1, green: 0.5, blue: 0.9, alpha: 1)
            ctx.fill(rect(p, h))
        }
        for m in marks {
            if let (r, g, b) = m.rgb, !gray { ctx.setFillColor(red: r, green: g, blue: b, alpha: 1) } else { ctx.setFillColor(gray: m.gray, alpha: 1) }
            ctx.fill(rect(m.lines, h))
        }
        // The writer's pictures are sRGB (PixelOperations), and it encodes their
        // Exif in that one form: the colour picture is tagged so, its bytes unchanged.
        let image = ctx.makeImage()!
        return gray ? image : image.copy(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
    }

    /// Lines counted from the top, as a Core Graphics rectangle (origin bottom-left).
    static func rect(_ l: Lines, _ h: Int) -> CGRect {
        CGRect(x: l.left, y: h - l.bottom, width: l.right - l.left, height: l.bottom - l.top)
    }

    /// The picture encoded as the writer encodes it, and walked.
    static func walk(_ image: CGImage) -> (PageImageWalk, Data) {
        let jpeg = PageImageFixtures.encode(image)
        guard case .success(let walk) = try! JPEGEntropyWalk.walk(jpeg) else { fatalError("the fixture's picture did not walk") }
        return (walk, jpeg)
    }

    /// A box of the plan: `inner`, its `paint` (default `inner`), its limits.
    static func box(_ inner: PageRect64, paint: PageRect64? = nil, above: Int? = nil, below: Int? = nil) -> PaintedBox {
        PaintedBox(regionIDs: [UUID()], inner: inner, paint: paint ?? inner, tight: inner, limitAbove: above, limitBelow: below,
                   exposure: .canShowLength, treatment: .notAsked, bandMade: false, inkEnlargedCovered: false,
                   inkEnlargedToCap: false, asDrawn: paint == nil && above == nil && below == nil)
    }

    static func r(_ minX: Int, _ minY: Int, _ maxX: Int, _ maxY: Int) -> PageRect64 {
        PageRect64(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    /// The rule's paint for a box on a W by H frame at quality d.
    static func paint(_ b: PaintedBox, dpi d: Int, width w: Int, height h: Int) -> Lines {
        PixelPaintRule.pixelPaint(inner: b.inner, paint: b.paint, limitAbove: b.limitAbove, limitBelow: b.limitBelow,
                                  dpi: d, width: w, height: h)
    }

    /// A report of exactly these lines, rows counted from the bottom.
    static func report(_ l: Lines, height h: Int) -> RunRecord.PaintedPixels {
        RunRecord.PaintedPixels(firstColumn: l.left, firstRowFromBottom: h - l.bottom, columns: l.right - l.left, rows: l.bottom - l.top)
    }

    /// The box's inner rectangle in sixty-fourths whose pixel lines at quality d
    /// on an H-row frame are these: left column, top row, right, bottom (from the top).
    static func inner(left: Int, top: Int, right: Int, bottom: Int, dpi d: Int, height h: Int) -> PageRect64 {
        let s = PixelPaintRule.sixtyFourthsPerInch
        return r(PixelPaintRule.ceilDiv(left * s, d), PixelPaintRule.ceilDiv((h - bottom) * s, d),
                 PixelPaintRule.floorDiv(right * s, d), PixelPaintRule.floorDiv((h - top) * s, d))
    }

    /// Judge one box on a walked page.
    static func judge(_ b: PaintedBox, report: RunRecord.PaintedPixels?, on walk: PageImageWalk, dpi: Int,
                      sides: (Int, Int), fill: FillColor = .black) -> BoxOutcome {
        ExactFillCheck.judge(box: b, reported: report, walk: walk, dpi: dpi, widthSixtyFourths: sides.0,
                             heightSixtyFourths: sides.1, fill: fill)
    }
}
