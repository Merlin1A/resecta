#if canImport(UIKit)
import UIKit
#else
import CoreGraphics
#endif

// See ARCH §2.3 for FillColor and ExpectedPixelBGRA definitions.

/// User-selected redaction fill color. Persisted via UserDefaults as a raw string.
/// Defined in RedactionEngine/Models/ (used by both the engine and Settings UI).
public enum FillColor: String, Sendable, CaseIterable {
    case black
    case white

    /// CGColor value for use in the pixel destruction fill.
    /// AC-1: UIColor path is required — CGColor(sRGBRed:...) is macOS-only.
    ///
    /// Color space safety (Experiment A3.1): UIColor(red:green:blue:alpha:) creates
    /// colors in extended sRGB. When drawn into the sRGB bitmap context, Core Graphics
    /// performs a color space conversion. For black (0,0,0) and white (1,1,1), this
    /// conversion is confirmed lossless — both produce byte-exact expected pixel values.
    /// Non-black/white colors are NOT safe via this path. See ARCH §2.3 AC-1.
    public var cgColor: CGColor {
        #if canImport(UIKit)
        switch self {
        case .black: UIColor(red: 0, green: 0, blue: 0, alpha: 1).cgColor
        case .white: UIColor(red: 1, green: 1, blue: 1, alpha: 1).cgColor
        }
        #else
        // macOS tooling destination: CGColor(srgbRed:) is available here and
        // produces the same byte-exact sRGB black/white as the UIColor path.
        switch self {
        case .black: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        case .white: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        }
        #endif
    }

    /// Expected BGRA pixel values for post-fill verification (ENGINE §3.4).
    /// Named struct prevents channel-swap regressions.
    public var expectedPixel: ExpectedPixelBGRA {
        switch self {
        case .black: ExpectedPixelBGRA(b: 0, g: 0, r: 0, a: 255)
        case .white: ExpectedPixelBGRA(b: 255, g: 255, r: 255, a: 255)
        }
    }
}

/// Named BGRA fields avoid channel-swap bugs.
/// Replaces the unnamed (UInt8, UInt8, UInt8, UInt8) tuple. See ARCH §2.3.
public struct ExpectedPixelBGRA: Sendable, Equatable {
    public let b: UInt8, g: UInt8, r: UInt8, a: UInt8

    public init(b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
        self.b = b
        self.g = g
        self.r = r
        self.a = a
    }
}
