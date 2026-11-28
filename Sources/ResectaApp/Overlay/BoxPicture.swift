import CoreGraphics

/// One box as it is shown and touched on the overlay: every rectangle the
/// drawing, the hit test, VoiceOver and the walks need, made by one pure
/// function from plain values. Overlay points, origin top-left, y down;
/// sizes meant on screen are multiplied by `fingerScale` (1 / zoom).
///
/// `make` calls the overlay's own handle and corner-dot centres and reads
/// the canvas tokens. The halo, the handle boxes, the body zone, the cores
/// and the tag's place are restated here from the code that applies them
/// today, and the case table pins each.
nonisolated struct BoxPicture: Equatable {
    nonisolated enum Selection: Equatable, Sendable {
        case rest, single, oneOfSeveral, addToSelection, moving
    }

    nonisolated struct Input: Equatable {
        /// The region's stored rectangle, overlay points.
        var own: CGRect
        /// The box's fill, overlay points: the union of the fill read's shares
        /// through the draw map; nil when the read gives none.
        var fill: CGRect?
        /// The veil's rectangles as shares of the page as displayed, unsnapped.
        var veilShares: [CGRect]
        /// The plan box's paint, overlay points; nil means `own`.
        var paint: CGRect?
        /// Where a first edit of this box would start, overlay points, when one applies.
        var start: CGRect?
        /// The region's source is a hand-drawn box.
        var drawnByHand: Bool
        /// The tag's words, nil for none.
        var tagWord: String?
        /// The tag's words' width in screen points.
        var tagTextWidth: CGFloat?
        var selection: Selection
        var settings: CanvasDisplaySettings
        /// Overlay points per screen point (1 / zoom).
        var fingerScale: CGFloat
        /// The overlay's page size, overlay points.
        var page: CGSize
    }

    nonisolated struct Handle: Equatable, Sendable {
        var handle: RedactionOverlayView.ResizeHandle
        var point: CGPoint
    }

    nonisolated struct HandleBox: Equatable, Sendable {
        var handle: RedactionOverlayView.ResizeHandle
        var box: CGRect
    }

    nonisolated struct Lift: Equatable, Sendable {
        var line: CGRect
        var fill: CGRect
    }

    /// What is filled: the fill, else the paint, else the stored rectangle.
    var fill: CGRect
    /// The veil's shares, as handed.
    var veilShares: [CGRect]
    /// The line's rectangle: the start for a box selected alone that has one,
    /// else the stored rectangle.
    var lineRect: CGRect
    /// The line's width in screen points, and in overlay points.
    var lineWidthScreen: CGFloat
    var lineWidth: CGFloat
    /// The resize handles (a box selected alone).
    var handleCentres: [Handle]
    /// The corner dots (a box selected among others, or with Add to Selection on).
    var dotCentres: [CGPoint]
    /// The tag, at rest only; nil where it is not drawn.
    var tagRect: CGRect?
    /// What a touch on the box claims: the line's rectangle grown by the halo.
    var hitBody: CGRect
    /// Each handle's touch box, slid inside the page.
    var handleBoxes: [HandleBox]
    /// The part of the box a touch moves rather than resizes; nil without handles.
    var bodyZone: CGRect?
    /// The square round each handle centre where the handle always wins.
    var cores: [HandleBox]
    /// The box being moved, at its own size; nil otherwise.
    var lift: Lift?
    /// VoiceOver's frame: the fill joined with the line.
    var accessibilityFrame: CGRect
    /// What the walks and the selection bar keep in view: the fill joined with the line.
    var keepInView: CGRect
    /// The ink line beside the line is drawn (Increase Contrast).
    var showsInkLine: Bool
    /// The Differentiate Without Color cue is drawn (where corner dots are).
    var showsCue: Bool

    /// The touch halo round a box, in screen points.
    static let halo: CGFloat = 8
    /// The smallest handle touch box, in screen points.
    static let handleBoxFloor: CGFloat = 22
    /// The most of a side the handle boxes reach in from it.
    static let bodyReachCap: CGFloat = 0.25
    /// The side of the square round a handle centre where the handle wins, in screen points.
    static let core: CGFloat = 22
    /// The tag: height, padding each side of its words, its foot's gap above
    /// the line, how far its leading edge sits outside the line's, and the
    /// shortest line it is drawn on; all in screen points.
    static let tagHeight: CGFloat = 15
    static let tagPadding: CGFloat = 5
    static let tagGap: CGFloat = 1.5
    static let tagLeadOut: CGFloat = 0.7
    static let tagShortestLine: CGFloat = 15

    static func make(_ input: Input) -> BoxPicture {
        typealias C = ResectaTokens.Canvas
        let f = input.fingerScale
        let selected = input.selection != .rest
        let fill = input.fill ?? input.paint ?? input.own
        let lineRect = input.selection == .single ? (input.start ?? input.own) : input.own
        let lineWidthScreen = selected ? C.lineSelected.width : C.line.width

        let centres: [Handle] = input.selection == .single
            ? RedactionOverlayView.handleCentres(for: lineRect, fingerScale: f).map { Handle(handle: $0.0, point: $0.1) }
            : []
        let dots: [CGPoint] = input.selection == .oneOfSeveral || input.selection == .addToSelection
            ? RedactionOverlayView.selectionDotCentres(for: lineRect, fingerScale: f)
            : []

        let page = CGRect(origin: .zero, size: input.page)
        let boxSide = min(ResectaTokens.TouchTarget.minimum * f,
                          max(handleBoxFloor * f, min(lineRect.width, lineRect.height) / 2))
        func handleBox(at centre: CGPoint) -> CGRect {
            var box = CGRect(x: centre.x - boxSide / 2, y: centre.y - boxSide / 2, width: boxSide, height: boxSide)
            box.origin.x = max(page.minX, min(box.origin.x, page.maxX - boxSide))
            box.origin.y = max(page.minY, min(box.origin.y, page.maxY - boxSide))
            return box
        }
        let handleBoxes = centres.map { HandleBox(handle: $0.handle, box: handleBox(at: $0.point)) }

        var bodyZone: CGRect?
        if !centres.isEmpty {
            let r = lineRect
            let left = min(handleBox(at: CGPoint(x: r.minX, y: r.midY)).maxX - r.minX, r.width * bodyReachCap)
            let right = min(r.maxX - handleBox(at: CGPoint(x: r.maxX, y: r.midY)).minX, r.width * bodyReachCap)
            let top = min(handleBox(at: CGPoint(x: r.midX, y: r.minY)).maxY - r.minY, r.height * bodyReachCap)
            let bottom = min(r.maxY - handleBox(at: CGPoint(x: r.midX, y: r.maxY)).minY, r.height * bodyReachCap)
            bodyZone = CGRect(x: r.minX + left, y: r.minY + top,
                              width: r.width - left - right, height: r.height - top - bottom)
        }

        let coreSide = core * f
        let cores = centres.map {
            HandleBox(handle: $0.handle, box: CGRect(x: $0.point.x - coreSide / 2, y: $0.point.y - coreSide / 2,
                                                     width: coreSide, height: coreSide))
        }

        // fill ∪ lineRect, taken as the larger rectangle itself when one
        // holds the other: CGRect.union works the width out as maxX - minX,
        // which can differ from a hand box's own width in the last bit.
        let shown = lineRect.contains(fill) ? lineRect : fill.contains(lineRect) ? fill : fill.union(lineRect)
        return BoxPicture(
            fill: fill,
            veilShares: input.veilShares,
            lineRect: lineRect,
            lineWidthScreen: lineWidthScreen,
            lineWidth: lineWidthScreen * f,
            handleCentres: centres,
            dotCentres: dots,
            tagRect: input.selection == .rest ? tagRect(on: lineRect, input: input) : nil,
            hitBody: lineRect.insetBy(dx: -halo * f, dy: -halo * f),
            handleBoxes: handleBoxes,
            bodyZone: bodyZone,
            cores: cores,
            lift: input.selection == .moving ? Lift(line: lineRect, fill: fill) : nil,
            accessibilityFrame: shown,
            keepInView: shown,
            showsInkLine: C.showsInkLine(increaseContrast: input.settings.increaseContrast),
            showsCue: input.settings.differentiateWithoutColor && !dots.isEmpty)
    }

    /// The tag of a box at rest: not on a hand-drawn box, only with words, on a
    /// line at least `tagShortestLine` tall and as wide as the tag on screen.
    /// Its foot sits `tagGap` above the line's top and its leading edge
    /// `tagLeadOut` outside the line's; below the line if above would cross
    /// the page's top; none if neither fits on the page.
    private static func tagRect(on line: CGRect, input: Input) -> CGRect? {
        guard !input.drawnByHand, let word = input.tagWord, !word.isEmpty,
              let words = input.tagTextWidth else { return nil }
        let f = input.fingerScale
        let widthOnScreen = words + 2 * tagPadding
        guard line.height / f >= tagShortestLine, line.width / f >= widthOnScreen else { return nil }
        let x = line.minX - tagLeadOut * f, width = widthOnScreen * f, height = tagHeight * f
        let above = CGRect(x: x, y: line.minY - (tagGap + tagHeight) * f, width: width, height: height)
        if above.minY >= 0 { return above }
        let below = CGRect(x: x, y: line.maxY + tagGap * f, width: width, height: height)
        return below.maxY <= input.page.height ? below : nil
    }
}
