import CoreGraphics
import Foundation

/// The ink test's tolerance band: how far (in 8-bit levels, per channel) a
/// pixel may sit from its glyph box's first pixel and still read as the same
/// colour. The exact-uniformity read the test made before this band let
/// near-white text, nearly transparent text and text under a nearly opaque
/// box through with their text layer: each shows a few levels of ink the eye
/// does not see. The band was first set from a census over the born-digital
/// identity corpora at the production DPI — the largest value (24) at which
/// no census page's inked glyph box reads as uniform — and then tightened to
/// half that: at 24 a footer or a watermark one level lighter than the
/// census's faintest inked fixture (0.905 grey on white, 24 levels) read as
/// inkless and sent its page image-only. The faint-ink fixtures the band
/// exists for sit well inside the narrower band (near-white 0.985 grey ≈ 4
/// levels, 2 % alpha ≈ 5, a 97 % box over black ≈ 8), and every inked census
/// glyph stays above it; the census is recorded with the change that
/// introduced the band.
enum InkContrastFloor {

    /// Levels of 255, per channel, alpha included.
    static let tolerance: Int = 12

    /// The largest per-channel distance between any pixel of `rect` and the
    /// box's first pixel, alpha included; nil when the aligned, clamped box
    /// covers no pixel. Stops early once `stopAbove` is exceeded (the ink
    /// test needs only the verdict). Reads the context's BGRA buffer the way
    /// `verifyFill` does — memory row 0 is the top of the image — with a
    /// cooperative cancellation check every `cancellationBandRows` rows.
    static func maximumDeviation(
        context: CGContext, rect: CGRect, stopAbove: Int? = nil
    ) throws -> Int? {
        guard let data = context.data else { return nil }
        let buffer = data.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = context.bytesPerRow
        let aligned = rect.pixelAligned()
        let minX = max(0, Int(aligned.minX))
        let minY = max(0, Int(aligned.minY))
        let maxX = min(context.width, Int(aligned.maxX))
        let maxY = min(context.height, Int(aligned.maxY))
        guard minX < maxX, minY < maxY else { return nil }

        let firstRow = context.height - 1 - minY
        let first = buffer + firstRow * bytesPerRow + minX * 4
        let reference = (Int(first[0]), Int(first[1]), Int(first[2]), Int(first[3]))

        var deviation = 0
        var rowsSinceCheck = 0
        for contextY in minY..<maxY {
            if rowsSinceCheck == 0 { try Task.checkCancellation() }
            let row = buffer + (context.height - 1 - contextY) * bytesPerRow
            var pixel = row + minX * 4
            for _ in minX..<maxX {
                let d = max(
                    abs(Int(pixel[0]) - reference.0), abs(Int(pixel[1]) - reference.1),
                    abs(Int(pixel[2]) - reference.2), abs(Int(pixel[3]) - reference.3))
                if d > deviation {
                    deviation = d
                    if let stopAbove, deviation > stopAbove { return deviation }
                }
                pixel += 4
            }
            rowsSinceCheck += 1
            if rowsSinceCheck >= cancellationBandRows { rowsSinceCheck = 0 }
        }
        return deviation
    }

    /// True when every pixel of `rect` lies within `tolerance` of the box's
    /// first pixel on every channel: the box shows no ink. An empty box is
    /// not near-uniform (nothing was read).
    static func isNearUniform(
        context: CGContext, rect: CGRect, band: Int = tolerance
    ) throws -> Bool {
        guard let deviation = try maximumDeviation(
            context: context, rect: rect, stopAbove: band) else { return false }
        return deviation <= band
    }

    /// The band read for a glyph that sits on textured content — the band
    /// before `tolerance` was halved. A glyph on an image (a scanned page,
    /// a photograph, a noisy scanned bar under a stale text layer) is read
    /// against this wider band, so the halving, made for faint text on
    /// clean paper, never lets more through there than the wider band did.
    static let texturedBand: Int = 24

