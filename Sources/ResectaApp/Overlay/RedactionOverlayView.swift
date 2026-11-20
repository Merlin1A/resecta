import UIKit
import SwiftUI
import PDFKit
import RedactionEngine

// Custom UIView overlay for redaction drawing.
// NOT PKCanvasView (blur bug FB13286723).

/// Custom overlay placed on each visible PDF page by PDFPageOverlayViewProvider.
/// Handles drawing new regions, selecting existing ones, and resizing via handles.
/// Coordinates are stored in normalized PDF space (0–1, bottom-left origin).
class RedactionOverlayView: UIView {

    var pageIndex: Int = 0
    weak var coordinator: PDFViewCoordinator?

    /// When true, dragging on empty space creates new regions.
    /// When false, only selection and resize are active.
    var isDrawingMode: Bool = false

    /// Shape produced when drawing is active. `.rectangle` (default)
    /// keeps the existing rubber-band drag → rectangle commit path.
    enum ShapeTool: Equatable {
        case rectangle
    }
    var activeShapeTool: ShapeTool = .rectangle

    /// When true, a tap on a region toggles its membership in the
    /// selection rather than replacing the selection. iPhone parity for
    /// the iPad Shift+tap path — both routes converge on
    /// `coordinator?.toggleRegionSelection(_:)`.
    var isMultiSelectActive: Bool = false { didSet { setNeedsDisplay() } }  // the handles show only while off

    var regions: [RedactionRegion] = []
    var selectedIDs: Set<UUID> = []
    /// Search highlights for the current page (drawn underneath regions).
    var searchHighlights: [SearchResult] = []
    /// Transient live-preview rects (normalized PDF coords) for the
    /// current page. Drawn even more lightly than `searchHighlights` so the
    /// transition into committed results is visible.
    var livePreviewRects: [CGRect] = []
    /// The id of the search result the result walk
    /// currently focuses (`SearchState.currentResult`). Drawn as ONE
    /// 2-pt brand-tint ring just outside that highlight's rect; the
    /// highlight fills are untouched, no animation.
    var focusedHighlightID: UUID?
    /// Convenience: the single selected ID when exactly one is selected.
    var selectedID: UUID? { selectedIDs.count == 1 ? selectedIDs.first : nil }
    var cachedAccessibilityElements: [UIAccessibilityElement]?

    /// The "canvas touch in flight" flag that
    /// window-level cancelling pans are required to fail against — see
    /// `CanvasTouchClaimGestureRecognizer` and `reconcileWindowPanDeference()`.
    private let canvasTouchClaim = CanvasTouchClaimGestureRecognizer(target: nil, action: nil)

    /// Window pans already carrying the failure requirement (weak: a
    /// sheet's pan goes away with its presentation).
    private let deferredWindowPans = NSHashTable<UIGestureRecognizer>.weakObjects()

    // MARK: - Drawing State

    var dragOrigin: CGPoint?
    /// Read-only outside the overlay so `RectangleDrawGestureTests` can
    /// observe the rubber band mid-gesture.
    var currentDragRect: CGRect?
    var activeResizeHandle: ResizeHandle?

    // MARK: - Lasso Marquee State

    /// Active rect-marquee (overlay-space points) during a lasso drag.
    /// Parallel to `currentDragRect` so the two paths stay orthogonal —
    /// `currentDragRect` drives the new-region rubber-band path; this
    /// drives the multi-select marquee path. Only ever non-nil while
    /// `isMultiSelectActive == true` AND the touch-down hit empty space.
    var marqueeRect: CGRect?
    /// Origin of an in-progress marquee drag. Distinct from `dragOrigin`
    /// so neither path can clobber the other mid-gesture.
    var marqueeOrigin: CGPoint?

    /// True during active touch-drag operations. When true,
    /// configure(with:selectedID:) is a no-op to prevent mid-drag
    /// state reset from updateUIView.
    var isActivelyDragging: Bool = false

    // MARK: - Move State

    /// True when the user is dragging an existing region to a new position.
    var isDraggingExistingRegion: Bool = false
    /// Offset from touch point to the region's overlay-space origin, preserving
    /// the grab point so the region doesn't jump to center on the finger.
    var dragOffset: CGSize = .zero
    /// Normalized rect captured before a move begins, for cancel restoration.
    var preDragNormalizedRect: CGRect?
    /// Normalized rect captured when a resize begins: the drag's anchor and the cancel's restore.
    var preResizeNormalizedRect: CGRect?
    /// Primary touch reference recorded at touchesBegan. Secondary
    /// touches (e.g., a finger landing during a Pencil drag) are ignored
    /// while a gesture is in flight to prevent corruption of
    /// marquee state. Cleared in resetDragState.
    var primaryTouch: UITouch?
    /// True when dragging multiple selected regions as a group.
    var isGroupMoving: Bool = false
    /// Pre-drag normalized rects for all regions in the group move, for cancel restoration.
    var preDragGroupRects: [UUID: CGRect] = [:]
    /// Where the touch went down for a move, a group move or a resize: the
    /// start slop and the grab offset read it.
    var dragStartPoint: CGPoint?
    /// True once the finger has travelled past the start slop (`+Move`).
    var hasPassedStartSlop = false
    /// The member the group move's touch landed on.
    var groupMoveTouchedID: UUID?
    /// The region an Add to Selection touch landed on, toggled on lift.
    var pendingToggleID: UUID?

