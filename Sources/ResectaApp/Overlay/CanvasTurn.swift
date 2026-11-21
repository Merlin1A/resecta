import CoreGraphics

/// The turn between the two frames a box can be described in on a page
/// stored with `/Rotate`. Both are normalized 0–1 with a bottom-left
/// origin over the crop box:
///
/// - the STORED frame: the page before its rotation. PDFKit sizes a page's
///   overlay view to the stored page and turns the view with the page, so
///   the overlay's bounds, and a rect normalized over them, are in this
///   frame;
/// - the SHOWN frame: the page after its rotation, as it is displayed. A
///   stored region (`RedactionRegion.normalizedRect`) lives here, as the
///   search places it, the burn paints it and the checks read it.
///
/// `shown(fromStored:rotation:)` is the search's own transform
/// (`ConcealingAnnotations.displayNormalized`) on normalized rects;
/// `stored(fromShown:rotation:)` is its exact inverse. Unrotated, both are
/// the identity.
nonisolated enum CanvasTurn {

    /// `/Rotate` normalized to 0 · 90 · 180 · 270.
    static func quarterTurns(_ rotation: Int) -> Int {
        ((rotation % 360) + 360) % 360
    }

    /// A stored-frame rect in the shown frame.
    static func shown(fromStored s: CGRect, rotation: Int) -> CGRect {
        switch quarterTurns(rotation) {
        case 90:  return CGRect(x: s.minY, y: 1 - s.maxX, width: s.height, height: s.width)
        case 180: return CGRect(x: 1 - s.maxX, y: 1 - s.maxY, width: s.width, height: s.height)
        case 270: return CGRect(x: 1 - s.maxY, y: s.minX, width: s.height, height: s.width)
        default:  return s
        }
    }

    /// A shown-frame rect in the stored frame.
    static func stored(fromShown d: CGRect, rotation: Int) -> CGRect {
        switch quarterTurns(rotation) {
        case 90:  return CGRect(x: 1 - d.maxY, y: d.minX, width: d.height, height: d.width)
        case 180: return CGRect(x: 1 - d.maxX, y: 1 - d.maxY, width: d.width, height: d.height)
        case 270: return CGRect(x: d.minY, y: 1 - d.maxX, width: d.height, height: d.width)
        default:  return d
        }
    }
}
