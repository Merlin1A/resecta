import CoreGraphics
import Foundation

/// The measure of the screen test that compares the editor's fill with the
/// file the run writes: the three scans of each expected rectangle, the inside
/// check, the comparison where the line hides an edge, the turn into page
/// points, the correction for a page whose size in pixels is not whole, the
/// check of the read-out against the page's own white, the reading of the
/// page's ink at fit, and the names a case fails with. Plain functions of
/// bitmaps and numbers; every rectangle here is in device pixels of `shot`,
/// origin at its top-left, unless a line says otherwise.
nonisolated enum WitnessMeasure {
    typealias RGB = (r: Int, g: Int, b: Int)

    /// What a case stops with, by name. A nil reading is never a pass and never a skip.
    enum Failure: Error, Equatable {
        /// A view whose scans hold no fill, or whose inside is not covered.
        case fillAbsent(String)
        /// Absent in both views.
        case boxNotFound
        /// The three scans of one rectangle in one view differ by more than a device pixel.
        case scansDisagree(String)
        /// A seeded box's expected edge does not lie between the line's two ends.
        case lineOffTheBox
        /// The read-out's corner or size is not where the page's own white is.
        case readOutOffThePage
        /// Increase Contrast or Reduce Transparency is on.
        case displaySettingOn
        /// The written picture is not the size the case's quality makes, or could not be read.
        case paintedAtAnotherQuality(expected: String, read: String)
        /// A dragged box does not lie under the drag's two points.
        case boxNotUnderTheFinger
        /// The file's page shows a mark outside its fills and its recorded lines.
        case inkOutOfPlace(CGPoint)
    }

    /// The three scans of one expected rectangle. `window` and `expected` are device-pixel
    /// rectangles of `shot`; the bitmap is cut to `window`; scan i reads the row at 25, 50, 75 %
    /// of `expected`'s height with the column at `columns[i]` of its width (0.25, 0.5, 0.75;
    /// for a found box 0.5, 0.7, 0.9). `classed` is true in the editor; in the preview every
    /// pixel that is not paper is fill. Edges come back in `shot`'s own device pixels.
    static func threeScans(of shot: CGImage, window: CGRect, expected: CGRect,
                           columns: [CGFloat], classed: Bool,
                           paper: RGB, step: Int) -> [CanvasPixelProbe.Reading] {
        let none = CanvasPixelProbe.Reading(fill: nil, lineOuter: nil, lineInner: nil)
        let cut = window.integral
        guard columns.count == 3, let bitmap = shot.cropping(to: cut) else { return [none, none, none] }
        let dx = Int(cut.minX), dy = Int(cut.minY)
        func moved(_ e: CanvasPixelProbe.Edges?) -> CanvasPixelProbe.Edges? {
            e.map { .init(left: $0.left + dx, right: $0.right + dx, top: $0.top + dy, bottom: $0.bottom + dy) }
        }
        return zip([0.25, 0.5, 0.75] as [CGFloat], columns).map { rowShare, columnShare in
            let row = Int((expected.minY + expected.height * rowShare).rounded(.down)) - dy
            let column = Int((expected.minX + expected.width * columnShare).rounded(.down)) - dx
            if classed {
                let r = CanvasPixelProbe.reading(in: bitmap, row: row, column: column, paper: paper, step: step)
                return .init(fill: moved(r.fill), lineOuter: moved(r.lineOuter), lineInner: moved(r.lineInner))
            }
            let fill = CanvasPixelProbe.edges(in: bitmap, row: row, column: column, paper: paper, step: step)
            return .init(fill: moved(fill), lineOuter: nil, lineInner: nil)
        }
    }

    /// Whether the three scans' fills agree on every edge within `within` device pixels.
    /// A scan with no fill never agrees.
    static func agree(_ scans: [CanvasPixelProbe.Reading], within: Int) -> Bool {
        let fills = scans.compactMap(\.fill)
        guard !scans.isEmpty, fills.count == scans.count else { return false }
        let sides: [(CanvasPixelProbe.Edges) -> Int] = [\.left, \.right, \.top, \.bottom]
        return sides.allSatisfy { side in
            let values = fills.map(side)
            return values.max()! - values.min()! <= within
        }
    }

    /// The inside check: whether every device pixel of `row` and of `column` that lies inside `expected`,
    /// inset by `inset` on each side, is not paper.
    static func insideCovered(in shot: CGImage, expected: CGRect, inset: CGFloat, row: Int, column: Int,
                              paper: RGB, step: Int) -> Bool {
        guard let pixels = CanvasPixelProbe.DevicePixels(shot) else { return false }
        let inner = expected.insetBy(dx: inset, dy: inset)
        guard inner.width >= 1, inner.height >= 1,
              (0..<pixels.height).contains(row), (0..<pixels.width).contains(column) else { return false }
        let xs = Int(inner.minX.rounded(.up))..<Int(inner.maxX.rounded(.down))
        let ys = Int(inner.minY.rounded(.up))..<Int(inner.maxY.rounded(.down))
        guard xs.lowerBound >= 0, xs.upperBound <= pixels.width,
              ys.lowerBound >= 0, ys.upperBound <= pixels.height else { return false }
        let notPaper = { (p: RGB) in CanvasPixelProbe.mark(p, paper: paper, step: step) != .paper }
        return xs.allSatisfy { notPaper(pixels.rgb($0, row)) } && ys.allSatisfy { notPaper(pixels.rgb(column, $0)) }
    }

    /// Whether every device pixel of `row` between `from` and `to` is not paper.
    static func covered(in shot: CGImage, row: Int, from: Int, to: Int,
                        paper: RGB, step: Int) -> Bool {
        guard let pixels = CanvasPixelProbe.DevicePixels(shot), from <= to,
              (0..<pixels.height).contains(row), from >= 0, to < pixels.width else { return false }
        return (from...to).allSatisfy {
            CanvasPixelProbe.mark(pixels.rgb($0, row), paper: paper, step: step) != .paper
        }
    }

    /// One side of one scan, compared between the views, in page points. `outward` is +1 or -1: the sign of a step
    /// away from the box on that side. Where the editor's scan met the fill before the line,
    /// the preview's edge lies within `tolerance` of the editor's. Where it met the line first
    /// (its outer end lies further out than the fill read), the fill's edge is under the line,
    /// and the preview's edge lies between that reading less `tolerance` and the line's outer
    /// end plus `tolerance`.
    static func sideAgrees(editorFill: CGFloat, editorLineOuter: CGFloat?, preview: CGFloat,
                           outward: CGFloat, tolerance: CGFloat) -> Bool {
        let fill = outward * editorFill, shown = outward * preview
        if let line = editorLineOuter.map({ outward * $0 }), line > fill {
            return shown >= fill - tolerance && shown <= line + tolerance
        }
        return abs(shown - fill) <= tolerance
    }

    /// An edge read in device pixels, as a rectangle in window points: the outer boundary of
    /// each outermost pixel.
    static func windowRect(_ edges: CanvasPixelProbe.Edges, screenScale: CGFloat) -> CGRect {
        CGRect(x: CGFloat(edges.left) / screenScale, y: CGFloat(edges.top) / screenScale,
               width: CGFloat(edges.right + 1 - edges.left) / screenScale,
               height: CGFloat(edges.bottom + 1 - edges.top) / screenScale)
    }

    /// A window point to points of the page as displayed, origin at its bottom-left:
    /// `(window point - page origin) / scale`, with the y flip. `origin` is the read-out's
    /// top-left corner; `height` the page's displayed height in points.
    static func toPage(_ point: CGPoint, origin: CGPoint, scale: CGFloat, height: CGFloat) -> CGPoint {
        CGPoint(x: (point.x - origin.x) / scale, y: height - (point.y - origin.y) / scale)
    }

    /// A preview reading, in points from the page's left or bottom, to the content's place.
    static func corrected(_ reading: CGFloat, side: CGFloat, picture: Int, quality: Int) -> CGFloat {
        reading * CGFloat(picture) * 72 / (CGFloat(quality) * side)
    }

    /// Whether the page's own white agrees with the read-out. Down the column 8 pt inside
    /// the page's left edge and along the row 8 pt under its top edge, the longest run of page
    /// white begins and ends within two device pixels of the read-out's corner and of the corner
    /// plus its shown size. `origin` and `shown` are in window points.
    static func readOutOnThePage(_ shot: CGImage, origin: CGPoint, shown: CGSize, screenScale: CGFloat) -> Bool {
        guard let pixels = CanvasPixelProbe.DevicePixels(shot) else { return false }
        let white = { (p: RGB) in p.r >= 250 && p.g >= 250 && p.b >= 250 }
        func longest(_ count: Int, _ isWhite: (Int) -> Bool) -> (start: Int, end: Int)? {
            var best: (start: Int, end: Int)?, start: Int?
            for i in 0...count {
                let w = i < count && isWhite(i)
                if w, start == nil { start = i }
                if !w, let s = start {
                    if best == nil || i - s > best!.end - best!.start { best = (s, i) }
                    start = nil
                }
            }
            return best
        }
        let column = Int(((origin.x + 8) * screenScale).rounded(.down))
        let row = Int(((origin.y + 8) * screenScale).rounded(.down))
        guard (0..<pixels.width).contains(column), (0..<pixels.height).contains(row),
              let down = longest(pixels.height, { white(pixels.rgb(column, $0)) }),
              let across = longest(pixels.width, { white(pixels.rgb($0, row)) }) else { return false }
        let near = { (pixel: Int, point: CGFloat) in abs(CGFloat(pixel) - point * screenScale) <= 2 }
        return near(down.start, origin.y) && near(down.end, origin.y + shown.height)
            && near(across.start, origin.x) && near(across.end, origin.x + shown.width)
    }

    /// The first pixel of `page` that is not paper and lies in none of `allowed`, or nil.
    /// A bitmap that cannot be read answers (-1, -1), never nil.
    static func inkOutOfPlace(in shot: CGImage, page: CGRect, allowed: [CGRect],
                              paper: RGB, step: Int) -> CGPoint? {
        guard let pixels = CanvasPixelProbe.DevicePixels(shot) else { return CGPoint(x: -1, y: -1) }
        let area = page.integral.intersection(CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
        guard !area.isNull, area.width > 0, area.height > 0 else { return nil }
        for y in Int(area.minY)..<Int(area.maxY) {
            for x in Int(area.minX)..<Int(area.maxX)
            where CanvasPixelProbe.mark(pixels.rgb(x, y), paper: paper, step: step) != .paper {
                let centre = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                if !allowed.contains(where: { $0.contains(centre) }) { return CGPoint(x: x, y: y) }
            }
        }
        return nil
    }
}
