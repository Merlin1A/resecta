import CoreGraphics
import Foundation

/// The ink test's tolerance band: how far (in 8-bit levels, per channel) a
/// pixel may sit from its glyph box's first pixel and still read as the same
/// colour. The exact-uniformity read the test made before this band let
/// near-white text, nearly transparent text and text under a nearly opaque
/// box through with their text layer: each shows a few levels of ink the eye
/// does not see. `tolerance` was set from a census over the born-digital
/// identity corpora at the production DPI — the largest value at which no
/// census page's inked glyph box reads as uniform — so ordinary text at any
/// weight stays above the band; the census is recorded with the change that
/// introduced it.
enum InkContrastFloor {

    /// Levels of 255, per channel, alpha included.
    static let tolerance: Int = 24

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
    static func isNearUniform(context: CGContext, rect: CGRect) throws -> Bool {
        guard let deviation = try maximumDeviation(
            context: context, rect: rect, stopAbove: tolerance) else { return false }
        return deviation <= tolerance
    }
}
