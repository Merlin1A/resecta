import SwiftUI

/// The app icon, drawn from shapes: the icon's paper field as a tile with the
/// iOS 26 icon outline (continuous corners at 0.26 of the side), and on it
/// the redaction-bars mark at the icon's own place and scale — two ink bars,
/// one teal bar and twelve grey text runs on the icon's 821 × 435 unit grid,
/// whose ink box sits at (106, 286) on the icon's 1024 canvas. A 0.5 pt edge
/// (a hairline in light, a top-lit rim in dark) and, in light, the cards'
/// resting shadow give it the depth of an icon. Decorative: hidden from
/// accessibility, and kept out of Smart Invert like any icon. Home, the
/// first-launch gate and the app-switcher overlay draw it.
struct HomeMark: View {
    /// One shape on the unit grid.
    struct Shape: Equatable {
        enum Kind: Equatable { case bar, run }
        let kind: Kind
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat
        let radius: CGFloat
        /// Which of the three bars (0-based); nil for a run.
        let bar: Int?
    }

    /// The icon's unit grid: the mark's ink box.
    static let gridWidth: CGFloat = 821
    static let gridHeight: CGFloat = 435

    /// The icon's canvas, and where the ink box sits on it.
    static let canvas: CGFloat = 1024
    static let inkOrigin = CGPoint(x: 106, y: 286)

    /// The tile's corner radius as a fraction of its side (the iOS 26 icon).
    static let cornerFraction: CGFloat = 0.26

    /// The fifteen shapes: three bars (height 103, radius 25) and twelve
    /// runs (35 × 45, radius 9), as measured on the icon.
    static let shapes: [Shape] = {
        var list: [Shape] = [
            Shape(kind: .bar, x: 0, y: 0, width: 703, height: 103, radius: 25, bar: 0),
            Shape(kind: .bar, x: 0, y: 166, width: 571, height: 103, radius: 25, bar: 1),
            Shape(kind: .bar, x: 0, y: 332, width: 411, height: 103, radius: 25, bar: 2),
        ]
        let rows: [(y: CGFloat, xs: [CGFloat])] = [
            (29, [734, 786]),
            (195, [602, 654, 724, 776]),
            (361, [442, 494, 546, 616, 668, 720]),
        ]
        for row in rows {
            for x in row.xs {
                list.append(Shape(kind: .run, x: x, y: row.y, width: 35, height: 45, radius: 9, bar: nil))
            }
        }
        return list
    }()

    /// The tile's side; the mark inside follows the icon's proportions.
    let size: CGFloat

    init(size: CGFloat) {
        self.size = size
    }

    private var scale: CGFloat { size / Self.canvas }

    private var outline: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * Self.cornerFraction, style: .continuous)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The shadow sits on the field alone, so the shapes on it cast none.
            outline
                .fill(ResectaTokens.BrandMark.field)
                .shadow(
                    color: ResectaTokens.BrandMark.shadow,
                    radius: ResectaTokens.Shadow.subtle.radius,
                    x: ResectaTokens.Shadow.subtle.x,
                    y: ResectaTokens.Shadow.subtle.y
                )
            ForEach(Array(Self.shapes.enumerated()), id: \.offset) { _, shape in
                RoundedRectangle(cornerRadius: shape.radius * scale, style: .circular)
                    .fill(Self.color(for: shape))
                    .frame(width: shape.width * scale, height: shape.height * scale)
                    .offset(x: (Self.inkOrigin.x + shape.x) * scale, y: (Self.inkOrigin.y + shape.y) * scale)
            }
            outline
                .strokeBorder(
                    LinearGradient(colors: ResectaTokens.BrandMark.edge, startPoint: .top, endPoint: .bottom),
                    lineWidth: ResectaTokens.Border.subtle
                )
        }
        .frame(width: size, height: size, alignment: .topLeading)
        .accessibilityIgnoresInvertColors()
        .accessibilityHidden(true)
    }

    private static func color(for shape: Shape) -> Color {
        switch shape.kind {
        case .bar: return shape.bar == 2 ? ResectaTokens.BrandMark.teal : ResectaTokens.BrandMark.ink
        case .run: return ResectaTokens.BrandMark.runs
        }
    }
}
