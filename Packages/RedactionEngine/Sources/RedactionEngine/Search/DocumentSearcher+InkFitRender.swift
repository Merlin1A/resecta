import CoreGraphics
import Foundation
import PDFKit

// The ink fit's render (`DocumentSearcher+InkFit.swift`): a neighbourhood of the
// page drawn as the rasterizer draws it, and the ink of a word read from it.

extension DocumentSearcher {

    struct GrayBitmap {
        let pixels: [UInt8]
        let width: Int
        let height: Int
        /// A pixel darker than this is ink; with `light`, a pixel lighter than
        /// 255 minus it (light text on a dark ground).
        var threshold: UInt8 = DocumentSearcher.inkFitThreshold
        var light = false
        /// `x`, `y` in pixels from the window's bottom-left.
        func isInk(_ x: Int, _ y: Int) -> Bool {
            let value = pixels[(height - 1 - y) * width + x]
            return light ? value > 255 - threshold : value < threshold
        }
        /// The same pixels read with another ink rule.
        func reading(threshold: UInt8, light: Bool = false) -> GrayBitmap {
            GrayBitmap(pixels: pixels, width: width, height: height, threshold: threshold, light: light)
        }
    }

    /// How long a render waits for another draw of its private copy before
    /// the fit falls back (the read word's box, degraded).
    static let inkFitDrawWait: TimeInterval = 2

    /// `work`, a draw of `page`, on the caller's own thread under its copy's
    /// draw lock; nil in a cancelled task (a cancelled search renders nothing
    /// more), or when the lock is not had within `wait`.
    nonisolated static func drawn<T>(_ page: InkFitPage, wait: TimeInterval = inkFitDrawWait, _ work: () -> T) -> T? {
        if Task.isCancelled { return nil }
        guard let value = page.drawLock.draw(wait: wait, work) else {
            inkFitLogger.log("ink fit: another draw of the page's copy held it past its wait")
            return nil
        }
        return value
    }

