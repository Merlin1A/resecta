import Foundation
import CoreGraphics

// Where the selection bar sits, so it never covers the selection it acts
// on. The bar's place is the bottom of the canvas; when the selected boxes,
// with the reach of their handles, come within 8 pt of it, the bar is drawn
// at the top of the canvas instead, unless the selection is near that place
// too. The page never moves for it. Pure and host-free: the coordinator
// reads the boxes from the page in view and hands the place to the editor,
// which draws it.

enum SelectionBarClearance {

    /// Space kept between the selection and the bar, and between the top
    /// place and the canvas's top.
    static let gap: CGFloat = ResectaTokens.Spacing.sm

    /// How far a handle's touch area reaches past its box: half the
    /// 46-pt touch target, which is centred on the box's corner or edge.
    static let handleReach: CGFloat = ResectaTokens.TouchTarget.minimum / 2

    /// Two rectangles meet when they share a point inside both; rectangles
    /// whose edges only touch do not meet.
    static func meets(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY
    }

    /// The selection the bar keeps clear of: the selected boxes together,
    /// grown on every side by the handles' reach and cut to the page's
    /// frame. nil without a box, or when nothing of it lies on the page.
    static func selectionRect(boxes: [CGRect], page: CGRect) -> CGRect? {
        guard let first = boxes.first else { return nil }
        let union = boxes.dropFirst().reduce(first) { $0.union($1) }
        let cut = union.insetBy(dx: -handleReach, dy: -handleReach).intersection(page)
        return cut.isNull || cut.isEmpty ? nil : cut
    }

    /// The bar's top place: its bottom place moved up until its top is
    /// `gap` under the canvas's top.
    static func topPlace(of bottomBar: CGRect, canvas: CGRect) -> CGRect {
        CGRect(x: bottomBar.minX, y: canvas.minY + gap, width: bottomBar.width, height: bottomBar.height)
    }

    /// Whether the bar takes its top place: the selection meets the bottom
    /// place grown by `gap` and does not meet the top place grown by `gap`.
    /// A selection near both keeps the bar at the bottom.
    static func barAtTop(selection: CGRect?, bottomBar: CGRect, canvas: CGRect) -> Bool {
        guard let selection else { return false }
        let bottom = bottomBar.insetBy(dx: -gap, dy: -gap)
        let top = topPlace(of: bottomBar, canvas: canvas).insetBy(dx: -gap, dy: -gap)
        return meets(selection, bottom) && !meets(selection, top)
    }

    /// Whether the bar is drawn at the top: only while the bar holds the
    /// slot, its place is the top, and no notice shows in the top band.
    static func drawnAtTop(barUp: Bool, placeIsTop: Bool, topNoticeShowing: Bool) -> Bool {
        barUp && placeIsTop && !topNoticeShowing
    }

    /// What the place is decided from. The page's zoom and scroll position
    /// are not among them: a person who scrolls a box under the bar moves
    /// nothing.
    struct Inputs: Equatable {
        var selectedIDs: Set<UUID>
        var regionVersion: Int
        var bar: CGRect?
        var canvasSize: CGSize
        var pageIndex: Int
    }

    enum Step: Equatable {
        /// Nothing to decide.
        case none
        /// Decide the place now.
        case run
        /// Decide it when the finger lifts.
        case wait
        /// Leave the place as it is.
        case drop
    }

    /// When the place is decided: once per change of its inputs while the
    /// bar is up; never while the person scrolls or zooms, nor in an update
    /// in which a Search step framed the page; while a finger holds a box or
    /// a handle, when the finger lifts.
    static func step(inputsChanged: Bool, barUp: Bool, fingerDown: Bool,
                     personScrolling: Bool, framedThisPass: Bool) -> Step {
        guard inputsChanged, barUp else { return .none }
        if framedThisPass || personScrolling { return .drop }
        if fingerDown { return .wait }
        return .run
    }
}
