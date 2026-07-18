import UIKit
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
    /// `.polygon` builds a vertex list on each tap; double-tap closes the
    /// loop and commits. `.freeform` accumulates touch points during a
    /// continuous drag and on touch-up runs Douglas-Peucker simplification
    /// to ≤ 32 vertices (tolerance 2 pt × 1/zoomScale).
    enum ShapeTool: Equatable {
        case rectangle
        case polygon
        case freeform
    }
    var activeShapeTool: ShapeTool = .rectangle

    /// When true, a tap on a region toggles its membership in the
    /// selection rather than replacing the selection. iPhone parity for
    /// the iPad Shift+tap path — both routes converge on
    /// `coordinator?.toggleRegionSelection(_:)`.
    var isMultiSelectActive: Bool = false

    private var regions: [RedactionRegion] = []
    private var selectedIDs: Set<UUID> = []
    /// Search highlights for the current page (drawn underneath regions).
    private var searchHighlights: [SearchResult] = []
    /// Transient live-preview rects (normalized PDF coords) for the
    /// current page. Drawn even more lightly than `searchHighlights` so the
    /// transition into committed results is visible.
    private var livePreviewRects: [CGRect] = []
    /// Convenience: the single selected ID when exactly one is selected.
    private var selectedID: UUID? { selectedIDs.count == 1 ? selectedIDs.first : nil }
    private var cachedAccessibilityElements: [UIAccessibilityElement]?

    // MARK: - Drawing State

    private var dragOrigin: CGPoint?
    private var currentDragRect: CGRect?
    private var activeResizeHandle: ResizeHandle?

    // MARK: - Lasso Marquee State

    /// Active rect-marquee (overlay-space points) during a lasso drag.
    /// Parallel to `currentDragRect` so the two paths stay orthogonal —
    /// `currentDragRect` drives the new-region rubber-band path; this
    /// drives the multi-select marquee path. Only ever non-nil while
    /// `isMultiSelectActive == true` AND the touch-down hit empty space.
    private var marqueeRect: CGRect?
    /// Origin of an in-progress marquee drag. Distinct from `dragOrigin`
    /// so neither path can clobber the other mid-gesture.
    private var marqueeOrigin: CGPoint?

    /// True during active touch-drag operations. When true,
    /// configure(with:selectedID:) is a no-op to prevent mid-drag
    /// state reset from updateUIView.
    private(set) var isActivelyDragging: Bool = false

    // MARK: - Polygon / Freeform Drawing State

    /// Vertices accumulated for the in-progress
    /// polygon, in overlay-space points. Each tap appends; a tap inside
    /// `polygonCloseRadius` of `polygonVertices[0]` once `count >= 3`
    /// closes the loop and commits via `commitPolygonRegion`. Cleared on
    /// commit, `discardInProgressPolygon`, and `removeFromSuperview`.
    private var polygonVertices: [CGPoint] = []

    /// Overlay-space radius around `polygonVertices[0]`
    /// that closes the polygon when tapped (count >= 3). 18 pt sits
    /// between the 22 pt resize-handle hit area and the 8 pt vertex dot
    /// — large enough to be a comfortable tap target without overlapping
    /// a neighbouring vertex on a tight polygon.
    static let polygonCloseRadius: CGFloat = 18.0
    /// Diameter of the stroked close-target ring drawn
    /// around the first vertex once `polygonVertices.count >= 3`. 16 pt
    /// is 2× the standard vertex dot, making the close target visibly
    /// distinct from a mid-polygon vertex.
    static let firstVertexRingDiameter: CGFloat = 16.0
    /// Baseline dedup tolerance for polygon taps near
    /// the previous vertex, in overlay-space points at 1× zoom. Active
    /// tolerance is `baseline / zoomScale` (same scaling rule as
    /// `freeformDouglasPeuckerToleranceAtUnitZoom`). 2 pt matches the
    /// freeform baseline so the rejected-near-duplicate band is the
    /// same magnitude both routes use.
    static let polygonVertexDeduplicationDistance: CGFloat = 2.0

    /// Live touch path for the freeform tool, in overlay-space
    /// points. Accumulated in `touchesMoved`; simplified via
    /// Douglas-Peucker in `touchesEnded` before commit.
    private var freeformPath: [CGPoint] = []
    /// Zoom scale captured at the start of a freeform drag — used
    /// to scale Douglas-Peucker tolerance by `1/zoomScale`. Defaults to
    /// 1.0 when no enclosing PDFView exists in the view hierarchy.
    private var freeformZoomScale: CGFloat = 1.0
    /// Tolerance baseline at zoom 1×. Multiplied by `1/zoomScale`
    /// to produce the active tolerance — so a finger drift at 2× zoom is
    /// treated as half a point of real geometry. Locked at 2 pt; do not
    /// tune.
    static let freeformDouglasPeuckerToleranceAtUnitZoom: CGFloat = 2.0
    /// Hard cap on simplified vertex count. Polygon storage is
    /// O(vertices) in the schema; capping the count keeps verify cost
    /// bounded. Locked at 32; do not raise.
    static let maxPolygonVertices: Int = 32

    // MARK: - Move State

    /// True when the user is dragging an existing region to a new position.
    private var isDraggingExistingRegion: Bool = false
    /// Offset from touch point to the region's overlay-space origin, preserving
    /// the grab point so the region doesn't jump to center on the finger.
    private var dragOffset: CGSize = .zero
    /// Normalized rect captured before a move begins, for cancel restoration.
    private var preDragNormalizedRect: CGRect?
    /// Primary touch reference recorded at touchesBegan. Secondary
    /// touches (e.g., a finger landing during a Pencil drag) are ignored
    /// while a gesture is in flight to prevent corruption of polygon /
    /// marquee state. Cleared in resetDragState.
    private var primaryTouch: UITouch?
    /// Long-press timer for selecting + moving unselected regions.
    private var longPressTimer: Timer?
    private var longPressOrigin: CGPoint?
    private var longPressCandidateID: UUID?
    /// Maximum finger movement before long-press is cancelled.
    private static let longPressMoveThreshold: CGFloat = 10.0
    /// Duration before long-press fires. 0.35s matches Apple's standard
    /// context menu duration — feels more responsive on iPad.
    private static let longPressDuration: TimeInterval = 0.35
    /// True when dragging multiple selected regions as a group.
    private var isGroupMoving: Bool = false
    /// Pre-drag normalized rects for all regions in the group move, for cancel restoration.
    private var preDragGroupRects: [UUID: CGRect] = [:]
    /// Touch start point for computing group move delta.
    private var groupMoveStart: CGPoint?

    // MARK: - Snap State

    /// A snap guide line to draw during interaction.
    private struct SnapGuide: Equatable {
        let position: CGFloat
        let isHorizontal: Bool  // true = horizontal line at Y position
    }

    /// Currently active snap guides, populated during drag/resize/move.
    private var activeGuides: [SnapGuide] = []
    /// Track previous guide count for haptic firing (only on new guide appearance).
    private var previousGuideSet: Set<CGFloat> = []

    /// Cached snap guide targets for the current drag session.
    /// Computed once on first use after drag begins, invalidated on drag end.
    private var cachedGuideTargets: (horizontal: [CGFloat], vertical: [CGFloat])?
    private var cachedGuideExcludeID: UUID?

    // MARK: - Snap-to-text Box State

    /// OCR text-block bounding boxes for the current page, in
    /// normalized PDF coordinates (0–1, bottom-left origin). Sourced from
    /// the existing OCR cache via the coordinator; the rectangle-draw
    /// snap-to-text-box assist consults this list during `touchesMoved`.
    /// Empty when OCR has not run for the page (snap path no-ops).
    var ocrTextBlockNormalizedRects: [CGRect] = []

    /// Magic-wand source data — per-word OCR hits for the current
    /// page, paired with the recognized text. Bounding boxes are in
    /// normalized PDF coordinates (0–1, bottom-left origin) so a touch
    /// point can be hit-tested without re-running OCR. When the
    /// long-press point falls inside one of these rects, the
    /// `UIContextMenuInteraction` adds a "Select all instances" item
    /// that drives a pre-filled exact-match search via
    /// `RedactionState.pendingMagicWandRequest`. Empty when OCR has not
    /// run for the page (the menu item is gated off).
    struct OCRWord: Equatable, Sendable {
        let text: String
        let normalizedRect: CGRect
    }
    var ocrWords: [OCRWord] = []

    /// When true, the rectangle-draw tool consults
    /// `ocrTextBlockNormalizedRects` during drag and snaps edges within
    /// `snapToTextTolerance = 8 / zoomScale` overlay points to the
    /// nearest text-block edge. Default on; bound to the Settings opt-out
    /// (`SettingsState.snapToTextEnabled`).
    var snapToTextEnabled: Bool = true

    /// Baseline snap tolerance at 1× zoom, in overlay-space points.
    /// Active tolerance is `baseline / zoomScale` so the assist tracks
    /// finger drift at any zoom level. Locked at 8 pt; do not tune.
    static let snapToTextToleranceAtUnitZoom: CGFloat = 8.0

    /// Visual tick segments rendered for active text-edge snaps.
    /// Each tick is an overlay-space line from `start` to `end`. Drawn
    /// after `drawSnapGuides` so it sits above the page but under the
    /// rubber-band rect. Cleared in `resetDragState`.
    private struct TextSnapTick: Equatable {
        let start: CGPoint
        let end: CGPoint
    }
    private var activeTextSnapTicks: [TextSnapTick] = []

    /// Test override for the zoom scale used by
    /// `applyTextBoxSnapping(to:)`. The production path walks the view
    /// hierarchy looking for a `PDFView`; tests synthesise the overlay
    /// without a parent and pin the zoom directly here. Default `nil`
    /// so production falls through to `currentZoomScale()`.
    var snapZoomScaleOverride: CGFloat?

    /// Haptic for snap alignment — fires when a new guide activates.
    private lazy var snapFeedback: UIImpactFeedbackGenerator = {
        let gen = UIImpactFeedbackGenerator(style: .rigid)
        gen.prepare()
        return gen
    }()

    // MARK: - Handle Animation State

    /// Current scale of resize handles (0 = hidden, 1 = full size).
    /// Animated via CADisplayLink for smooth 60fps interpolation.
    private var handleScale: CGFloat = 0.0
    private var handleDisplayLink: CADisplayLink?
    private var handleAnimStartTime: CFTimeInterval = 0
    private var handleAnimDuration: CFTimeInterval = 0.2
    private var handleAnimFromScale: CGFloat = 0.0
    private var handleAnimTargetScale: CGFloat = 1.0
    /// Track previous selection to detect transitions.
    private var previousSelectedID: UUID?

    /// Minimum drag distance (in points) before creating a region.
    /// Prevents accidental taps from creating tiny regions.
    private static let minimumDragThreshold: CGFloat = 8.0
    // Minimum committed region size (overlay points). Prevents accidental
    // taps from creating invisible regions. Separate from minimumDragThreshold
    // (which prevents drag start); this rejects valid drags that produce too-small regions.
    static let minimumCommittedRegionSize: CGFloat = 20.0

    // VoiceOver announcement when the committed rect falls below
    // `minimumCommittedRegionSize` on either axis. Names the 20pt floor so the
    // listener can target the dimension. Pinned by CanvasPolishBundleTests.
    static let subThresholdRejectionAnnouncement =
        "Region too small. Minimum is 20 by 20 points."

    // Polish helpers + adaptive-stroke constants live in
    // the sibling extension file `RedactionOverlayView+CanvasPolish.swift`:
    //   badgeOuterStrokeWidth / selectionHandleOuterStrokeWidth,
    //   dimensionLabelSmallRegionThreshold,
    //   DimensionLabelPosition + dimensionLabelPosition(…),
    //   clampedDragOrigin(…),
    //   HandleAnimationDirection + reduceMotionHandleScale(…).

    // Predicate for the touchesBegan branch that routes a region tap
    // through `coordinator?.toggleRegionSelection`. Returns true when either
    // the iPad Shift modifier is held OR the iPhone "Select More" toolbar
    // toggle is on; otherwise the tap follows the replace-selection path.
    // Pure predicate so the OR shape is pinned without a UITouch host.
    static func shouldToggleSelection(
        isMultiSelectActive: Bool,
        shiftHeld: Bool
    ) -> Bool {
        isMultiSelectActive || shiftHeld
    }

    // Label for the add-to-selection toolbar toggle (WU-38; historically
    // "Select More"). UXF-22: verb-object form names what a tap does
    // while the toggle is on. When at least one region is selected, the
    // count surfaces in the label so the user can see the selection size
    // without opening a separate count badge.
    static func selectMoreToggleLabel(selectedCount: Int) -> String {
        selectedCount > 0 ? "Add to Selection (\(selectedCount))" : "Add to Selection"
    }

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

    /// Minimum region dimension in overlay points.
    private static let minimumRegionSize: CGFloat = 10.0

    /// Prepared haptic generator for sub-threshold rejection feedback.
    private lazy var rejectionFeedback: UIImpactFeedbackGenerator = {
        let gen = UIImpactFeedbackGenerator(style: .soft)
        gen.prepare()
        return gen
    }()

    /// Haptic for move commit ("stamp placed" metaphor).
    private lazy var moveCommitFeedback: UIImpactFeedbackGenerator = {
        let gen = UIImpactFeedbackGenerator(style: .medium)
        gen.prepare()
        return gen
    }()

    /// Selection haptic for long-press activation.
    private lazy var selectionFeedback: UISelectionFeedbackGenerator = {
        let gen = UISelectionFeedbackGenerator()
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

        // Context menu for region info + delete
        let contextMenu = UIContextMenuInteraction(delegate: self)
        addInteraction(contextMenu)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Configuration

    /// Update displayed regions from RedactionState.
    /// No-op while a drag is active to avoid mid-gesture state reset.
    func configure(
        with regions: [RedactionRegion],
        selectedIDs: Set<UUID>,
        searchHighlights: [SearchResult] = [],
        livePreviewRects: [CGRect] = []
    ) {
        guard !isActivelyDragging else { return }
        let geometryChanged = regions != self.regions
        let selectionChanged = selectedIDs != self.selectedIDs
        let searchChanged = searchHighlights != self.searchHighlights
        let previewChanged = livePreviewRects != self.livePreviewRects
        self.regions = regions
        self.selectedIDs = selectedIDs
        self.searchHighlights = searchHighlights
        self.livePreviewRects = livePreviewRects
        if geometryChanged || selectionChanged || searchChanged || previewChanged {
            cachedAccessibilityElements = nil
            setNeedsDisplay()
        }
        // Animate resize handle transitions on selection change
        let newSingleID = selectedIDs.count == 1 ? selectedIDs.first : nil
        if selectionChanged {
            if previousSelectedID == nil, newSingleID != nil {
                animateHandlesIn()
            } else if previousSelectedID != nil, newSingleID == nil {
                animateHandlesOut()
            } else if previousSelectedID != newSingleID, newSingleID != nil {
                // Changed single selection — instant swap (handles stay visible)
                handleScale = 1.0
            }
            previousSelectedID = newSingleID
        }
        // Post VoiceOver layout notification on geometry changes
        if geometryChanged {
            UIAccessibility.post(notification: .layoutChanged, argument: nil)
        }
    }

    // MARK: - Hit Testing (tool-based routing)

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Always intercept if drawing mode is on
        if isDrawingMode {
            return super.hitTest(point, with: event)
        }
        // When multi-select is active, intercept empty-space touches
        // so the marquee can capture them. Without this, empty-space touches
        // would pass through to PDFView for pan and the lasso would never
        // begin. The marquee path is gated again inside `touchesBegan` on
        // `isMultiSelectActive && empty touch-down`, so this hit-test gate
        // only widens the routing — it does not commit a marquee on its own.
        if isMultiSelectActive {
            return super.hitTest(point, with: event)
        }
        // Without drawing mode, intercept touches on handles, regions, or selected
        // region body (for move).
        if hitTestResizeHandle(at: point) != nil { return super.hitTest(point, with: event) }
        if hitTestRegion(at: point) != nil { return super.hitTest(point, with: event) }
        // Pass through to PDFView for pan/zoom
        return nil
    }

    // MARK: - Touch Handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard touches.count == 1, let touch = touches.first else { return }
        // Ignore secondary touchesBegan while a gesture is already
        // in flight. Prevents a finger landing during a Pencil drag from
        // hijacking the gesture state machine.
        guard primaryTouch == nil else { return }
        primaryTouch = touch
        let point = touch.location(in: self)

        // Priority 1: Resize handle of selected region
        if let handle = hitTestResizeHandle(at: point) {
            activeResizeHandle = handle
            isActivelyDragging = true
            return
        }

        // Priority 2: Tap on existing region — select, and start move if already selected
        if let tappedRegion = hitTestRegion(at: point) {
            // iPad Shift+tap OR iPhone "Select More" toggle: tap toggles
            // multi-selection. Both routes converge on the same toggle
            // call — the toolbar toggle layers on top of the existing
            // selection model, no parallel mutation path.
            let shiftHeld = event?.modifierFlags.contains(.shift) ?? false
            if RedactionOverlayView.shouldToggleSelection(
                isMultiSelectActive: isMultiSelectActive,
                shiftHeld: shiftHeld
            ) {
                coordinator?.toggleRegionSelection(tappedRegion.id)
                return
            }

            if selectedIDs.contains(tappedRegion.id), selectedIDs.count == 1 {
                // Single-selected — begin move immediately
                beginMove(for: tappedRegion, at: point)
            } else if selectedIDs.contains(tappedRegion.id), selectedIDs.count > 1 {
                // Multi-selected and tapped one of them — begin group move
                beginGroupMove(at: point)
            } else {
                // Not selected — select and start long-press timer for move
                coordinator?.selectRegion(tappedRegion.id)
                longPressOrigin = point
                longPressCandidateID = tappedRegion.id
                longPressTimer = Timer.scheduledTimer(
                    withTimeInterval: Self.longPressDuration, repeats: false
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.longPressTimerFired()
                    }
                }
            }
            return
        }

        // Priority 3: lasso marquee — empty-space touch-down while the
        // "Select More" toggle is on becomes a rect-marquee multi-select drag.
        // Branch is gated on `isMultiSelectActive` and checked before the
        // drawing-mode branch so the marquee wins when both flags would
        // otherwise be eligible (the user opted into multi-select; new-region
        // drawing while multi-select is on is by design unreachable through
        // empty-space drag). The branch is orthogonal to `currentDragRect`
        // — see `marqueeRect` declaration. The undo-grouped commit happens
        // in `touchesEnded` via `coordinator?.commitLassoSelection`.
        if isMultiSelectActive {
            marqueeOrigin = point
            marqueeRect = nil
            isActivelyDragging = true
            // VoiceOver announcement for marquee-in-progress.
            // Mechanism-description language — names the
            // observable affordance without making a promise claim.
            UIAccessibility.post(notification: .announcement,
                                 argument: "Selecting regions")
            return
        }

        // Priority 4: Start drawing new region (only in drawing mode)
        if isDrawingMode {
            coordinator?.selectRegion(nil)
            switch activeShapeTool {
            case .rectangle:
                dragOrigin = point
                currentDragRect = nil
                isActivelyDragging = true
                // VoiceOver announcement for drawing-in-progress
                UIAccessibility.post(notification: .announcement,
                                     argument: "Drawing region")
            case .polygon:
                // Tap-on-first-vertex close model. Three
                // branches, in priority order:
                //   (a) close — count >= 3 AND tap within
                //       `polygonCloseRadius` of `polygonVertices[0]`.
                //   (b) dedup — tap within `polygonVertexDeduplicationDistance
                //       / zoomScale` of the previous vertex (silent drop +
                //       soft haptic). Compared against the previous vertex
                //       only so a non-adjacent vertex can sit close to an
                //       earlier one if the user intends it.
                //   (c) append — record vertex, mirror count onto observer,
                //       announce.
                isActivelyDragging = false
                if polygonVertices.count >= 3,
                   let first = polygonVertices.first {
                    let dx = point.x - first.x
                    let dy = point.y - first.y
                    if (dx * dx + dy * dy)
                        <= Self.polygonCloseRadius * Self.polygonCloseRadius {
                        commitPolygonRegion(vertices: polygonVertices)
                        polygonVertices = []
                        coordinator?.redactionState?.inProgressPolygonVertexCount = 0
                        setNeedsDisplay()
                        break
                    }
                }
                if let last = polygonVertices.last {
                    let dx = point.x - last.x
                    let dy = point.y - last.y
                    let tolerance =
                        Self.polygonVertexDeduplicationDistance
                        / currentZoomScale()
                    if (dx * dx + dy * dy) <= tolerance * tolerance {
                        rejectionFeedback.impactOccurred(intensity: 0.3)
                        break
                    }
                }
                polygonVertices.append(point)
                coordinator?.redactionState?.inProgressPolygonVertexCount =
                    polygonVertices.count
                setNeedsDisplay()
                UIAccessibility.post(
                    notification: .announcement,
                    argument: "Polygon vertex \(polygonVertices.count)"
                )
            case .freeform:
                freeformPath = [point]
                freeformZoomScale = currentZoomScale()
                isActivelyDragging = true
                UIAccessibility.post(
                    notification: .announcement,
                    argument: "Drawing freeform region"
                )
            }
        }
    }

    // MARK: - Polygon / Freeform Helpers

    /// Current zoom scale on the enclosing `PDFView`, used to scale the
    /// Douglas-Peucker tolerance for the freeform tool. Walks up the
    /// view hierarchy to locate the `PDFView`; defaults to 1.0 when no
    /// PDFView ancestor exists (test surfaces synthesise the overlay
    /// without a PDFView parent — the unit-zoom default keeps the
    /// simplification under test deterministic).
    private func currentZoomScale() -> CGFloat {
        var view: UIView? = self
        while view != nil {
            if let pdf = view as? PDFView {
                return pdf.scaleFactor
            }
            view = view?.superview
        }
        return 1.0
    }

    /// Commit an in-progress polygon as a `RedactionRegion`.
    /// Builds normalized vertices and the corresponding bounding rect,
    /// then routes through the existing `addRegion(_:page:undoManager:)`
    /// path so undo / observer wiring is uniform with the rectangle path.
    private func commitPolygonRegion(vertices: [CGPoint]) {
        guard vertices.count >= 3 else { return }
        let normalizedVerts = vertices.map(overlayPointToNormalized)
        // Bounding box of the vertex set.
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for v in normalizedVerts {
            if v.x < minX { minX = v.x }
            if v.x > maxX { maxX = v.x }
            if v.y < minY { minY = v.y }
            if v.y > maxY { maxY = v.y }
        }
        let bounds = CGRect(
            x: minX, y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY)
        )
        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: bounds,
            source: .manual,
            vertices: normalizedVerts
        )
        coordinator?.addRegion(region, page: pageIndex, undoManager: window?.undoManager)
        UIAccessibility.post(notification: .announcement, argument: "Polygon region added")
    }

    /// Convert a single point in overlay-space to normalized PDF
    /// coordinates (0–1, bottom-left origin). Mirrors
    /// `overlayToPDFNormalized` for a rect but for a single CGPoint.
    private func overlayPointToNormalized(_ point: CGPoint) -> CGPoint {
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return .zero }
        return CGPoint(x: point.x / w, y: 1.0 - point.y / h)
    }

    /// Douglas-Peucker simplification on `points` with tolerance
    /// `epsilon` (overlay-space points). Returns a simplified polyline
    /// preserving the first and last points. Used by the freeform tool
    /// to reduce raw touch streams (typically 100+ points) to
    /// ≤ `maxPolygonVertices` vertices.
    ///
    /// If the initial pass produces more than `maxVertices` points, the
    /// tolerance is doubled and the algorithm re-runs until the count
    /// fits. This is the locked simplification strategy;
    /// the per-iteration doubling is a deterministic backoff that
    /// converges in ≤ 10 iterations for any realistic touch stream.
    static func simplifyDouglasPeucker(
        _ points: [CGPoint],
        epsilon: CGFloat,
        maxVertices: Int = maxPolygonVertices
    ) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var eps = max(epsilon, 0.0001)
        var iterations = 0
        while iterations < 16 {
            let simplified = douglasPeuckerStep(points, epsilon: eps)
            if simplified.count <= maxVertices {
                return simplified
            }
            eps *= 2
            iterations += 1
        }
        // Hard fallback: uniformly subsample.
        return uniformSubsample(points, target: maxVertices)
    }

    private static func douglasPeuckerStep(
        _ points: [CGPoint], epsilon: CGFloat
    ) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        douglasPeuckerRecurse(
            points: points, start: 0, end: points.count - 1,
            epsilon: epsilon, keep: &keep
        )
        return zip(points, keep).compactMap { $1 ? $0 : nil }
    }

    private static func douglasPeuckerRecurse(
        points: [CGPoint], start: Int, end: Int,
        epsilon: CGFloat, keep: inout [Bool]
    ) {
        guard end > start + 1 else { return }
        let a = points[start]
        let b = points[end]
        var maxDist: CGFloat = 0
        var maxIndex = start
        for i in (start + 1)..<end {
            let d = perpendicularDistance(point: points[i], a: a, b: b)
            if d > maxDist {
                maxDist = d
                maxIndex = i
            }
        }
        if maxDist > epsilon {
            keep[maxIndex] = true
            douglasPeuckerRecurse(
                points: points, start: start, end: maxIndex,
                epsilon: epsilon, keep: &keep
            )
            douglasPeuckerRecurse(
                points: points, start: maxIndex, end: end,
                epsilon: epsilon, keep: &keep
            )
        }
    }

    private static func perpendicularDistance(
        point p: CGPoint, a: CGPoint, b: CGPoint
    ) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else {
            let ddx = p.x - a.x
            let ddy = p.y - a.y
            return (ddx * ddx + ddy * ddy).squareRoot()
        }
        // |(b - a) × (a - p)| / |b - a|
        let numer = abs(dy * p.x - dx * p.y + b.x * a.y - b.y * a.x)
        return numer / lenSq.squareRoot()
    }

    private static func uniformSubsample(_ points: [CGPoint], target: Int) -> [CGPoint] {
        guard points.count > target, target >= 2 else { return points }
        var result: [CGPoint] = []
        result.reserveCapacity(target)
        let step = Double(points.count - 1) / Double(target - 1)
        for i in 0..<target {
            let idx = Int((Double(i) * step).rounded())
            result.append(points[min(idx, points.count - 1)])
        }
        return result
    }

    // MARK: - Move Helpers

    /// Begin a move drag on an already-selected region.
    private func beginMove(for region: RedactionRegion, at point: CGPoint) {
        let viewRect = pdfNormalizedToOverlay(region.normalizedRect)
        dragOffset = CGSize(
            width: point.x - viewRect.origin.x,
            height: point.y - viewRect.origin.y
        )
        preDragNormalizedRect = region.normalizedRect
        isDraggingExistingRegion = true
        isActivelyDragging = true
        moveCommitFeedback.prepare()
    }

    /// Long-press timer fired — select the region and begin move.
    private func longPressTimerFired() {
        guard let candidateID = longPressCandidateID,
              let region = regions.first(where: { $0.id == candidateID }),
              let origin = longPressOrigin else {
            cancelLongPress()
            return
        }
        selectionFeedback.selectionChanged()
        coordinator?.selectRegion(candidateID)
        beginMove(for: region, at: origin)
        setNeedsDisplay()
    }

    /// Begin a group move of all selected regions.
    private func beginGroupMove(at point: CGPoint) {
        preDragGroupRects = [:]
        for region in regions where selectedIDs.contains(region.id) {
            preDragGroupRects[region.id] = region.normalizedRect
        }
        groupMoveStart = point
        isGroupMoving = true
        isActivelyDragging = true
        moveCommitFeedback.prepare()
    }

    /// Update all selected regions' positions during a group move.
    private func updateGroupMove(to point: CGPoint) {
        guard let start = groupMoveStart else { return }
        let dx = point.x - start.x
        let dy = point.y - start.y

        for i in regions.indices where selectedIDs.contains(regions[i].id) {
            guard let originalNorm = preDragGroupRects[regions[i].id] else { continue }
            let originalOverlay = pdfNormalizedToOverlay(originalNorm)
            var moved = originalOverlay.offsetBy(dx: dx, dy: dy)
            // Clamp to overlay bounds
            moved.origin.x = max(0, min(moved.origin.x, bounds.width - moved.width))
            moved.origin.y = max(0, min(moved.origin.y, bounds.height - moved.height))
            regions[i].normalizedRect = overlayToPDFNormalized(moved)
        }
    }

    private func cancelLongPress() {
        longPressTimer?.invalidate()
        longPressTimer = nil
        longPressOrigin = nil
        longPressCandidateID = nil
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Only honor touchesMoved while a gesture is in flight.
        guard primaryTouch != nil, let touch = touches.first else { return }
        let point = touch.location(in: self)

        // Cancel long-press timer if finger moved too far
        if let origin = longPressOrigin {
            let dx = abs(point.x - origin.x)
            let dy = abs(point.y - origin.y)
            if dx > Self.longPressMoveThreshold || dy > Self.longPressMoveThreshold {
                cancelLongPress()
            }
        }

        if isGroupMoving {
            // Group move — translate all selected regions by delta
            updateGroupMove(to: point)
            setNeedsDisplay()
        } else if isDraggingExistingRegion {
            // Move selected region — update position from touch minus offset
            updateSelectedRegionForMove(to: point)
            setNeedsDisplay()
        } else if let handle = activeResizeHandle {
            // Resize selected region
            updateSelectedRegionForResize(handle: handle, to: point)
            setNeedsDisplay()
        } else if let origin = marqueeOrigin {
            // Lasso marquee — track the marching-ants rect over
            // empty space. The branch is reached only when touchesBegan
            // set `marqueeOrigin` (which it does only when
            // `isMultiSelectActive && empty touch-down`), so the
            // new-region drawing path below is never entered during a
            // marquee drag. No snap-to-guides on the marquee — the
            // rectangle is a selection cursor, not a committed region.
            // No minimum-drag threshold gate so very short drags still
            // surface a tiny visual cue; the intersection at commit will
            // simply select nothing if no region overlaps.
            marqueeRect = CGRect(
                x: min(origin.x, point.x),
                y: min(origin.y, point.y),
                width: abs(point.x - origin.x),
                height: abs(point.y - origin.y)
            )
            setNeedsDisplay()
        } else if isDrawingMode && activeShapeTool == .freeform
                  && !freeformPath.isEmpty {
            // Accumulate freeform stroke points. Collapse near-
            // duplicate points (< 1 pt apart) to keep the raw stream
            // bounded — even at 240 Hz a sub-pixel append is wasted work.
            if let last = freeformPath.last {
                let dxp = point.x - last.x
                let dyp = point.y - last.y
                if dxp * dxp + dyp * dyp > 1 {
                    freeformPath.append(point)
                    setNeedsDisplay()
                }
            } else {
                freeformPath.append(point)
                setNeedsDisplay()
            }
        } else if let origin = dragOrigin {
            // Draw new region — only commit visually once past threshold
            let dx = abs(point.x - origin.x)
            let dy = abs(point.y - origin.y)
            if dx >= Self.minimumDragThreshold || dy >= Self.minimumDragThreshold {
                var rect = CGRect(
                    x: min(origin.x, point.x),
                    y: min(origin.y, point.y),
                    width: abs(point.x - origin.x),
                    height: abs(point.y - origin.y)
                )
                // Apply snap guides during new region drawing
                rect = applySnapping(to: rect, excluding: nil)
                // Apply snap-to-text-box assist during new
                // region drawing. The assist runs after the region-edge
                // snap so a strong text-edge match overrides a weaker
                // region-edge match; both passes share the same
                // overlay-space coordinate system. Tolerance scales by
                // `1/zoomScale` so the same finger drift on screen
                // means the same number of overlay points at any zoom.
                rect = applyTextBoxSnapping(to: rect)
                currentDragRect = rect
                setNeedsDisplay()
            }
        }
    }

    // MARK: - Snap to Text-Box Assist

    /// Snap rect edges to the nearest OCR text-block edge within
    /// `snapToTextToleranceAtUnitZoom / zoomScale` overlay-space points.
    /// Designed to align rectangle edges to text rows during drag;
    /// returns the input rect unchanged when the assist is disabled,
    /// when no text blocks are cached, or when no edge is in tolerance.
    /// Populates `activeTextSnapTicks` with one tick per snapped edge so
    /// `draw(_:)` can render a visual affordance.
    private func applyTextBoxSnapping(to rect: CGRect) -> CGRect {
        // Clear last frame's ticks regardless of branch — a stale tick
        // would otherwise linger after the finger moves out of range.
        activeTextSnapTicks = []
        guard snapToTextEnabled, !ocrTextBlockNormalizedRects.isEmpty else {
            return rect
        }
        let zoom = max(snapZoomScaleOverride ?? currentZoomScale(), 0.01)
        let tolerance = Self.snapToTextToleranceAtUnitZoom / zoom

        // Build overlay-space text-block rects once per call. Stays in
        // overlay coords so edge comparisons match `rect`.
        let textRects = ocrTextBlockNormalizedRects.map(pdfNormalizedToOverlay)

        // Collect all candidate text edges. `xs` are left/right edges
        // (snap targets for the rect's left/right edges); `ys` are
        // top/bottom edges (snap targets for the rect's top/bottom).
        var xs: [CGFloat] = []
        var ys: [CGFloat] = []
        xs.reserveCapacity(textRects.count * 2)
        ys.reserveCapacity(textRects.count * 2)
        for t in textRects {
            xs.append(t.minX)
            xs.append(t.maxX)
            ys.append(t.minY)
            ys.append(t.maxY)
        }

        var result = rect
        var ticks: [TextSnapTick] = []

        // Helper: nearest target within tolerance, else nil.
        func nearest(_ edge: CGFloat, in targets: [CGFloat]) -> CGFloat? {
            guard let candidate = targets.min(by: {
                abs($0 - edge) < abs($1 - edge)
            }) else { return nil }
            return abs(candidate - edge) <= tolerance ? candidate : nil
        }

        // Snap left edge.
        if let left = nearest(result.minX, in: xs) {
            let delta = left - result.minX
            result = CGRect(
                x: result.minX + delta,
                y: result.minY,
                width: max(0, result.width - delta),
                height: result.height
            )
            ticks.append(TextSnapTick(
                start: CGPoint(x: left, y: result.minY),
                end: CGPoint(x: left, y: result.maxY)
            ))
        }
        // Snap right edge.
        if let right = nearest(result.maxX, in: xs) {
            let delta = right - result.maxX
            result = CGRect(
                x: result.minX,
                y: result.minY,
                width: max(0, result.width + delta),
                height: result.height
            )
            ticks.append(TextSnapTick(
                start: CGPoint(x: right, y: result.minY),
                end: CGPoint(x: right, y: result.maxY)
            ))
        }
        // Snap top edge (minY in overlay space).
        if let top = nearest(result.minY, in: ys) {
            let delta = top - result.minY
            result = CGRect(
                x: result.minX,
                y: result.minY + delta,
                width: result.width,
                height: max(0, result.height - delta)
            )
            ticks.append(TextSnapTick(
                start: CGPoint(x: result.minX, y: top),
                end: CGPoint(x: result.maxX, y: top)
            ))
        }
        // Snap bottom edge (maxY in overlay space).
        if let bottom = nearest(result.maxY, in: ys) {
            let delta = bottom - result.maxY
            result = CGRect(
                x: result.minX,
                y: result.minY,
                width: result.width,
                height: max(0, result.height + delta)
            )
            ticks.append(TextSnapTick(
                start: CGPoint(x: result.minX, y: bottom),
                end: CGPoint(x: result.maxX, y: bottom)
            ))
        }

        activeTextSnapTicks = ticks
        return result
    }

    /// Update the selected region's position during a move drag.
    private func updateSelectedRegionForMove(to point: CGPoint) {
        guard let selectedID,
              let idx = regions.firstIndex(where: { $0.id == selectedID })
        else { return }

        // Capture old rect for dirty-region invalidation
        let oldOverlayRect = pdfNormalizedToOverlay(regions[idx].normalizedRect)
        let regionSize = oldOverlayRect.size

        // Clamp the touch into overlay bounds first, then
        // derive the region origin from (clamped touch) - dragOffset.
        // Keeps the grab point under the finger up to the overlay edge
        // and handles the region-bigger-than-overlay edge case at one site.
        let newOrigin = Self.clampedDragOrigin(
            touchPoint: point,
            dragOffset: dragOffset,
            regionSize: regionSize,
            overlaySize: bounds.size
        )

        var newRect = CGRect(origin: newOrigin, size: regionSize)

        // Apply snap guides during move
        newRect = applySnapping(to: newRect, excluding: selectedID)

        regions[idx].normalizedRect = overlayToPDFNormalized(newRect)

        // Dirty-rect optimization: only invalidate old + new rect area (+ margin for shadow/handles)
        let margin: CGFloat = 20
        let dirtyRect = oldOverlayRect.union(newRect).insetBy(dx: -margin, dy: -margin)
        setNeedsDisplay(dirtyRect)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        defer { resetDragState() }

        // Commit lasso marquee — intersect every visible region's
        // normalizedRect against the marquee's normalized rect; route the
        // hit set through `coordinator?.commitLassoSelection` so the
        // 500-region cap + warning toast land inside `RedactionState`.
        // The intersection uses the existing overlayToPDFNormalized
        // conversion site so the math stays single-sourced with the
        // new-region commit path. Branch is reached only when
        // `marqueeOrigin` was set — guarded by the
        // `isMultiSelectActive && empty touch-down` predicate in
        // `touchesBegan`, so multi-select-off documents never enter here.
        if marqueeOrigin != nil {
            let rect = marqueeRect ?? .zero
            let normalizedMarquee = overlayToPDFNormalized(rect)
            let hits = Self.regionsIntersecting(
                marqueeNormalized: normalizedMarquee,
                regions: regions
            )
            coordinator?.commitLassoSelection(hits, undoManager: window?.undoManager)
            return
        }

        // Commit group move
        if isGroupMoving {
            moveCommitFeedback.impactOccurred()
            let moves = regions
                .filter { selectedIDs.contains($0.id) }
                .map { (id: $0.id, newRect: $0.normalizedRect) }
            coordinator?.commitMoveMultiple(moves, page: pageIndex,
                                            undoManager: window?.undoManager)
            return
        }

        // Commit single move
        if isDraggingExistingRegion, let id = selectedID,
           let region = regions.first(where: { $0.id == id }) {
            moveCommitFeedback.impactOccurred()
            coordinator?.commitMove(id, page: pageIndex,
                                    newRect: region.normalizedRect,
                                    undoManager: window?.undoManager)
            return
        }

        // Commit resize
        if activeResizeHandle != nil, let id = selectedID,
           let region = regions.first(where: { $0.id == id }) {
            coordinator?.commitResize(id, page: pageIndex,
                                      newRect: region.normalizedRect,
                                      undoManager: window?.undoManager)
            return
        }

        // Commit freeform stroke. Simplify via Douglas-Peucker
        // first; tolerance scales by 1/zoomScale. Need at least 3 unique
        // points for a closed polygon — short streaks are dropped.
        if isDrawingMode && activeShapeTool == .freeform && !freeformPath.isEmpty {
            let tolerance =
                Self.freeformDouglasPeuckerToleranceAtUnitZoom
                / max(freeformZoomScale, 0.01)
            let simplified = Self.simplifyDouglasPeucker(
                freeformPath, epsilon: tolerance
            )
            if simplified.count >= 3 {
                commitPolygonRegion(vertices: simplified)
            }
            return
        }

        // Polygon tool — touch-up after a single tap is a no-op
        // (the vertex was already appended in touchesBegan). No commit
        // here; commit happens on double-tap.
        if isDrawingMode && activeShapeTool == .polygon {
            return
        }

        // Commit new region
        guard let rect = currentDragRect else { return }

        // Reject sub-threshold regions (< 20×20pt in overlay space).
        // Animate shrink-to-center + fade, soft haptic, VoiceOver announcement.
        if rect.width < Self.minimumCommittedRegionSize
            || rect.height < Self.minimumCommittedRegionSize {
            rejectSubThresholdRegion(rect)
            return
        }

        let normalizedRect = overlayToPDFNormalized(rect)
        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: normalizedRect,
            source: .manual
        )
        coordinator?.addRegion(region, page: pageIndex, undoManager: window?.undoManager)
        // VoiceOver announcement on region commit
        UIAccessibility.post(notification: .announcement, argument: "Region added")
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Discard without committing — restore pre-drag region state
        if isGroupMoving {
            for i in regions.indices {
                if let original = preDragGroupRects[regions[i].id] {
                    regions[i].normalizedRect = original
                }
            }
        } else if isDraggingExistingRegion, let preDragNormalizedRect,
           let selectedID,
           let idx = regions.firstIndex(where: { $0.id == selectedID }) {
            // Restore pre-move position
            regions[idx].normalizedRect = preDragNormalizedRect
        }
        if activeResizeHandle != nil {
            // Undo the in-progress resize by re-configuring from state
            coordinator?.refreshOverlay(for: pageIndex)
        }
        // A system-level cancel during polygon/freeform discards
        // the in-progress shape — the user's intent was lost, do not
        // commit half a polygon.
        discardInProgressPolygon()
        resetDragState()
        setNeedsDisplay()
    }

    private func resetDragState() {
        primaryTouch = nil
        dragOrigin = nil
        currentDragRect = nil
        activeResizeHandle = nil
        isActivelyDragging = false
        // Lasso marquee state cleanup
        marqueeOrigin = nil
        marqueeRect = nil
        // Move state cleanup
        isDraggingExistingRegion = false
        dragOffset = .zero
        preDragNormalizedRect = nil
        cancelLongPress()
        // Group move cleanup
        isGroupMoving = false
        preDragGroupRects = [:]
        groupMoveStart = nil
        // Snap state cleanup
        activeGuides = []
        previousGuideSet = []
        cachedGuideTargets = nil
        cachedGuideExcludeID = nil
        // Text-snap tick cleanup. Ticks are transient — they
        // exist only while the drag is producing edge matches.
        activeTextSnapTicks = []
        // Freeform stroke cleanup. NOTE: polygonVertices is
        // intentionally NOT reset here — polygon tap-to-vertex
        // accumulates across multiple touch sequences and only resets
        // on commit, escape, or tool deactivation.
        freeformPath = []
        freeformZoomScale = 1.0
    }

    /// Clear the in-progress polygon vertex list. Call when the
    /// user switches tool, taps outside the overlay, or presses Escape.
    /// `touchesCancelled` triggers this so a system-level cancel discards
    /// the in-progress polygon. Also zeros the observer field on
    /// `RedactionState` so the bottom capsule resets to the count-0 string.
    func discardInProgressPolygon() {
        polygonVertices = []
        coordinator?.redactionState?.inProgressPolygonVertexCount = 0
        setNeedsDisplay()
    }

    /// Commit the in-progress polygon when the user taps
    /// the SwiftUI "Close polygon" button. Routed by
    /// `PDFViewCoordinator.commitInProgressPolygon`. Silent no-op when
    /// below the 3-vertex floor — the button surface is disabled there,
    /// and the floor is also enforced inside `commitPolygonRegion`, so
    /// the guard here is belt-and-braces against a button-press / state
    /// mutation race.
    func commitInProgressPolygon() {
        guard polygonVertices.count >= 3 else { return }
        commitPolygonRegion(vertices: polygonVertices)
        polygonVertices = []
        coordinator?.redactionState?.inProgressPolygonVertexCount = 0
        setNeedsDisplay()
    }

    /// Animate sub-threshold region rejection with shrink-to-center + fade.
    private func rejectSubThresholdRegion(_ rect: CGRect) {
        rejectionFeedback.impactOccurred(intensity: 0.3)

        // VoiceOver announcement. Mechanism-description string
        // names the 20pt floor so the user knows what dimension to target.
        UIAccessibility.post(
            notification: .announcement,
            argument: RedactionOverlayView.subThresholdRejectionAnnouncement
        )

        // Visual: create a temporary view that shrinks to center and fades out
        let rejectView = UIView(frame: rect)
        rejectView.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.15)
        rejectView.layer.borderColor = UIColor.systemBlue.cgColor
        rejectView.layer.borderWidth = 2.0
        addSubview(rejectView)

        if UIAccessibility.isReduceMotionEnabled {
            // Respect reduce-motion: simple fade without scale transform
            UIView.animate(withDuration: 0.15, delay: 0, options: .curveEaseOut) {
                rejectView.alpha = 0
            } completion: { _ in
                rejectView.removeFromSuperview()
            }
        } else {
            UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseOut) {
                rejectView.transform = CGAffineTransform(scaleX: 0.01, y: 0.01)
                rejectView.alpha = 0
            } completion: { _ in
                rejectView.removeFromSuperview()
            }
        }
    }

    // MARK: - Hover

    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began, .changed:
            let region = hitTestRegion(at: point)
            let newID = region?.id
            if newID != coordinator?.redactionState?.hoveredRegionID {
                coordinator?.redactionState?.hoveredRegionID = newID
            }
        case .ended, .cancelled:
            coordinator?.redactionState?.hoveredRegionID = nil
        default:
            break
        }
    }

    // MARK: - Resize

    private func updateSelectedRegionForResize(handle: ResizeHandle, to point: CGPoint) {
        guard let selectedID,
              let idx = regions.firstIndex(where: { $0.id == selectedID })
        else { return }

        let current = pdfNormalizedToOverlay(regions[idx].normalizedRect)
        var newRect: CGRect

        switch handle {
        case .topLeft:
            newRect = CGRect(x: point.x, y: point.y,
                             width: current.maxX - point.x, height: current.maxY - point.y)
        case .topRight:
            newRect = CGRect(x: current.minX, y: point.y,
                             width: point.x - current.minX, height: current.maxY - point.y)
        case .bottomLeft:
            newRect = CGRect(x: point.x, y: current.minY,
                             width: current.maxX - point.x, height: point.y - current.minY)
        case .bottomRight:
            newRect = CGRect(x: current.minX, y: current.minY,
                             width: point.x - current.minX, height: point.y - current.minY)
        case .topCenter:
            newRect = CGRect(x: current.minX, y: point.y,
                             width: current.width, height: current.maxY - point.y)
        case .bottomCenter:
            newRect = CGRect(x: current.minX, y: current.minY,
                             width: current.width, height: point.y - current.minY)
        case .leftCenter:
            newRect = CGRect(x: point.x, y: current.minY,
                             width: current.maxX - point.x, height: current.height)
        case .rightCenter:
            newRect = CGRect(x: current.minX, y: current.minY,
                             width: point.x - current.minX, height: current.height)
        }

        // Enforce minimum size in overlay space
        newRect.size.width = max(abs(newRect.size.width), Self.minimumRegionSize)
        newRect.size.height = max(abs(newRect.size.height), Self.minimumRegionSize)

        // Apply snap guides to moving edges during resize
        newRect = applyResizeSnapping(to: newRect, handle: handle, excluding: selectedID)

        // Clamp to overlay bounds
        newRect = newRect.intersection(bounds)
        guard !newRect.isNull else { return }

        regions[idx].normalizedRect = overlayToPDFNormalized(newRect)
        setNeedsDisplay()
    }

    // MARK: - Region Hit Testing

    /// Hit-test regions in reverse order so topmost region wins.
    private func hitTestRegion(at point: CGPoint) -> RedactionRegion? {
        for region in regions.reversed() {
            let viewRect = pdfNormalizedToOverlay(region.normalizedRect)
            // 8-point inset expansion for easier touch targeting
            let hitRect = viewRect.insetBy(dx: -8, dy: -8)
            if hitRect.contains(point) {
                return region
            }
        }
        return nil
    }

    // MARK: - Resize Handle Hit Testing

    enum ResizeHandle {
        case topLeft, topRight, bottomLeft, bottomRight
        case topCenter, bottomCenter, leftCenter, rightCenter
    }

    private func hitTestResizeHandle(at point: CGPoint) -> ResizeHandle? {
        guard let selectedID,
              let region = regions.first(where: { $0.id == selectedID })
        else { return nil }

        let rect = pdfNormalizedToOverlay(region.normalizedRect)
        // 22pt hit area — combined with handle visual size meets 44pt minimum
        let handleSize: CGFloat = 22

        let handles: [(ResizeHandle, CGPoint)] = [
            (.topLeft,     CGPoint(x: rect.minX, y: rect.minY)),
            (.topRight,    CGPoint(x: rect.maxX, y: rect.minY)),
            (.bottomLeft,  CGPoint(x: rect.minX, y: rect.maxY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)),
            (.topCenter,   CGPoint(x: rect.midX, y: rect.minY)),
            (.bottomCenter, CGPoint(x: rect.midX, y: rect.maxY)),
            (.leftCenter,  CGPoint(x: rect.minX, y: rect.midY)),
            (.rightCenter, CGPoint(x: rect.maxX, y: rect.midY)),
        ]

        for (handle, center) in handles {
            let hitArea = CGRect(x: center.x - handleSize / 2,
                                 y: center.y - handleSize / 2,
                                 width: handleSize, height: handleSize)
            if hitArea.contains(point) { return handle }
        }
        return nil
    }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        // Clip to dirty rect for performance with many regions.
        ctx.clip(to: rect)

        // Draw committed regions
        for region in regions {
            let viewRect = pdfNormalizedToOverlay(region.normalizedRect)
            // Perf: Skip regions entirely outside the dirty rect.
            // 20pt expansion accounts for resize handles, badges, and shadow.
            guard viewRect.insetBy(dx: -20, dy: -20).intersects(rect) else { continue }
            let isSelected = selectedIDs.contains(region.id)
            let color = region.displayColor(isSelected: isSelected)
            let isBeingMoved = isSelected && isDraggingExistingRegion

            // Lift effect during move — 1.02× scale + drop shadow
            let drawRect: CGRect
            if isBeingMoved {
                let dx = viewRect.width * 0.01
                let dy = viewRect.height * 0.01
                drawRect = viewRect.insetBy(dx: -dx, dy: -dy)
                ctx.saveGState()
                // Adapt the drag-lift shadow so it reads against the dark
                // editor background when the overlay extends past the page
                // edge. Core Graphics consumes a CGColor, so resolve the
                // trait-aware UIColor through the view's traitCollection.
                let liftShadowColor = UIColor { trait in
                    trait.userInterfaceStyle == .dark
                        ? UIColor.white.withAlphaComponent(0.08)
                        : UIColor.black.withAlphaComponent(0.20)
                }
                ctx.setShadow(
                    offset: CGSize(width: 0, height: 4),
                    blur: 12,
                    color: liftShadowColor.resolvedColor(with: traitCollection).cgColor
                )
            } else {
                drawRect = viewRect
            }

            // Fill at 30% opacity (60% when reduceTransparency enabled),
            // border at 100%. Stroke: 2pt unselected, 2.5pt selected.
            let fillOpacity: CGFloat = UIAccessibility.isReduceTransparencyEnabled ? 0.6 : 0.3
            ctx.setFillColor(color.withAlphaComponent(fillOpacity).cgColor)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(isSelected ? 2.5 : 2.0)
            ctx.setLineDash(phase: 0, lengths: [])
            // Polygon regions render as filled polygons (even-odd
            // rule). The lift effect for moves still uses the bounding
            // box (drawRect) — the polygon itself is drawn at its real
            // shape inside that box.
            if let vertices = region.vertices, vertices.count >= 3 {
                drawPolygonRegion(
                    ctx: ctx, vertices: vertices, isBeingMoved: isBeingMoved
                )
            } else {
                ctx.addRect(drawRect)
                ctx.drawPath(using: .fillStroke)
            }

            if isBeingMoved {
                ctx.restoreGState()
            }

            // PII type badge for detected regions
            drawRegionBadge(ctx: ctx, region: region, rect: drawRect)

            // Dimension label during move
            if isBeingMoved {
                drawDimensionLabel(ctx: ctx, rect: drawRect)
            }

            // Resize handles for selected region (suppressed during move)
            if isSelected && !isBeingMoved {
                drawResizeHandles(ctx: ctx, rect: drawRect)
            }
        }

        // Live-preview highlights — drawn under committed search highlights
        // so the visual transition (faint → solid yellow) signals "preview →
        // confirmed result". 20% yellow fill, no border.
        if !livePreviewRects.isEmpty {
            ctx.setFillColor(UIColor.systemYellow.withAlphaComponent(0.20).cgColor)
            for normalizedRect in livePreviewRects {
                let viewRect = pdfNormalizedToOverlay(normalizedRect)
                guard viewRect.intersects(rect) else { continue }
                ctx.fill([viewRect])
            }
        }

        // Draw search highlights on top of regions so overlaps are visible
        for highlight in searchHighlights {
            let viewRect = pdfNormalizedToOverlay(highlight.normalizedRect)
            guard viewRect.intersects(rect) else { continue }
            if highlight.isSelected {
                // Selected: amber fill 30%, amber 2pt border
                ctx.setFillColor(UIColor.systemYellow.withAlphaComponent(0.3).cgColor)
                ctx.setStrokeColor(UIColor.systemOrange.cgColor)
                ctx.setLineWidth(2.0)
                ctx.addRect(viewRect)
                ctx.drawPath(using: .fillStroke)
            } else {
                // Deselected: yellow fill 15%, no border
                ctx.setFillColor(UIColor.systemYellow.withAlphaComponent(0.15).cgColor)
                ctx.fill([viewRect])
            }
        }

        // Draw active snap guide lines
        drawSnapGuides(ctx: ctx)

        // Draw active text-edge snap tick marks. Tick is a small
        // affordance — if rendering fails (e.g. zero-length segment),
        // the rectangle drag continues regardless.
        drawTextSnapTicks(ctx: ctx)

        // Draw in-progress rubber-band rectangle
        if let dragRect = currentDragRect {
            ctx.setFillColor(UIColor.systemBlue.withAlphaComponent(0.15).cgColor)
            ctx.setStrokeColor(UIColor.systemBlue.cgColor)
            ctx.setLineWidth(2.0)
            ctx.setLineDash(phase: 0, lengths: [6, 3])
            ctx.addRect(dragRect)
            ctx.drawPath(using: .fillStroke)
            // Dimension label during drawing
            drawDimensionLabel(ctx: ctx, rect: dragRect)
        }

        // Dashed close-preview + first-vertex close ring.
        // Render edges between collected vertices and small dots at each
        // vertex so the user can see where their taps landed. Once
        // `count >= 3`, also stroke a dashed segment from the last
        // vertex back to the first and ring the first vertex so the
        // close target is visible.
        if !polygonVertices.isEmpty {
            ctx.saveGState()
            ctx.setStrokeColor(UIColor.systemBlue.cgColor)
            ctx.setFillColor(UIColor.systemBlue.withAlphaComponent(0.15).cgColor)
            ctx.setLineWidth(2.0)
            ctx.setLineDash(phase: 0, lengths: [])

            if polygonVertices.count >= 2 {
                ctx.move(to: polygonVertices[0])
                for v in polygonVertices.dropFirst() {
                    ctx.addLine(to: v)
                }
                ctx.strokePath()
            }

            if polygonVertices.count >= 3,
               let first = polygonVertices.first,
               let last = polygonVertices.last {
                ctx.saveGState()
                ctx.setStrokeColor(
                    UIColor.systemBlue.withAlphaComponent(0.5).cgColor
                )
                ctx.setLineDash(phase: 0, lengths: [6, 3])
                ctx.move(to: last)
                ctx.addLine(to: first)
                ctx.strokePath()
                ctx.restoreGState()
            }

            for v in polygonVertices {
                let dotRect = CGRect(x: v.x - 4, y: v.y - 4, width: 8, height: 8)
                ctx.setFillColor(UIColor.systemBlue.cgColor)
                ctx.fillEllipse(in: dotRect)
            }

            if polygonVertices.count >= 3, let first = polygonVertices.first {
                let radius = Self.firstVertexRingDiameter / 2
                let ringRect = CGRect(
                    x: first.x - radius, y: first.y - radius,
                    width: Self.firstVertexRingDiameter,
                    height: Self.firstVertexRingDiameter
                )
                ctx.setStrokeColor(UIColor.systemBlue.cgColor)
                ctx.setLineWidth(2.0)
                ctx.setLineDash(phase: 0, lengths: [])
                ctx.strokeEllipse(in: ringRect)
            }
            ctx.restoreGState()
        }

        // In-progress freeform stroke. Stroke the polyline only —
        // the closed fill happens at commit so the user sees the live
        // path as a stroke and not a filling shape.
        if freeformPath.count >= 2 {
            ctx.saveGState()
            ctx.setStrokeColor(UIColor.systemBlue.cgColor)
            ctx.setLineWidth(2.0)
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.move(to: freeformPath[0])
            for p in freeformPath.dropFirst() {
                ctx.addLine(to: p)
            }
            ctx.strokePath()
            ctx.restoreGState()
        }

        // Draw in-progress lasso marquee. Distinguished from the
        // new-region rubber-band by a tint-only system-purple stroke + a
        // sparser dash so the user sees this rectangle as a selection
        // cursor rather than a region commitment. No dimension label —
        // the marquee is transient and the user does not care about its
        // exact size, only the regions it overlaps.
        if let marqueeRect {
            ctx.setFillColor(UIColor.systemPurple.withAlphaComponent(0.10).cgColor)
            ctx.setStrokeColor(UIColor.systemPurple.cgColor)
            ctx.setLineWidth(1.5)
            ctx.setLineDash(phase: 0, lengths: [4, 4])
            ctx.addRect(marqueeRect)
            ctx.drawPath(using: .fillStroke)
        }

        // Dimension label during resize
        if activeResizeHandle != nil, let selectedID,
           let region = regions.first(where: { $0.id == selectedID }) {
            let resizeRect = pdfNormalizedToOverlay(region.normalizedRect)
            drawDimensionLabel(ctx: ctx, rect: resizeRect)
        }
    }

    /// Draw a committed polygon region. Translates normalized
    /// vertices into overlay-space and fills the closed path with the
    /// caller's current fill color (set by `draw(_:)` before calling
    /// in). Even-odd rule matches the engine fill path (PixelOperations
    /// `fillPath(using: .evenOdd)`).
    private func drawPolygonRegion(
        ctx: CGContext,
        vertices: [CGPoint],
        isBeingMoved: Bool
    ) {
        let overlayPoints = vertices.map(normalizedPointToOverlay)
        guard overlayPoints.count >= 3 else { return }
        ctx.beginPath()
        ctx.move(to: overlayPoints[0])
        for p in overlayPoints.dropFirst() {
            ctx.addLine(to: p)
        }
        ctx.closePath()
        ctx.drawPath(using: .eoFillStroke)
    }

    /// Convert a normalized point (0–1, bottom-left origin) into
    /// overlay-space (UIKit top-left origin).
    private func normalizedPointToOverlay(_ point: CGPoint) -> CGPoint {
        let w = bounds.width
        let h = bounds.height
        return CGPoint(x: point.x * w, y: (1.0 - point.y) * h)
    }

    private func drawResizeHandles(ctx: CGContext, rect: CGRect) {
        // Scale handles by animated handleScale (0 = hidden, 1 = full size)
        guard handleScale > 0.001 else { return }

        let handleRadius: CGFloat = 5.0 * handleScale
        // Mid-gray outer ring scales together with the handle so
        // it animates in/out alongside the white-fill / blue-stroke disc.
        let outerStroke: CGFloat = Self.selectionHandleOuterStrokeWidth * handleScale
        let points = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY),
        ]

        ctx.setLineDash(phase: 0, lengths: [])

        for p in points {
            // Mid-gray outer ring drawn under the handle. Pads
            // the handle radius by `outerStroke` on each side so the visible
            // band of grey sits outside the handle's blue border, giving the
            // handle a visible perimeter against white page margins.
            let outerRadius = handleRadius + outerStroke
            let outerRect = CGRect(
                x: p.x - outerRadius, y: p.y - outerRadius,
                width: outerRadius * 2, height: outerRadius * 2
            )
            ctx.setFillColor(UIColor.systemGray2.cgColor)
            ctx.fillEllipse(in: outerRect)

            let handleRect = CGRect(
                x: p.x - handleRadius, y: p.y - handleRadius,
                width: handleRadius * 2, height: handleRadius * 2
            )
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.setStrokeColor(UIColor.systemBlue.cgColor)
            ctx.setLineWidth(1.5)
            ctx.fillEllipse(in: handleRect)
            ctx.strokeEllipse(in: handleRect)
        }
    }

    // MARK: - Region Badge

    /// Draw a small type badge at the top-right corner of detected regions.
    /// Suppressed for manual regions, selected regions (resize handles
    /// overlap top-right corner), and regions too small to fit (<30pt width).
    private func drawRegionBadge(ctx: CGContext, region: RedactionRegion, rect: CGRect) {
        guard region.source != .manual,
              region.id != selectedID,
              rect.width >= 30,
              let metadata = coordinator?.redactionState?.regionMetadata[region.id]
        else { return }

        let label = metadata.badgeLabel as NSString
        let fontSize: CGFloat = 9
        let font = UIFont.systemFont(ofSize: fontSize, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white,
        ]
        let textSize = label.size(withAttributes: attributes)
        let badgePadding: CGFloat = ResectaTokens.Spacing.xxs + 1 // 3pt
        let badgeSize = CGSize(
            width: textSize.width + badgePadding * 2,
            height: textSize.height + badgePadding
        )

        // Position: top-right corner of the region rect, inset slightly
        let badgeOrigin = CGPoint(
            x: rect.maxX - badgeSize.width - 2,
            y: rect.minY + 2
        )
        let badgeRect = CGRect(origin: badgeOrigin, size: badgeSize)

        // Badge background — orange for PII, purple for faces
        let badgeColor: UIColor = switch region.source {
        case .detectedPII: .systemOrange
        case .detectedFace: .systemPurple
        case .manual: .systemRed // Unreachable due to guard
        case .searchMatch: .systemGreen
        }
        let path = UIBezierPath(
            roundedRect: badgeRect,
            cornerRadius: ResectaTokens.CornerRadius.small / 2
        )
        ctx.setFillColor(badgeColor.cgColor)
        ctx.addPath(path.cgPath)
        ctx.fillPath()

        // Hairline outer stroke for dark-mode contrast. Drawn
        // after the fill so the stroke sits on the perimeter, not the
        // interior. `UIColor.separator` adapts across light/dark trait.
        ctx.setStrokeColor(UIColor.separator.cgColor)
        ctx.setLineWidth(Self.badgeOuterStrokeWidth)
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.addPath(path.cgPath)
        ctx.strokePath()

        // Badge text
        label.draw(
            at: CGPoint(
                x: badgeOrigin.x + badgePadding,
                y: badgeOrigin.y + badgePadding / 2
            ),
            withAttributes: attributes
        )
    }

    // MARK: - Coordinate Transforms

    /// Convert overlay-view rect to normalized PDF coordinates (0–1, bottom-left origin).
    func overlayToPDFNormalized(_ rect: CGRect) -> CGRect {
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return .zero }
        return CGRect(
            x: rect.minX / w,
            y: 1.0 - (rect.maxY / h),   // Flip Y: UIKit top-left -> PDF bottom-left
            width: rect.width / w,
            height: rect.height / h
        )
    }

    /// Convert normalized PDF coordinates back to overlay-view rect.
    func pdfNormalizedToOverlay(_ normalized: CGRect) -> CGRect {
        let w = bounds.width
        let h = bounds.height
        return CGRect(
            x: normalized.minX * w,
            y: (1.0 - normalized.minY - normalized.height) * h,  // Flip Y back
            width: normalized.width * w,
            height: normalized.height * h
        )
    }

    // MARK: - Snap Engine

    /// Collect all snap guide positions from other regions, page margins, and page center.
    /// `excluding` omits the region being moved/drawn so it doesn't snap to itself.
    private func collectGuideTargets(excluding excludeID: UUID?) -> (horizontal: [CGFloat], vertical: [CGFloat]) {
        // Return cached targets if available and exclude ID matches.
        // Safe because regions cannot change during a drag (isActivelyDragging blocks configure).
        if let cached = cachedGuideTargets, cachedGuideExcludeID == excludeID {
            return cached
        }

        var hTargets: [CGFloat] = []
        var vTargets: [CGFloat] = []

        // Other region edges and centers
        for region in regions where region.id != excludeID {
            let rect = pdfNormalizedToOverlay(region.normalizedRect)
            hTargets.append(contentsOf: [rect.minY, rect.midY, rect.maxY])
            vTargets.append(contentsOf: [rect.minX, rect.midX, rect.maxX])
        }

        // Page margins (16pt inset)
        let margin = ResectaTokens.Snap.pageMarginInset
        hTargets.append(contentsOf: [margin, bounds.height - margin])
        vTargets.append(contentsOf: [margin, bounds.width - margin])

        // Page center lines
        hTargets.append(bounds.height / 2)
        vTargets.append(bounds.width / 2)

        cachedGuideTargets = (hTargets, vTargets)
        cachedGuideExcludeID = excludeID
        return (hTargets, vTargets)
    }

    /// Apply snapping to a rect. Returns the adjusted rect; populates `activeGuides`.
    /// Fires snap haptic when new guides appear.
    private func applySnapping(to rect: CGRect, excluding excludeID: UUID?) -> CGRect {
        let threshold = ResectaTokens.Snap.proximityThreshold
        let (hTargets, vTargets) = collectGuideTargets(excluding: excludeID)

        var result = rect
        var guides: [SnapGuide] = []
        var snappedPositions: Set<CGFloat> = []

        // Horizontal snapping (Y positions): top edge, center, bottom edge
        let yEdges: [(CGFloat, (CGFloat) -> CGFloat)] = [
            (result.minY, { dy in result.origin.y += dy; return result.minY }),
            (result.midY, { dy in result.origin.y += dy; return result.midY }),
            (result.maxY, { dy in result.origin.y += dy; return result.maxY }),
        ]
        for (edgeY, _) in yEdges {
            if let nearest = hTargets.min(by: { abs($0 - edgeY) < abs($1 - edgeY) }),
               abs(nearest - edgeY) <= threshold {
                let dy = nearest - edgeY
                result.origin.y += dy
                guides.append(SnapGuide(position: nearest, isHorizontal: true))
                snappedPositions.insert(nearest)
                break  // Only snap one horizontal edge per frame
            }
        }

        // Vertical snapping (X positions): left edge, center, right edge
        let xEdges: [(CGFloat, (CGFloat) -> CGFloat)] = [
            (result.minX, { dx in result.origin.x += dx; return result.minX }),
            (result.midX, { dx in result.origin.x += dx; return result.midX }),
            (result.maxX, { dx in result.origin.x += dx; return result.maxX }),
        ]
        for (edgeX, _) in xEdges {
            if let nearest = vTargets.min(by: { abs($0 - edgeX) < abs($1 - edgeX) }),
               abs(nearest - edgeX) <= threshold {
                let dx = nearest - edgeX
                result.origin.x += dx
                guides.append(SnapGuide(position: nearest, isHorizontal: false))
                snappedPositions.insert(nearest)
                break  // Only snap one vertical edge per frame
            }
        }

        // Fire haptic only when new guides appear
        let newPositions = snappedPositions.subtracting(previousGuideSet)
        if !newPositions.isEmpty {
            snapFeedback.impactOccurred(intensity: 0.4)
            // VoiceOver announcement — gated to avoid throttling during drag
            if UIAccessibility.isVoiceOverRunning {
                UIAccessibility.post(notification: .announcement,
                                     argument: "Aligned to guide")
            }
        }
        previousGuideSet = snappedPositions
        activeGuides = guides

        return result
    }

    /// Apply snapping to a resize operation. Only snaps the edges that are being moved.
    private func applyResizeSnapping(to rect: CGRect, handle: ResizeHandle, excluding excludeID: UUID?) -> CGRect {
        let threshold = ResectaTokens.Snap.proximityThreshold
        let (hTargets, vTargets) = collectGuideTargets(excluding: excludeID)

        var result = rect
        var guides: [SnapGuide] = []
        var snappedPositions: Set<CGFloat> = []

        // Determine which edges move for this handle
        let movesTop = [.topLeft, .topRight, .topCenter].contains(handle)
        let movesBottom = [.bottomLeft, .bottomRight, .bottomCenter].contains(handle)
        let movesLeft = [.topLeft, .bottomLeft, .leftCenter].contains(handle)
        let movesRight = [.topRight, .bottomRight, .rightCenter].contains(handle)

        // Snap moving horizontal edges
        if movesTop, let nearest = hTargets.min(by: { abs($0 - result.minY) < abs($1 - result.minY) }),
           abs(nearest - result.minY) <= threshold {
            let dy = nearest - result.minY
            result.origin.y += dy
            result.size.height -= dy
            guides.append(SnapGuide(position: nearest, isHorizontal: true))
            snappedPositions.insert(nearest)
        }
        if movesBottom, let nearest = hTargets.min(by: { abs($0 - result.maxY) < abs($1 - result.maxY) }),
           abs(nearest - result.maxY) <= threshold {
            result.size.height += nearest - result.maxY
            guides.append(SnapGuide(position: nearest, isHorizontal: true))
            snappedPositions.insert(nearest)
        }

        // Snap moving vertical edges
        if movesLeft, let nearest = vTargets.min(by: { abs($0 - result.minX) < abs($1 - result.minX) }),
           abs(nearest - result.minX) <= threshold {
            let dx = nearest - result.minX
            result.origin.x += dx
            result.size.width -= dx
            guides.append(SnapGuide(position: nearest, isHorizontal: false))
            snappedPositions.insert(nearest)
        }
        if movesRight, let nearest = vTargets.min(by: { abs($0 - result.maxX) < abs($1 - result.maxX) }),
           abs(nearest - result.maxX) <= threshold {
            result.size.width += nearest - result.maxX
            guides.append(SnapGuide(position: nearest, isHorizontal: false))
            snappedPositions.insert(nearest)
        }

        let newPositions = snappedPositions.subtracting(previousGuideSet)
        if !newPositions.isEmpty {
            snapFeedback.impactOccurred(intensity: 0.4)
        }
        previousGuideSet = snappedPositions
        activeGuides = guides

        return result
    }

    // MARK: - Handle Animation

    /// Animate resize handles appearing (selection gained).
    /// Duration sourced from `ResectaTokens.Anim.selectionInDuration`;
    /// Reduce Motion bypasses the CADisplayLink path and snaps to the target
    /// scale immediately, matching the `Anim.resolved` posture used by the
    /// SwiftUI surfaces.
    private func animateHandlesIn() {
        if UIAccessibility.isReduceMotionEnabled {
            handleScale = 1.0
            setNeedsDisplay()
            return
        }
        handleAnimFromScale = handleScale
        handleAnimTargetScale = 1.0
        handleAnimDuration = ResectaTokens.Anim.selectionInDuration
        startHandleAnimation()
    }

    /// Animate resize handles disappearing (selection lost).
    /// See `animateHandlesIn` for the Reduce-Motion posture.
    private func animateHandlesOut() {
        if UIAccessibility.isReduceMotionEnabled {
            handleScale = 0.0
            setNeedsDisplay()
            return
        }
        handleAnimFromScale = handleScale
        handleAnimTargetScale = 0.0
        handleAnimDuration = ResectaTokens.Anim.selectionOutDuration
        startHandleAnimation()
    }

    private func startHandleAnimation() {
        handleDisplayLink?.invalidate()
        handleAnimStartTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(handleAnimationTick))
        // ProMotion: allow 120Hz on capable devices for smoother handle animation
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        handleDisplayLink = link
    }

    @objc private func handleAnimationTick(_ link: CADisplayLink) {
        let elapsed = CACurrentMediaTime() - handleAnimStartTime
        var t = min(elapsed / handleAnimDuration, 1.0)
        // Ease-out cubic: 1 - (1-t)^3
        t = 1.0 - pow(1.0 - t, 3)
        handleScale = handleAnimFromScale + (handleAnimTargetScale - handleAnimFromScale) * CGFloat(t)
        setNeedsDisplay()
        if elapsed >= handleAnimDuration {
            handleScale = handleAnimTargetScale
            link.invalidate()
            handleDisplayLink = nil
        }
    }

    override func removeFromSuperview() {
        handleDisplayLink?.invalidate()
        handleDisplayLink = nil
        // PDFView's overlay-recycling can drop the view mid-long-press; the
        // scheduled Timer otherwise retains itself on the runloop until fire.
        cancelLongPress()
        // Drop in-progress polygon vertices when the
        // overlay is recycled or the editor closes mid-polygon. The
        // per-overlay vertex list dies with the view, but the shared
        // `inProgressPolygonVertexCount` on `RedactionState` would
        // otherwise leak the stale count into the next overlay's capsule.
        discardInProgressPolygon()
        super.removeFromSuperview()
    }

    // MARK: - Dimension Label

    /// Draw a dimension label (W x H) near the bottom-right of a rect.
    /// Small regions (<40pt tall) prefer above so the label
    /// doesn't crowd a thin strip from below; taller regions retain the
    /// legacy below posture. When neither above nor below has room inside
    /// the overlay, the label is suppressed rather than clamped on top
    /// of the region.
    private func drawDimensionLabel(ctx: CGContext, rect: CGRect) {
        let text = "\(Int(rect.width)) \u{00D7} \(Int(rect.height))" as NSString
        let font = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.label,
        ]
        let textSize = text.size(withAttributes: attributes)
        let padding: CGFloat = 4
        let pillSize = CGSize(
            width: textSize.width + padding * 2,
            height: textSize.height + padding
        )

        let position = Self.dimensionLabelPosition(
            regionRect: rect,
            pillHeight: pillSize.height,
            overlayHeight: bounds.height
        )

        let pillY: CGFloat
        switch position {
        case .suppressed:
            return
        case .above(let y), .below(let y):
            pillY = y
        }

        // Horizontal: align to the right edge of the region, clamped to
        // overlay bounds so the pill never spills past the left/right edge.
        let rawX = rect.maxX - pillSize.width
        let pillOrigin = CGPoint(
            x: max(0, min(rawX, bounds.width - pillSize.width)),
            y: pillY
        )

        let pillRect = CGRect(origin: pillOrigin, size: pillSize)

        // Background pill
        let pillPath = UIBezierPath(roundedRect: pillRect, cornerRadius: 4)
        ctx.saveGState()
        ctx.setFillColor(UIColor.systemBackground.withAlphaComponent(0.85).cgColor)
        ctx.addPath(pillPath.cgPath)
        ctx.fillPath()
        ctx.restoreGState()

        // Text
        text.draw(
            at: CGPoint(x: pillOrigin.x + padding, y: pillOrigin.y + padding / 2),
            withAttributes: attributes
        )
    }

    /// Draw active snap guide lines spanning the full overlay.
    private func drawSnapGuides(ctx: CGContext) {
        guard !activeGuides.isEmpty else { return }

        ctx.saveGState()
        ctx.setStrokeColor(ResectaTokens.Snap.guideColor.cgColor)
        ctx.setLineWidth(ResectaTokens.Snap.guideLineWidth)
        ctx.setLineDash(phase: 0, lengths: [])

        for guide in activeGuides {
            if guide.isHorizontal {
                ctx.move(to: CGPoint(x: 0, y: guide.position))
                ctx.addLine(to: CGPoint(x: bounds.width, y: guide.position))
            } else {
                ctx.move(to: CGPoint(x: guide.position, y: 0))
                ctx.addLine(to: CGPoint(x: guide.position, y: bounds.height))
            }
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Draw a thin tick segment for each active text-edge snap.
    /// Visual affordance — the tick traces the snapped edge of the
    /// in-progress rect so the user sees which edge clipped to OCR text.
    /// Uses the existing snap-guide color so the visual vocabulary stays
    /// uniform with the region-edge snap; 1pt line width keeps it
    /// subordinate to the rubber-band rect.
    private func drawTextSnapTicks(ctx: CGContext) {
        guard !activeTextSnapTicks.isEmpty else { return }

        ctx.saveGState()
        ctx.setStrokeColor(ResectaTokens.Snap.guideColor.cgColor)
        ctx.setLineWidth(1.0)
        ctx.setLineDash(phase: 0, lengths: [])

        for tick in activeTextSnapTicks {
            ctx.move(to: tick.start)
            ctx.addLine(to: tick.end)
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: - Accessibility

    override var isAccessibilityElement: Bool {
        get { false }  // Container, not a direct element
        set { _ = newValue }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        cachedAccessibilityElements = nil
    }

    override var accessibilityElements: [Any]? {
        get {
            if let cached = cachedAccessibilityElements { return cached }
            var elements: [UIAccessibilityElement] = regions.enumerated().map { index, region in
                makeAccessibilityElement(for: region, index: index)
            }
            // Search highlight accessibility elements (read-only)
            for highlight in searchHighlights {
                let element = UIAccessibilityElement(accessibilityContainer: self)
                let viewRect = pdfNormalizedToOverlay(highlight.normalizedRect)
                element.accessibilityFrame = UIAccessibility.convertToScreenCoordinates(viewRect, in: self)
                // NEVER include matched text — announce page only
                element.accessibilityLabel = "Search highlight, page \(pageIndex + 1)"
                element.accessibilityTraits = .staticText
                elements.append(element)
            }
            cachedAccessibilityElements = elements
            return elements
        }
        set { _ = newValue }
    }

    private func makeAccessibilityElement(
        for region: RedactionRegion, index: Int
    ) -> UIAccessibilityElement {
        let element = UIAccessibilityElement(accessibilityContainer: self)
        let viewRect = pdfNormalizedToOverlay(region.normalizedRect)
        element.accessibilityFrame = UIAccessibility.convertToScreenCoordinates(viewRect, in: self)

        // Numbered label — "Redaction region N"
        element.accessibilityLabel = "Redaction region \(index + 1)"

        // Value describes the region source type
        element.accessibilityValue = accessibilityValue(for: region)

        // Hint based on selection state
        let isSelected = region.id == selectedID
        element.accessibilityHint = isSelected
            ? "Selected. Use delete to remove."
            : "Double tap to select."

        element.accessibilityTraits = .button

        // Custom delete action for selected regions
        if isSelected {
            element.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: "Delete region") { [weak self] _ in
                    self?.coordinator?.deleteRegion(region.id, page: self?.pageIndex ?? 0)
                    return true
                }
            ]
        }

        return element
    }

    // Accessible description by region source.
    // Appends confidence from metadata when available.
    // Security: matchedText is NOT included in VoiceOver announcements.
    private func accessibilityValue(for region: RedactionRegion) -> String {
        let base: String = switch region.source {
        case .manual: "Manual redaction region"
        case .detectedPII(let kind, _): "Detected \(kind.accessibilityName)"
        case .detectedFace: "Detected face region"
        case .searchMatch: "Search match redaction region"
        }

        if let metadata = coordinator?.redactionState?.regionMetadata[region.id] {
            let conf = Int(metadata.confidence * 100)
            return "\(base), \(conf)% confidence"
        }
        return base
    }
}

// MARK: - Context Menu

extension RedactionOverlayView: UIContextMenuInteractionDelegate {

    /// Return the OCR word whose normalized bounding box
    /// contains the given overlay-space point. Returns nil when no
    /// word is hit or when the OCR cache hasn't been populated for
    /// the page. Pure helper so `MagicWandUITests` can pin the gating
    /// contract without touching `UIContextMenuInteraction`. The
    /// hit-test runs in overlay space (top-left origin) —
    /// `pdfNormalizedToOverlay` flips the Y axis so the rect aligns
    /// with UIKit touch coordinates.
    func hitTestOCRWord(at point: CGPoint) -> OCRWord? {
        guard !ocrWords.isEmpty else { return nil }
        for word in ocrWords {
            let overlayRect = pdfNormalizedToOverlay(word.normalizedRect)
            if overlayRect.contains(point) { return word }
        }
        return nil
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        // When no region is at the touch point but an OCR word is,
        // surface the magic-wand "Select all instances" menu (gated on hit).
        // Existing region menu still wins when both are present so the
        // user can still operate on a region they long-pressed on top of.
        if hitTestRegion(at: location) == nil,
           let ocrWord = hitTestOCRWord(at: location) {
            return makeMagicWandMenuConfiguration(for: ocrWord)
        }

        guard let region = hitTestRegion(at: location) else { return nil }

        // Select the region when showing its context menu
        coordinator?.selectRegion(region.id)

        return UIContextMenuConfiguration(actionProvider: { _ in
            var actions: [UIMenuElement] = []

            // Region info item (disabled — display only).
            // Only for detected regions with metadata.
            if region.source != .manual,
               let metadata = self.coordinator?.redactionState?.regionMetadata[region.id] {
                let infoAction = UIAction(
                    title: metadata.accessibilityDescription,
                    image: UIImage(systemName: "info.circle"),
                    attributes: .disabled
                ) { _ in }
                actions.append(infoAction)
            }

            // Select All on Page
            let selectAllAction = UIAction(
                title: "Select All on Page",
                image: UIImage(systemName: "checkmark.circle")
            ) { [weak self] _ in
                guard let self,
                      let regions = self.coordinator?.redactionState?.regions[self.pageIndex]
                else { return }
                self.coordinator?.redactionState?.selectedRegionIDs = Set(regions.map(\.id))
            }
            actions.append(selectAllAction)

            // Deselect (only when tapped region is selected)
            if self.selectedIDs.contains(region.id) {
                let deselectAction = UIAction(
                    title: "Deselect",
                    image: UIImage(systemName: "xmark.circle")
                ) { [weak self] _ in
                    self?.coordinator?.redactionState?.selectedRegionIDs.remove(region.id)
                }
                actions.append(deselectAction)
            }

            // Duplicate Region — long-press menu item that copies
            // the region with a small offset (clamped into page bounds by
            // `RedactionState.duplicateRegion`). Action name "Duplicate
            // Redaction" surfaces in the iOS long-press Undo menu per the
            // existing "<verb> Redaction" pattern.
            let duplicateAction = UIAction(
                title: "Duplicate Region",
                image: UIImage(systemName: "plus.square.on.square")
            ) { [weak self] _ in
                guard let self else { return }
                self.coordinator?.redactionState?.duplicateRegion(
                    region.id, page: self.pageIndex,
                    undoManager: self.window?.undoManager
                )
                self.coordinator?.refreshOverlay(for: self.pageIndex)
            }
            actions.append(duplicateAction)

            // View rationale — gated on the
            // region's `Source` carrying a non-nil `MatchRationale`.
            // Mirrors the iPad popover's disclosure visibility so the
            // menu density stays at the existing cap when no
            // rationale data exists. Action routes through
            // `pendingCanvasRationaleRequest` for sheet presentation on
            // `DocumentEditorView`, same pattern as Tag Exemption above.
            if RedactionOverlayView.rationaleMenuShouldShow(region: region) {
                let rationaleAction = UIAction(
                    title: "View Rationale",
                    image: UIImage(systemName: "doc.text.magnifyingglass")
                ) { [weak self] _ in
                    self?.coordinator?.redactionState?
                        .pendingCanvasRationaleRequest = region.id
                }
                actions.append(rationaleAction)
            }

            // Delete action
            let deleteAction = UIAction(
                title: "Delete Region",
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { [weak self] _ in
                guard let self else { return }
                self.coordinator?.deleteRegion(region.id, page: self.pageIndex)
            }
            actions.append(deleteAction)

            return UIMenu(children: actions)
        })
    }

    /// Build the magic-wand context menu for a long-pressed OCR
    /// word. The menu reads "Select all instances" and routes through
    /// `RedactionState.pendingMagicWandRequest` so the host view can
    /// open the search sheet pre-filled with an exact-match search.
    /// Regex specials in the hit word are escaped at this call site —
    /// the engine accepts the raw term and
    /// does not regex-escape inside the runtime.
    private func makeMagicWandMenuConfiguration(
        for ocrWord: OCRWord
    ) -> UIContextMenuConfiguration {
        UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self else { return UIMenu(children: []) }
            let escapedTerm = RedactionOverlayView.escapeRegexSpecials(in: ocrWord.text)
            let action = UIAction(
                title: "Select all instances",
                image: UIImage(systemName: "wand.and.stars")
            ) { [weak self] _ in
                guard let self else { return }
                let request = MagicWandSearchRequest(
                    rawTerm: ocrWord.text,
                    escapedTerm: escapedTerm
                )
                self.coordinator?.redactionState?.pendingMagicWandRequest = request
            }
            return UIMenu(children: [action])
        })
    }

    /// Escape the regex metacharacters that
    /// `NSRegularExpression.escapedPattern(for:)` would handle, so a hit
    /// word like `C++` matches the literal sequence and not a regex
    /// (regex-escape at the call site, not in
    /// the engine runtime). The engine's text path uses literal
    /// substring matching so the escape is belt-and-suspenders — kept
    /// because the design keeps the escape responsibility on
    /// the caller, and a future routing change in the engine must not
    /// silently break the magic-wand contract.
    static func escapeRegexSpecials(in term: String) -> String {
        NSRegularExpression.escapedPattern(for: term)
    }
}

/// Payload carried by `RedactionState.pendingMagicWandRequest`
/// when the canvas long-press menu fires "Select all instances".
/// `rawTerm` preserves the user-visible text; `escapedTerm` is the
/// regex-escaped form to feed into the search engine via
/// `SearchMode.text(escapedTerm, options:)` with `exactMatch = true`.
struct MagicWandSearchRequest: Equatable, Sendable {
    let rawTerm: String
    let escapedTerm: String
}