    // MARK: - Snap State

    /// The snap guides: the targets, the active guides the draw pass
    /// strokes, the haptic and the announcement (`SnapGuideEngine`).
    let snapEngine = SnapGuideEngine()

    // MARK: - Finger Scale

    /// Test override for the zoom scale used by
    /// `fingerScale` — i.e. every finger tolerance in the overlay. The
    /// production path walks the view hierarchy looking for a `PDFView`;
    /// tests synthesise the overlay without a parent and pin the zoom
    /// directly here. Default `nil` so production falls through to
    /// `currentZoomScale()`.
    var snapZoomScaleOverride: CGFloat?

    /// Screen points → overlay units. Finger tolerances
    /// (drag-start gate, commit floor, resize floor, region hit inset,
    /// handle boxes, snap proximity) are specified in
    /// SCREEN points; the overlay's space is the page's unscaled bounds
    /// (PDFKit zooms the container), so a tolerance in overlay units is
    /// the screen tolerance × 1/zoom. Document geometry (page-margin
    /// inset, the dimension label) is deliberately NOT scaled.
    var fingerScale: CGFloat {
        1 / max(snapZoomScaleOverride ?? currentZoomScale(), 0.01)
    }

    // MARK: - Handle Animation State

    /// Current scale of resize handles (0 = hidden, 1 = full size).
    /// Animated via CADisplayLink for smooth 60fps interpolation.
    var handleScale: CGFloat = 0.0
    var handleDisplayLink: CADisplayLink?
    var handleAnimStartTime: CFTimeInterval = 0
    var handleAnimDuration: CFTimeInterval = 0.2
    var handleAnimFromScale: CGFloat = 0.0
    var handleAnimTargetScale: CGFloat = 1.0
    /// Track previous selection to detect transitions.
    var previousSelectedID: UUID?

    /// Minimum drag distance (in points) before creating a region.
    /// Prevents accidental taps from creating tiny regions.
    static let minimumDragThreshold: CGFloat = 8.0
    // The notice when a drawn band falls below the size floor
    // (`RegionSizeFloor`): on screen and spoken. It names the remedy, not
    // the floor, since the floor is in screen points.
    static let subThresholdRejectionAnnouncement =
        "Region too small. Zoom in to draw a smaller region."

    // Polish helpers + adaptive-stroke constants live in
    // the sibling extension file `RedactionOverlayView+CanvasPolish.swift`:
    //   badgeOuterStrokeWidth / selectionHandleOuterStrokeWidth,
    //   dimensionLabelSmallRegionThreshold,
    //   DimensionLabelPosition + dimensionLabelPosition(…),
    //   clampedDragOrigin(…).

    // Predicate for the region tap that toggles on lift through
    // `coordinator?.toggleRegionSelection`. Returns true when either
    // the iPad Shift modifier is held OR the iPhone "Select More" toolbar
    // toggle is on; otherwise the tap follows the replace-selection path.
    // Pure predicate so the OR shape is pinned without a UITouch host.
    static func shouldToggleSelection(
        isMultiSelectActive: Bool,
        shiftHeld: Bool
    ) -> Bool {
        isMultiSelectActive || shiftHeld
    }

    // Label for the add-to-selection toolbar toggle (historically
    // "Select More"). Verb-object form names what a tap does
    // while the toggle is on. When at least one region is selected, the
    // count surfaces in the label so the user can see the selection size
    // without opening a separate count badge.
    static let selectMoreToggleTitle = "Add to Selection"

    // Pure helper resolving a normalized rect-marquee against a
    // set of regions. Returns the subset whose `normalizedRect` intersects
    // the marquee. `CGRect.intersects` is non-strict — an edge touch
    // counts as a hit, matching the user's "the region was under the
    // box" mental model. Order is preserved from the input array so a
    // caller cap (e.g. `RedactionState.lassoSelectionCap`) truncates
    // deterministically on the *first* N regions by their stored order.
    // Pure so `LassoMultiSelectTests` can pin the intersection contract
    // without a UITouch host or a PDF document.
    static func regionsIntersecting(
        marqueeNormalized: CGRect,
        regions: [RedactionRegion]
    ) -> [RedactionRegion] {
        guard !marqueeNormalized.isNull, !marqueeNormalized.isEmpty else {
            return []
        }
        return regions.filter { $0.normalizedRect.intersects(marqueeNormalized) }
    }

