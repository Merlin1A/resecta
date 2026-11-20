/// Admission: whether a region drawn on a page reaches a run. Its rectangle,
/// cut to the page on all four sides (the part of it that lies on the page),
/// is admitted when that part is more than one thousandth of the page wide and
/// more than one thousandth high. This is the one admission rule: the engine's
/// `RedactionRegion.admission(normalizedRect:)` asks it, and the page builder,
/// the run's record, the Layer-2 check and the editor's "anything to redact"
/// all read that. A region it refuses is never painted, and the record lists it
/// with its reason (`RunRecord.Page.refusedRegions`).
public enum RegionAdmission {
    /// The share of the page the cut rectangle must exceed, on each side.
    package static let floor = 0.001

    /// Why a region does not reach the run.
    public enum Refusal: Equatable, Sendable {
        /// The region and the page share no area, and the region itself is
        /// not too thin to paint.
        case offThePage
        /// The region's part on the page is at most one thousandth of the page
        /// wide or high. A region of no area is too thin.
        case tooThinToPaint
    }

    /// The answer for a rectangle given as shares of the page (0 to 1, any
    /// edge may lie off the page): nil when admitted, else the reason.
    package static func refusal(minX: Double, minY: Double, maxX: Double, maxY: Double) -> Refusal? {
        let width = maxX - minX, height = maxY - minY
        // NaN fails every comparison below: such a rectangle is too thin.
        guard width > floor, height > floor else { return .tooThinToPaint }
        let cutWidth = min(maxX, 1) - max(minX, 0), cutHeight = min(maxY, 1) - max(minY, 0)
        if cutWidth <= 0 || cutHeight <= 0 { return .offThePage }
        return cutWidth > floor && cutHeight > floor ? nil : .tooThinToPaint
    }
}
