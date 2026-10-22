import SwiftUI

/// The app icon's redaction-bars mark, drawn from shapes on the icon's own
/// unit grid (821 × 434): two label-colour bars, one teal bar and twelve
/// grey text runs. The frame is the ink box — bar 1 starts at unit 0 and the
/// last run ends at unit 821, the top bar starts at 0 and the third bar ends
/// at 434 — so centring the frame centres the whole drawing. Decorative:
/// hidden from accessibility. Home, the first-launch gate and the
/// app-switcher overlay draw it.
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

    /// The icon's unit grid.
    static let gridWidth: CGFloat = 821
    static let gridHeight: CGFloat = 434

    /// The fifteen shapes: three bars (height 102, radius 22) and twelve
    /// runs (35 × 44, radius 8).
    static let shapes: [Shape] = {
        var list: [Shape] = [
            Shape(kind: .bar, x: 0, y: 0, width: 703, height: 102, radius: 22, bar: 0),
            Shape(kind: .bar, x: 0, y: 166, width: 571, height: 102, radius: 22, bar: 1),
            Shape(kind: .bar, x: 0, y: 332, width: 411, height: 102, radius: 22, bar: 2),
        ]
        let rows: [(y: CGFloat, xs: [CGFloat])] = [
            (29, [734, 786]),
            (195, [602, 654, 724, 776]),
            (361, [442, 494, 546, 616, 668, 720]),
        ]
        for row in rows {
            for x in row.xs {
                list.append(Shape(kind: .run, x: x, y: row.y, width: 35, height: 44, radius: 8, bar: nil))
            }
        }
        return list
    }()

    /// The drawn height; the width follows the grid's ratio.
    let height: CGFloat

    init(height: CGFloat) {
        self.height = height
    }

    /// The drawn width for a height.
    static func width(forHeight height: CGFloat) -> CGFloat {
        height * gridWidth / gridHeight
    }

    private var scale: CGFloat { height / Self.gridHeight }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(Self.shapes.enumerated()), id: \.offset) { _, shape in
                RoundedRectangle(cornerRadius: shape.radius * scale, style: .circular)
                    .fill(Self.color(for: shape))
                    .frame(width: shape.width * scale, height: shape.height * scale)
                    .offset(x: shape.x * scale, y: shape.y * scale)
            }
        }
        .frame(width: Self.width(forHeight: height), height: height, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private static func color(for shape: Shape) -> Color {
        switch shape.kind {
        case .bar: return shape.bar == 2 ? ResectaTokens.BrandMark.teal : .primary
        case .run: return ResectaTokens.BrandMark.runs
        }
    }
}
