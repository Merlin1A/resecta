import CoreGraphics

extension BoxPicture {
    /// What the walk and the selection bar keep in view, as a share of the
    /// page: the fill's share joined with the line's. The fill is the fill
    /// read's share, else the plan box's paint, else the region's own share;
    /// the line is the start's share for a box selected alone that has a
    /// start, else the region's own share.
    nonisolated static func keepInViewShare(own: CGRect, fill: CGRect?, paint: CGRect?,
                                            start: CGRect?, selectedAlone: Bool) -> CGRect {
        let line = selectedAlone ? (start ?? own) : own
        return (fill ?? paint ?? own).union(line)
    }

    /// The Search walk's frame for its current result, as a share of the page:
    /// the whole page for a result with no rectangle; the box's kept-in-view
    /// share when the result is applied or covered and has one; else the
    /// result's own rectangle.
    nonisolated static func walkFrame(resultRect: CGRect?, applied: Bool, keepInView: CGRect?) -> CGRect {
        guard let resultRect else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        if applied, let keepInView { return keepInView }
        return resultRect
    }
}
