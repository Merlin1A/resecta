import Foundation

/// The middle of a character's box: the part of the box in which every
/// letter and digit has stroke. Across the line it is the band the ink test
/// reads to decide whether a letter shows ink, 35 % to 65 % of the box
/// (`InkContrastFloor.glyphCore`); along the line it is the central half,
/// 25 % to 75 %. A rectangle that shares area with no letter's middle leaves
/// a stroke of every letter and digit showing.
///
/// The core imports Foundation alone, which on Darwin gives a rectangle its
/// origin and size but none of CoreGraphics' members on it, so this reads
/// only `origin` and `size` and does its own arithmetic.
public enum LetterBoxMiddle {

    /// Share of the box's extent along the line taken off each end.
    static let alongInset: CGFloat = 0.25

    /// Share of the box's extent across the line taken off top and bottom.
    static let acrossInset: CGFloat = 0.35

    /// The middle of `box`, a character's box in the frame the page is shown
    /// in, on a page stored with `rotation` degrees. On a page turned a
    /// quarter the line runs along the frame's height, so the two insets
    /// follow the line and not the frame's sides, as the ink test's band
    /// does. A box with a negative width or height is put right first (it
    /// starts that far before its origin). A box with no width or no height
    /// has no middle: nil, which a caller reads as sharing area with nothing.
    public static func middle(of box: CGRect, rotation: Int) -> CGRect? {
        var x = box.origin.x, width = box.size.width
        var y = box.origin.y, height = box.size.height
        if width < 0 { x += width; width = -width }
        if height < 0 { y += height; height = -height }
        guard width > 0, height > 0 else { return nil }
        let lineRunsAlongX = (((rotation % 360) + 360) % 360) % 180 == 0
        let dx = (lineRunsAlongX ? alongInset : acrossInset) * width
        let dy = (lineRunsAlongX ? acrossInset : alongInset) * height
        return CGRect(origin: CGPoint(x: x + dx, y: y + dy),
                      size: CGSize(width: width - 2 * dx, height: height - 2 * dy))
    }
}