    /// The band to read a glyph's box against: `texturedBand` when the
    /// content just beyond the box across the font's height — a strip a
    /// quarter of the box deep on each side, outside `box` (pixels, the
    /// halo included) — spans more than `tolerance` on any channel; else
    /// `tolerance`. Faint text on clean paper keeps the narrow band.
    static func band(
        forBox box: CGRect, rotation: Int, context: CGContext
    ) throws -> Int {
        let upright = (((rotation % 360) + 360) % 360) % 180 == 0
        let depth = max(2, ((upright ? box.height : box.width) / 4).rounded())
        let strips = upright
            ? [CGRect(x: box.minX, y: box.maxY, width: box.width, height: depth),
               CGRect(x: box.minX, y: box.minY - depth, width: box.width, height: depth)]
            : [CGRect(x: box.maxX, y: box.minY, width: depth, height: box.height),
               CGRect(x: box.minX - depth, y: box.minY, width: depth, height: box.height)]
        for strip in strips {
            if try spans(context: context, rect: strip, atMost: tolerance) == false { return texturedBand }
        }
        return tolerance
    }

    /// Whether `rect` spans at most `levels` on every channel, alpha
    /// included; nil when the clamped rect covers no pixel.
    static func spans(context: CGContext, rect: CGRect, atMost levels: Int) throws -> Bool? {
        guard let data = context.data else { return nil }
        let buffer = data.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = context.bytesPerRow
        let minX = max(0, Int(rect.minX)), minY = max(0, Int(rect.minY))
        let maxX = min(context.width, Int(rect.maxX)), maxY = min(context.height, Int(rect.maxY))
        guard minX < maxX, minY < maxY else { return nil }
        try Task.checkCancellation()
        var low = [255, 255, 255, 255], high = [0, 0, 0, 0]
        for contextY in minY..<maxY {
            var pixel = buffer + (context.height - 1 - contextY) * bytesPerRow + minX * 4
            for _ in minX..<maxX {
                for channel in 0..<4 {
                    let v = Int(pixel[channel])
                    if v < low[channel] { low[channel] = v }
                    if v > high[channel] { high[channel] = v }
                    if high[channel] - low[channel] > levels { return false }
                }
                pixel += 4
            }
        }
        return true
    }

    /// True when `rect` (pixel-aligned inward by the caller) spans at most
    /// `band` levels on every channel, alpha included: its darkest and
    /// lightest pixels sit inside one band. The same sensitivity as the halo
    /// test — a glyph whose strokes clear the band against its counters and
    /// side bearings reads as ink — read on the core alone, so page colour in
    /// the halo cannot speak for a covered glyph. An empty box is not uniform.
    static func isCoreNearUniform(
        context: CGContext, rect: CGRect, band: Int = tolerance
    ) throws -> Bool {
        try spans(context: context, rect: rect, atMost: band) ?? false
    }

    /// The core of a glyph box in bitmap pixels: rounded inward (no halo),
    /// the full advance, and the band from 35 % to 65 % of the font's height
    /// above the box's bottom — between the baseline and the x-height in a
    /// Latin face, where every letter and digit has both stroke and space.
    /// The font's height runs across the displayed frame on a page turned a
    /// quarter. Nil when the band covers no pixel.
    static func glyphCore(
        _ normalized: CGRect, rotation: Int, bitmapWidth: Int, bitmapHeight: Int
    ) -> CGRect? {
        let w = CGFloat(bitmapWidth), h = CGFloat(bitmapHeight)
        var minX = normalized.minX * w, maxX = normalized.maxX * w
        var minY = normalized.minY * h, maxY = normalized.maxY * h
        if (((rotation % 360) + 360) % 360) % 180 == 0 {
            (minY, maxY) = (minY + 0.35 * (maxY - minY), minY + 0.65 * (maxY - minY))
        } else {
            (minX, maxX) = (minX + 0.35 * (maxX - minX), minX + 0.65 * (maxX - minX))
        }
        let core = CGRect(x: ceil(minX), y: ceil(minY),
                          width: floor(maxX) - ceil(minX), height: floor(maxY) - ceil(minY))
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        return core.isNull || core.width < 1 || core.height < 1 ? nil : core
    }
}