    // Resize handle that models the finger's corner while a new rectangle
    // is being drawn: the drag origin is the anchored
    // corner, so only the two edges under the finger move — and snap —
    // through `SnapGuideEngine.applyResizeSnapping`. Ties (dx == 0 / dy == 0) fall to the
    // bottom/right side, matching the rect the drag produces. Pure so
    // `RectangleDrawGestureTests` can pin the quadrant table without a
    // UITouch host.
    static func drawSnapHandle(origin: CGPoint, point: CGPoint) -> ResizeHandle {
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        switch (dx >= 0, dy >= 0) {
        case (true, true): return .bottomRight
        case (true, false): return .topRight
        case (false, true): return .bottomLeft
        case (false, false): return .topLeft
        }
    }

    /// Prepared haptic generator for sub-threshold rejection feedback.
    lazy var rejectionFeedback: UIImpactFeedbackGenerator = {
        let gen = UIImpactFeedbackGenerator(style: .soft)
        gen.prepare()
        return gen
    }()

    /// Haptic for move commit ("stamp placed" metaphor).
    lazy var moveCommitFeedback: UIImpactFeedbackGenerator = {
        let gen = UIImpactFeedbackGenerator(style: .medium)
        gen.prepare()
        return gen
    }()

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear

        // Hover gesture for iPad pointer — updates hoveredRegionID
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hover)

        // The canvas claim — installed once; the failure
        // requirements against window pans are wired per window in
        // `reconcileWindowPanDeference()`.
        addGestureRecognizer(canvasTouchClaim)

        // Context menu for region info + delete
        let contextMenu = UIContextMenuInteraction(delegate: self)
        addInteraction(contextMenu)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Hit Testing (tool-based routing)

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Pass through to PDFView for pan/zoom unless the overlay owns the
        // point (`claimsTouch(at:)`); a touch it claims never scrolls.
        let claimed = claimsTouch(at: point)
        coordinator?.setCanvasHoldsTouch(claimed)
        guard claimed else { return nil }
        // Hit-testing runs at touch-down, before
        // the gesture environment dispatches the touch, so this is the
        // timing-proof seam to wire the failure requirement against a
        // window pan that arrived with a sheet since the last canvas
        // touch. Idempotent; a walk of the window's ~10 recognizers.
        reconcileWindowPanDeference()
        return super.hitTest(point, with: event)
    }

    /// Tool-based routing: the points this overlay owns.
    private func claimsTouch(at point: CGPoint) -> Bool {
        // Always intercept if drawing mode is on
        if isDrawingMode { return true }
        // When multi-select is active, intercept empty-space touches
        // so the marquee can capture them. Without this, empty-space touches
        // would pass through to PDFView for pan and the lasso would never
        // begin. The marquee path is gated again inside `touchesBegan` on
        // `isMultiSelectActive && empty touch-down`, so this hit-test gate
        // only widens the routing — it does not commit a marquee on its own.
        if isMultiSelectActive { return true }
        // Without drawing mode, intercept touches on a handle or a region.
        return hitTarget(at: point, handles: true) != nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reconcileWindowPanDeference()
        observeDifferentiateWithoutColor()
    }

    // MARK: - Window-pan deference

    /// Every window-level pan that would cancel this view's touches must
    /// fail before it may recognize while a canvas touch is in flight —
    /// iOS 26's sheet "exterior pan" is the one that exists today. Beneath
    /// the compact float it recognized on the first moves of a drag and
    /// cancelled the touches PDFKit's scroll view was still holding, so
    /// no draw / move / resize ever reached `touchesBegan` (taps did).
    /// The requirement is set once per recognizer; the table is weak, so a
    /// pan that leaves with its sheet drops out and a later presentation's
    /// pan is picked up on the next canvas touch (`hitTest`).
    func reconcileWindowPanDeference() {
        guard let window else { return }
        for recognizer in window.gestureRecognizers ?? [] {
            guard Self.windowPanShouldDeferToCanvas(recognizer),
                  !deferredWindowPans.contains(recognizer)
            else { continue }
            recognizer.require(toFail: canvasTouchClaim)
            deferredWindowPans.add(recognizer)
        }
    }

    /// Pure predicate: a `UIPanGestureRecognizer` attached to a `UIWindow`
    /// with `cancelsTouchesInView`. Name-agnostic on purpose — the iOS 26
    /// flex-interaction pans carry `cancelsTouchesInView == false` and are
    /// left alone, as is every recognizer on an ordinary view (PDFKit's
    /// scroll pan, the sheet's own grabber pan on its drop-shadow view).
    static func windowPanShouldDeferToCanvas(_ recognizer: UIGestureRecognizer) -> Bool {
        recognizer is UIPanGestureRecognizer
            && recognizer.cancelsTouchesInView
            && recognizer.view is UIWindow
    }

    /// Window pans currently carrying the requirement (test hook).
    var deferredWindowPanCount: Int { deferredWindowPans.count }
}
