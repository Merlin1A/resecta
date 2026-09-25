import CoreGraphics
import Foundation

/// The map between a page's DISPLAYED frame and its SOURCE frame.
///
/// A page stored with `/Rotate r` is displayed rotated r° clockwise (ISO
/// 32000, clause 8.3.2). From extraction onward the engine works in the
/// displayed frame (`TextLayerExtractor` applies `T_rot` per glyph; the
/// rasterizer's region basis is the displayed page), but a text LINE runs
/// along the source axes: on a 90°/270° page every source line is a vertical
/// run in the displayed frame, and on a 180° page each line is mirrored. The
/// text-layer reconstructor assembles its lines in the source frame and draws
/// them back under the rotation; the writer-side drawn-cell rule and the
/// Layer 9 lineage walk work in the source frame on both sides. This value
/// carries the two maps.
///
/// `displayedSize` is the displayed page size — `effectiveSize` in the
/// rasterizer, the output page's crop box in the verifier. `sourceSize` is
/// the source crop size (the `(w, h)` PRE-swap `rotateRectIntoOutputSpace`
/// reads): the displayed size with its axes swapped at 90°/270°. On an
/// unrotated page every map is the identity and only `displayedSize.width`
/// is read (the assembled-line fit clamp).
struct PageFrame: Sendable, Equatable {
    /// The page's `/Rotate`, normalized to 0 · 90 · 180 · 270.
    let rotation: Int
    let displayedSize: CGSize

    init(rotation: Int, displayedSize: CGSize) {
        self.rotation = ((rotation % 360) + 360) % 360
        self.displayedSize = displayedSize
    }

    /// An unrotated page of the given width; the height is never read.
    static func unrotated(width: CGFloat) -> PageFrame {
        PageFrame(rotation: 0, displayedSize: CGSize(width: width, height: 0))
    }

    var isUnrotated: Bool { rotation == 0 }

    /// The source (pre-rotation) crop size.
    var sourceSize: CGSize {
        rotation == 90 || rotation == 270
            ? CGSize(width: displayedSize.height, height: displayedSize.width)
            : displayedSize
    }

    /// `T_rot`: a source-frame (cropBox-local) rect in the displayed frame.
    func displayedRect(_ source: CGRect) -> CGRect {
        TextLayerExtractor.rotateRectIntoOutputSpace(
            source, sourceCropSize: sourceSize, rotation: rotation)
    }

    /// `T_rot⁻¹`: a displayed-frame rect in the source frame.
    func sourceRect(_ displayed: CGRect) -> CGRect {
        TextLayerExtractor.unrotateRectIntoSourceSpace(
            displayed, sourceCropSize: sourceSize, rotation: rotation)
    }

    func displayedPoint(_ source: CGPoint) -> CGPoint {
        TextLayerExtractor.rotatePointIntoOutputSpace(
            source, sourceCropSize: sourceSize, rotation: rotation)
    }

    func sourcePoint(_ displayed: CGPoint) -> CGPoint {
        TextLayerExtractor.unrotatePointIntoSourceSpace(
            displayed, sourceCropSize: sourceSize, rotation: rotation)
    }

    /// The angle of the rotation that carries a source-frame direction onto
    /// its displayed direction: `displayedPoint(p) − displayedPoint(.zero)`
    /// is `p` rotated by this angle. A line drawn along +X in a graphics
    /// state translated to `displayedPoint(origin)` and rotated by this
    /// angle runs along its source line on the displayed page.
    var displayedAngle: CGFloat {
        switch rotation {
        case 90: return -.pi / 2
        case 180: return .pi
        case 270: return .pi / 2
        default: return 0
        }
    }

    /// A character entry with its bounds carried into the source frame.
    func sourceEntry(_ entry: CharacterInfo) -> CharacterInfo {
        CharacterInfo(
            character: entry.character, bounds: sourceRect(entry.bounds),
            stringIndex: entry.stringIndex, lineIndex: entry.lineIndex)
    }

    /// A region shape with its rects and polygon carried into the source
    /// frame (a rigid map: the expanded halo stays the halo).
    func sourceShape(_ shape: RegionShape) -> RegionShape {
        RegionShape(
            expandedBounds: sourceRect(shape.expandedBounds),
            polygonVertices: shape.polygonVertices?.map(sourcePoint),
            bounds: sourceRect(shape.bounds))
    }
}
