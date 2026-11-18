/// Admission: whether a region drawn on a page reaches a run. Its rectangle,
/// clamped to the page, is admitted when it is more than one thousandth of the
/// page wide and more than one thousandth high. This is the one admission
/// floor: the engine's `RedactionRegion.isAdmitted(normalizedRect:)` clamps
/// and asks it, and the page builder and the run's record both read that.
package enum RegionAdmission {
    /// The share of the page a clamped rectangle must exceed, on each side.
    package static let floor = 0.001

    /// Whether a rectangle already clamped to the page, its width and height
    /// given as shares of the page, is admitted.
    package static func admits(clampedWidth: Double, clampedHeight: Double) -> Bool {
        clampedWidth > floor && clampedHeight > floor
    }
}
