import CoreGraphics
import Foundation

/// Whether a page whose accurate recognition returned no line holds ink.
/// Decided on the picture recognition was given, with no second render and
/// no second recognition: the page has ink when its dark pixels, a band at
/// each edge left out, are at least the floor's share of the pixels counted.
/// It fails toward "not read": with no picture at hand, or no floor set, the
/// page has ink.
enum PageInk {

    /// A share of a picture's pixels, kept as two counts so every comparison
    /// is exact.
    struct DarkShare: Sendable, Equatable {
        let dark: Int
        let total: Int
    }

    /// A share written to three significant figures: `significand` (100 to
    /// 999) times ten to the minus `exponent`.
    struct FloorShare: Sendable, Equatable {
        let significand: Int
        let exponent: Int
    }

    /// The floor and the band at each edge that its measurement was made at.
    struct Setting: Sendable, Equatable {
        let floor: FloorShare
        let edgeBandInches: Double
    }

    /// Not set. It waits for the measurement on real blank pages and real
    /// one-line pages, and is written from its dated note in a change of its
    /// own. Until then every empty read is reported as ink: "not read:
    /// recognition found no text".
    static let setting: Setting? = nil

    /// A pixel darker than this (of 255, DeviceGray) is dark: the ink fit's
    /// threshold.
    static let darkThreshold: UInt8 = DocumentSearcher.inkFitThreshold

    /// True when `share` is at or above `floor`; true as well when either is
    /// missing or the share counted no pixel.
    static func hasInk(_ share: DarkShare?, floor: FloorShare?) -> Bool {
        guard let share, let floor, share.total > 0, let scale = power(floor.exponent) else { return true }
        return Int128(share.dark) * scale >= Int128(floor.significand) * Int128(share.total)
    }

    /// The empty read's answer from the share kept with it.
    static func emptyRead(_ share: DarkShare?, setting: Setting? = PageInk.setting) -> PageSearchCoverage.EmptyRead {
        hasInk(share, floor: setting?.floor) ? .ink : .blank
    }

    /// The floor set from the two real ranges: the geometric mean of the
    /// darkest blank page's share `b` and the lightest one-line page's share
    /// `l`, rounded down to three significant figures, so rounding never
    /// moves it toward reading print as blank. Nil when the ranges do not
    /// stand apart by the band rule (`b` at most half of `l`), when `b` is
    /// zero (no geometric mean), or when either share counted no pixel.
    static func floor(darkestBlank b: DarkShare, lightestLine l: DarkShare) -> FloorShare? {
        guard b.total > 0, l.total > 0, b.dark > 0, b.dark <= b.total, l.dark <= l.total,
              2 * Int128(b.dark) * Int128(l.total) <= Int128(l.dark) * Int128(b.total) else { return nil }
        let product = Int128(b.dark) * Int128(l.dark), pixels = Int128(b.total) * Int128(l.total)
        // The smallest exponent at which the mean is at least 100 units:
        // 100 × 10^-e ≤ √(product / pixels).
        for exponent in 0...18 {
            guard let scale = power(2 * exponent),
                  case let (scaled, overflow) = product.multipliedReportingOverflow(by: scale), !overflow
            else { return nil }
            guard 10_000 * pixels <= scaled else { continue }
            // The largest significand whose square stays under the product.
            let significand = (100...999).last { Int128($0 * $0) * pixels <= scaled } ?? 100
            return FloorShare(significand: significand, exponent: exponent)
        }
        return nil
    }

    /// Ten to `exponent`, nil past what an `Int128` holds.
    private static func power(_ exponent: Int) -> Int128? {
        guard (0...36).contains(exponent) else { return nil }
        var value: Int128 = 1
        for _ in 0..<exponent { value *= 10 }
        return value
    }

    /// The band left out at each edge, in whole pixels, rounded down: a
    /// rounded band never hides more of the page than the band named.
    static func edgeBandPixels(inches: Double, pixelsPerInch: Double) -> Int {
        let pixels = (inches * pixelsPerInch).rounded(.down)
        return pixels.isFinite && pixels > 0 ? Int(pixels) : 0
    }

    /// The dark pixels of `image` drawn on white in DeviceGray, `edgeBand`
    /// pixels at each edge left out. Nil when the band leaves no pixel or the
    /// picture cannot be drawn.
    static func darkShare(of image: CGImage, edgeBand: Int) -> DarkShare? {
        let width = image.width, height = image.height, band = max(0, edgeBand)
        guard width > 2 * band, height > 2 * band,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.interpolationQuality = .none
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height)
        var dark = 0
        for row in band..<(height - band) {
            let start = row * width
            for column in band..<(width - band) where pixels[start + column] < darkThreshold { dark += 1 }
        }
        return DarkShare(dark: dark, total: (width - 2 * band) * (height - 2 * band))
    }

    /// The share kept with an empty read: measured at the setting's band,
    /// nil when no picture is at hand or no floor is set (the page then
    /// reads as ink, with no pass over the picture).
    static func emptyReadShare(of picture: CGImage?, pixelsPerInch: Double,
                               setting: Setting? = PageInk.setting) -> DarkShare? {
        guard let picture, let setting else { return nil }
        return darkShare(of: picture,
                         edgeBand: edgeBandPixels(inches: setting.edgeBandInches, pixelsPerInch: pixelsPerInch))
    }
}
