import CoreGraphics
import RedactionEngine

extension RunRecord.PageGeometry {
    /// An unturned Letter page: the geometry a test's bare overlay is given
    /// before it maps a rectangle or begins a touch.
    static let testUnturned = RunRecord.PageGeometry(cropBox: CGRect(x: 0, y: 0, width: 612, height: 792), rotation: 0)
}