    /// The page drawn as the rasterizer draws it (`PageRasterizer.drawingTransform`
    /// in PDFKit's rotation frame), cropped to `window` (visual points).
    nonisolated static func renderGray(_ cgPage: CGPDFPage, rotation: Int, visual: CGSize, window: CGRect,
                                       frame: InkFitFrame? = nil) -> GrayBitmap? {
        let width = Int((window.width * inkFitScale).rounded(.up))
        let height = Int((window.height * inkFitScale).rounded(.up))
        guard width > 0, height > 0, width * height <= 4_000_000 else { return nil }
        var pixels = [UInt8](repeating: 255, count: width * height)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.scaleBy(x: inkFitScale, y: inkFitScale)
            ctx.translateBy(x: -window.minX, y: -window.minY)
            // `window` in the reading frame: the page turned into it.
            if let frame, frame.turn != .upright { ctx.concatenate(frame.transform) }
            ctx.concatenate(PageRasterizer.drawingTransform(
                for: cgPage, box: .cropBox, rotation: rotation, targetRect: CGRect(origin: .zero, size: visual)))
            ctx.clip(to: cgPage.getBoxRect(.cropBox))
            ctx.drawPDFPage(cgPage)
            return true
        }
        return drawn ? GrayBitmap(pixels: pixels, width: width, height: height) : nil
    }

    /// The token's ink split into glyph columns (visual points, left to right):
    /// the columns with ink on the token's line, a blank column ending a run.
    /// The line's rows are the inked rows that meet Vision's box and those
    /// joined to them with no gap over two pixels, up to 0.6 of the box's
    /// height past it: Vision's box can sit high or low on its line, and a
    /// round digit's widest ink (the bowl of a 5, the foot of a 2) can lie on
    /// rows past it. A row inked across the window (a rule) is not the line.
    /// Nil when the box cannot be rendered.
    nonisolated static func glyphColumns(of token: InkToken, cgPage: CGPDFPage, rotation: Int, visual: CGSize,
                                         key: Int? = nil, frame: InkFitFrame? = nil) -> [ClosedRange<CGFloat>]? {
        #if DEBUG
        // The render-stall seam covers a token's glyph runs too (a queue of
        // its own; the stalled job only stalls).
        if let key, let injected = inkFitInjectedRenderStalls.value(for: key) {
            _ = onInkFitQueue(key: key, timeout: injected.timeout,
                              queue: DispatchQueue(label: "com.resecta.search.inkfit.stalled-columns")) {
                Thread.sleep(forTimeInterval: injected.stall)
            }
            return nil
        }
        #endif
        let window = token.rect.insetBy(dx: -1, dy: -0.6 * token.rect.height)
            .intersection(CGRect(origin: .zero, size: frame?.size ?? visual))
        let page = InkFitPage(cgPage)
        guard !window.isNull, window.width > 0, window.height > 0,
              let rendered = drawn(page, {
                  renderGray(page.page, rotation: rotation, visual: visual, window: window, frame: frame) }),
              let bitmap = rendered else { return nil }
        let s = inkFitScale
        let counts = (0..<bitmap.height).map { y in (0..<bitmap.width).reduce(0) { $0 + (bitmap.isInk($1, y) ? 1 : 0) } }
        let inked = counts.map { $0 > 0 && Double($0) < inkFitRuleShare * Double(bitmap.width) }
        let lo = max(0, Int(((token.rect.minY - window.minY) * s).rounded(.down)))
        let hi = min(bitmap.height - 1, Int(((token.rect.maxY - window.minY) * s).rounded(.up)) - 1)
        var rows = Set<Int>()
        if lo <= hi {
            for y in lo...hi where inked[y] { rows.insert(y) }
        }
        guard let first = rows.min(), let last = rows.max() else { return [] }
        var bottom = first, top = last
        while let next = (max(0, bottom - 3)..<bottom).last(where: { inked[$0] }) { bottom = next }
        while let next = ((top + 1)..<min(bitmap.height, top + 4)).first(where: { inked[$0] }) { top = next }
        var runs: [ClosedRange<CGFloat>] = []
        var start: Int?
        for x in 0...bitmap.width {
            let ink = x < bitmap.width && (bottom...top).contains { inked[$0] && bitmap.isInk(x, $0) }
            if ink, start == nil { start = x }
            if !ink, let s0 = start {
                runs.append((window.minX + CGFloat(s0) / s)...(window.minX + CGFloat(x) / s))
                start = nil
            }
        }
        return runs
    }

    /// Whether a token's glyph runs are its characters one by one: as many
    /// runs as characters, and each run as wide as its character can be (a
    /// narrow run is punctuation, a wide one is not; a character that can be
    /// either, like i or 1, takes any). A count that agrees by chance (one
    /// glyph split in two where two others touch) fails on the widths.
    nonisolated static func glyphRunsMatch(_ raw: String, _ columns: [ClosedRange<CGFloat>]) -> Bool {
        let characters = Array(raw)
        guard !columns.isEmpty, characters.count == columns.count else { return false }
        let widths = columns.map { $0.upperBound - $0.lowerBound }
        let median = widths.sorted()[widths.count / 2]
        let narrow: Set<Character> = [".", ",", ":", ";", "'", "\u{2019}", "`", "|", "!"]
        let either: Set<Character> = ["i", "l", "I", "1", "j", "t", "f", "r", "(", ")", "[", "]", "-", "/", "*", "\""]
        for (character, width) in zip(characters, widths) {
            if narrow.contains(character) {
                if width > 0.8 * median { return false }
            } else if !either.contains(character), width < 0.5 * median {
                return false
            }
        }
        return true
    }

    enum InkFitOutcome: Equatable { case fitted, capped, noInk, darkGround, otherLine }

    /// The ink of the word under `box`, in visual points: the run of inked rows
    /// that meets the box (a dot or an accent a small gap above or below joins
    /// it), then, on those rows, the inked columns that continue past either
    /// side of the box with no gap as wide as a word space, one pixel wider on
    /// every side. A row inked across the window (a rule) is not ink here. The
    /// window bounds the growth: a box that reaches its edge is `.capped`. Nil
    /// when no inked row meets the box, or on a dark ground.
    nonisolated static func inkBox(in bitmap: GrayBitmap, box: CGRect, window: CGRect,
                                   growLeft: Bool = true, growRight: Bool = true)
        -> (box: CGRect?, outcome: InkFitOutcome) {
        let s = inkFitScale
        let bx0 = max(0, Int(((box.minX - window.minX) * s).rounded(.down)))
        let bx1 = min(bitmap.width, Int(((box.maxX - window.minX) * s).rounded(.up)))
        let by0 = max(0, Int(((box.minY - window.minY) * s).rounded(.down)))
        let by1 = min(bitmap.height, Int(((box.maxY - window.minY) * s).rounded(.up)))
        guard bx1 > bx0, by1 > by0 else { return (nil, .noInk) }

        // Rules across the window (rows) and down it (columns), and a dark ground.
        var isRule = [Bool](repeating: false, count: bitmap.height)
        var columnInk = [Int](repeating: 0, count: bitmap.width)
        var inked = 0
        for y in 0..<bitmap.height {
            var n = 0
            for x in 0..<bitmap.width where bitmap.isInk(x, y) { n += 1; columnInk[x] += 1 }
            inked += n
            isRule[y] = Double(n) >= inkFitRuleShare * Double(bitmap.width)
        }
        if Double(inked) > inkFitDarkGroundShare * Double(bitmap.width * bitmap.height) { return (nil, .darkGround) }
        let isRuleColumn = columnInk.map { Double($0) >= inkFitRuleShare * Double(bitmap.height) }

        func rowHasInk(_ y: Int, _ x0: Int, _ x1: Int) -> Bool {
            guard !isRule[y] else { return false }
            for x in x0..<x1 where !isRuleColumn[x] && bitmap.isInk(x, y) { return true }
            return false
        }
        // Inked row runs across the box's columns.
        var runs: [ClosedRange<Int>] = []
        var start: Int?
        for y in 0..<bitmap.height {
            if rowHasInk(y, bx0, bx1) { if start == nil { start = y } } else if let s0 = start { runs.append(s0...(y - 1)); start = nil }
        }
        if let s0 = start { runs.append(s0...(bitmap.height - 1)) }
        // The line with the most rows inside the box; less than half the box
        // inked by any line means the box sits between lines (a layer set more
        // than half a line off): no fit.
        func overlap(_ r: ClosedRange<Int>) -> Int { max(0, min(r.upperBound + 1, by1) - max(r.lowerBound, by0)) }
        guard let line = runs.max(by: { overlap($0) < overlap($1) }), overlap(line) > 0 else { return (nil, .noInk) }
        guard overlap(line) * 2 >= by1 - by0 else { return (nil, .otherLine) }
        var lo = line.lowerBound, hi = line.upperBound
        // A dot or an accent: a shorter run a small gap away joins the band.
        var grew = true
        while grew {
            grew = false
            let band = hi - lo + 1, gap = max(2, Int(0.35 * Double(band)))
            for r in runs where r.upperBound < lo || r.lowerBound > hi {
                let short = r.count * 2 <= band
                let near = r.upperBound < lo ? lo - r.upperBound - 1 <= gap : r.lowerBound - hi - 1 <= gap
                if short && near { lo = min(lo, r.lowerBound); hi = max(hi, r.upperBound); grew = true }
            }
        }
        // Columns on the band: continue past each side while the gap stays
        // narrower than a word space.
        func columnHasInk(_ x: Int) -> Bool {
            guard !isRuleColumn[x] else { return false }
            for y in lo...hi where !isRule[y] && bitmap.isInk(x, y) { return true }
            return false
        }
        let gapTolerance = max(2, Int(0.15 * Double(hi - lo + 1)))
        var right = bx1 - 1, x = bx1
        while growRight, x < bitmap.width, x - right <= gapTolerance { if columnHasInk(x) { right = x }; x += 1 }
        var left = bx0, xl = bx0 - 1
        while growLeft, xl >= 0, left - xl <= gapTolerance { if columnHasInk(xl) { left = xl }; xl -= 1 }
        let capped = lo == 0 || hi == bitmap.height - 1 || left == 0 || right == bitmap.width - 1
        // One render pixel outward on every side: an edge pixel the
        // anti-aliasing half-inks is inside the box (the safe direction).
        return (CGRect(x: window.minX + CGFloat(left - 1) / s, y: window.minY + CGFloat(lo - 1) / s,
                       width: CGFloat(right + 3 - left) / s, height: CGFloat(hi + 3 - lo) / s),
                capped ? .capped : .fitted)
    }
}
