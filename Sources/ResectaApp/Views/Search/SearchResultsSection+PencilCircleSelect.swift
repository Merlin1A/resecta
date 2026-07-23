import SwiftUI
import UIKit

// Apple Pencil circle-to-select on search-results
// rows. Pencil-only gesture (touch-type filtered via UIKit) that lets
// the user draw a closed loop around several rows; on release the
// enclosed rows are toggled into the selection. Finger drags fall
// through untouched to the List's native scroll / select behavior.
//
// The geometry helpers (`isClosedLoop`, `shoelaceArea`, `isPointInPolygon`,
// `isRowEnclosed`) and the touch-source discriminator (`isPencilEvent`)
// are pure functions on `SearchResultsSection` so the gating contract is
// testable without a UIView host. The actual gesture wiring lives in
// `PencilCircleSelectOverlay` (UIViewRepresentable) below.
//
// The gesture-conflict matrix is the load-bearing
// sub-deliverable.
// iOS 26 Pencil API stability — `UIPanGestureRecognizer`
// with `allowedTouchTypes = [.pencil]` is a stable surface from
// pre-iOS 13 and continues to work on iOS 26. The wider feature is
// guarded by `#available(iOS 26, *)` per the kickoff so future iOS
// versions can swap in `SpatialEventGesture` without breaking the
// shipped path.

extension SearchResultsSection {

    // MARK: - Pure predicates

    /// Closed-loop recognizer. Returns true when:
    /// 1. The path has at least 3 points (degenerate loops are rejected).
    /// 2. The start and end points lie within `closeDistance` of each
    ///    other (the user came back to the start).
    /// 3. The enclosed area exceeds `minArea` (filters out tiny
    ///    accidental loops).
    ///
    /// Distances are in points; area in square points. Defaults are
    /// tuned for finger-comfortable Pencil writing (40pt close radius,
    /// 400 sq-pt minimum area ≈ a 20pt square). Pinned by
    /// `PencilCircleSelectTests.isClosedLoop*`.
    static func isClosedLoop(
        path: [CGPoint],
        closeDistance: CGFloat = 40,
        minArea: CGFloat = 400
    ) -> Bool {
        guard path.count >= 3 else { return false }
        guard let start = path.first, let end = path.last else { return false }
        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance <= closeDistance else { return false }
        return shoelaceArea(path: path) >= minArea
    }

    /// Shoelace-formula polygon area. Returns the unsigned area, so
    /// clockwise and counterclockwise loops produce the same result.
    /// Pure function — pinned by `PencilCircleSelectTests.shoelace*`.
    static func shoelaceArea(path: [CGPoint]) -> CGFloat {
        guard path.count >= 3 else { return 0 }
        var sum: CGFloat = 0
        for i in 0..<path.count {
            let j = (i + 1) % path.count
            sum += path[i].x * path[j].y
            sum -= path[j].x * path[i].y
        }
        return abs(sum) / 2
    }

    /// Point-in-polygon via ray casting. Returns true if `point` lies
    /// inside the polygon described by `polygon`. The polygon is
    /// treated as closed even if the final vertex doesn't repeat the
    /// first. Pure function — pinned by
    /// `PencilCircleSelectTests.isPointInPolygon*`.
    static func isPointInPolygon(
        point: CGPoint,
        polygon: [CGPoint]
    ) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let xi = polygon[i].x, yi = polygon[i].y
            let xj = polygon[j].x, yj = polygon[j].y
            let intersects = (yi > point.y) != (yj > point.y) &&
                point.x < (xj - xi) * (point.y - yi) / (yj - yi) + xi
            if intersects { inside.toggle() }
            j = i
        }
        return inside
    }

    /// Row inclusion test: a row is enclosed when its centroid sits
    /// inside the loop. Centroid (rather than full-rect intersection)
    /// keeps the selection threshold predictable for partial overlaps —
    /// the user's loop only needs to cross more than half the row's
    /// vertical extent to grab it. Pinned by
    /// `PencilCircleSelectTests.isRowEnclosed*`.
    static func isRowEnclosed(
        rowFrame: CGRect,
        loop: [CGPoint]
    ) -> Bool {
        let centroid = CGPoint(x: rowFrame.midX, y: rowFrame.midY)
        return isPointInPolygon(point: centroid, polygon: loop)
    }

    /// Touch-source discrimination: only `UITouch.TouchType.pencil`
    /// drives circle-to-select. Finger and indirect touches fall
    /// through to the List's native scroll / select gestures. Pure
    /// function — pinned by
    /// `PencilCircleSelectTests.isPencilEvent*`.
    static func isPencilEvent(touchType: UITouch.TouchType) -> Bool {
        touchType == .pencil
    }

    /// SA-1 (D-71) stroke-lifecycle gate transition for the row-frame
    /// tracking gate: `.began` activates tracking, terminal states
    /// (`.ended`/`.cancelled`/`.failed`) deactivate it, and
    /// mid-stroke / idle states leave it unchanged (nil). Keeping the
    /// mapping a pure function splits gate policy from the UIKit
    /// wiring, matching the predicates above. Pinned by
    /// `PencilCircleSelectTests.strokeGate*`.
    static func pencilStrokeGateTransition(
        for state: UIGestureRecognizer.State
    ) -> Bool? {
        switch state {
        case .began:
            return true
        case .ended, .cancelled, .failed:
            return false
        case .possible, .changed:
            return nil
        @unknown default:
            return nil
        }
    }

    /// Selection-effect computation: given the closed loop and a map
    /// of row frames keyed by result UUID, return the set of row IDs
    /// to toggle. Splits selection-policy from gesture-mechanics so
    /// future variants (toggle vs. replace) can adjust here without
    /// touching the UIView layer. Pinned by
    /// `PencilCircleSelectTests.enclosedRowIDs*`.
    static func enclosedRowIDs(
        loop: [CGPoint],
        rowFrames: [UUID: CGRect]
    ) -> Set<UUID> {
        var enclosed: Set<UUID> = []
        for (id, frame) in rowFrames {
            if isRowEnclosed(rowFrame: frame, loop: loop) {
                enclosed.insert(id)
            }
        }
        return enclosed
    }
}

// MARK: - UIKit Gesture Recognizer (Pencil-only)

/// Pencil-only pan recognizer. Filters touches via
/// `allowedTouchTypes` so finger drags never trigger the circle
/// gesture; the SwiftUI List's native scroll / row-tap path keeps
/// working for finger input. The recognizer tracks the path in its
/// own coordinate space; the host overlay translates points to the
/// SwiftUI coordinate space at callback time.
@MainActor
final class PencilCircleSelectGestureRecognizer: UIPanGestureRecognizer {
    private(set) var pathPoints: [CGPoint] = []

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        // Pencil-only filter. `UITouch.TouchType.pencil.rawValue`
        // boxes through `NSNumber`. Indirect / finger events are
        // ignored by the recognizer — they fall through to whatever
        // is below (typically the List's scroll recognizer).
        self.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        // The circle gesture should not start unless the user
        // actually moved — a static Pencil-down is a contextMenu
        // long-press, not a circle. Pan recognizer's default
        // minimum-translation behavior matches this.
        self.maximumNumberOfTouches = 1
        self.minimumNumberOfTouches = 1
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        pathPoints.removeAll()
        if let touch = touches.first {
            pathPoints.append(touch.location(in: view))
        }
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first {
            pathPoints.append(touch.location(in: view))
        }
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first {
            pathPoints.append(touch.location(in: view))
        }
        super.touchesEnded(touches, with: event)
    }

    override func reset() {
        super.reset()
        pathPoints.removeAll()
    }
}

// MARK: - SwiftUI Overlay

/// SwiftUI overlay that hosts a transparent UIView with the
/// Pencil-only gesture recognizer. Finger touches pass through to the
/// view hierarchy below (the List); Pencil drags activate
/// `PencilCircleSelectGestureRecognizer` and accumulate a path. On
/// gesture end, the overlay calls `onLoopClose(_:)` with the captured
/// path so the host can compute enclosed rows.
///
/// iOS 26 API stability: the recognizer path uses pre-26
/// UIKit APIs (`allowedTouchTypes`, `UIPanGestureRecognizer`) that
/// remain stable across the iOS 26 surface. The `#available(iOS 26, *)`
/// gate in the modifier consumer guards future iOS-version-specific
/// behavior — currently a no-op since the deployment target is iOS 26.
struct PencilCircleSelectOverlay: UIViewRepresentable {
    var onLoopClose: ([CGPoint]) -> Void
    /// SA-1: stroke-lifecycle callback driving the host's row-frame
    /// tracking gate — true on `.began`, false on terminal states, per
    /// `SearchResultsSection.pencilStrokeGateTransition(for:)`.
    var onStrokeActiveChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onLoopClose: onLoopClose,
            onStrokeActiveChanged: onStrokeActiveChanged
        )
    }

    func makeUIView(context: Context) -> UIView {
        let view = PencilTouchPassthroughView()
        let recognizer = PencilCircleSelectGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        // Hit-test regression fix: the recognizer is NOT attached
        // to this overlay view. An attached full-size overlay must win
        // hit-testing to feed its recognizer, and that stole every
        // finger tap over the results list (row taps + finger scroll
        // were silent no-ops; a synthesized tap dead-center on a row
        // never reached the row's tap gesture). Instead the view hands
        // the recognizer to its UIWindow when it enters one —
        // `allowedTouchTypes = [.pencil]` filters at the recognizer
        // layer, so finger touches proceed to the List untouched while
        // Pencil pans still drive the circle gesture.
        view.hostedRecognizer = recognizer
        context.coordinator.recognizer = recognizer
        context.coordinator.overlayView = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Closure capture refresh — the host may pass updated
        // closures between renders.
        context.coordinator.onLoopClose = onLoopClose
        context.coordinator.onStrokeActiveChanged = onStrokeActiveChanged
    }

    @MainActor
    final class Coordinator: NSObject {
        var onLoopClose: ([CGPoint]) -> Void
        var onStrokeActiveChanged: (Bool) -> Void
        weak var recognizer: PencilCircleSelectGestureRecognizer?
        /// The overlay view, used to convert the recognizer's
        /// window-space path into overlay-local coordinates — the
        /// overlay spans the List, so overlay-local equals the named
        /// coordinate space the row frames are tracked in.
        weak var overlayView: UIView?

        init(
            onLoopClose: @escaping ([CGPoint]) -> Void,
            onStrokeActiveChanged: @escaping (Bool) -> Void
        ) {
            self.onLoopClose = onLoopClose
            self.onStrokeActiveChanged = onStrokeActiveChanged
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            if recognizer.state == .ended,
               let pencilRecognizer = recognizer as? PencilCircleSelectGestureRecognizer {
                // The recognizer lives on the UIWindow (see
                // `PencilTouchPassthroughView`), so its path is in window
                // coordinates; convert to overlay-local before handing to
                // the SwiftUI host, whose row frames resolve in the named
                // coordinate space anchored at the List boundary.
                let path: [CGPoint]
                if let overlayView, let window = overlayView.window {
                    path = pencilRecognizer.pathPoints.map {
                        overlayView.convert($0, from: window)
                    }
                } else {
                    path = pencilRecognizer.pathPoints
                }
                onLoopClose(path)
            }
            // SA-1: dispatch the stroke gate AFTER any loop-close so the
            // logical order reads "finish the stroke, then drop
            // tracking". Both callbacks are synchronous state writes;
            // the render that unmounts the GeometryReaders happens
            // afterward, so the modifier's render-time `rowFrames`
            // capture is still populated when `onLoopClose` computes
            // enclosure.
            if let active = SearchResultsSection.pencilStrokeGateTransition(
                for: recognizer.state
            ) {
                onStrokeActiveChanged(active)
            }
        }
    }
}

/// Transparent host for the Pencil circle-select recognizer. The view
/// itself NEVER participates in hit-testing — the original
/// implementation returned `super.hitTest` unless `event.allTouches`
/// carried a non-Pencil touch, but `allTouches` is nil during
/// hit-testing, so the full-size overlay claimed every finger touch
/// over the results list and row taps / finger scrolls died in its
/// Pencil-only recognizer. Instead the recognizer is attached to the
/// UIWindow while the view is in one: window-level recognizers see all
/// touches, `allowedTouchTypes = [.pencil]` filters to Pencil, and
/// finger touches flow to the List as if this overlay didn't exist.
@MainActor
final class PencilTouchPassthroughView: UIView {
    /// Recognizer to host on the window. Set once by `makeUIView`
    /// before the view enters a window.
    var hostedRecognizer: UIGestureRecognizer?
    private weak var attachedWindow: UIWindow?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard attachedWindow !== window else { return }
        if let hostedRecognizer, let attachedWindow {
            attachedWindow.removeGestureRecognizer(hostedRecognizer)
        }
        attachedWindow = window
        if let hostedRecognizer, let window {
            window.addGestureRecognizer(hostedRecognizer)
        }
    }
}

// MARK: - SwiftUI Modifier

/// Ergonomic ViewModifier that pairs the
/// `PencilCircleSelectOverlay` with a closure that converts a
/// completed path into a selection effect. The host applies this
/// modifier to the rows surface; the modifier handles the closed-loop
/// recognition and dispatches the enclosed-row set back to the host's
/// selection mutator.
struct PencilCircleSelectModifier: ViewModifier {
    var rowFrames: [UUID: CGRect]
    var onStrokeActiveChanged: (Bool) -> Void
    var onSelectionLoop: (Set<UUID>) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.overlay(
                PencilCircleSelectOverlay(
                    onLoopClose: { path in
                        guard SearchResultsSection.isClosedLoop(path: path) else { return }
                        let enclosed = SearchResultsSection.enclosedRowIDs(
                            loop: path,
                            rowFrames: rowFrames
                        )
                        if !enclosed.isEmpty {
                            onSelectionLoop(enclosed)
                        }
                    },
                    onStrokeActiveChanged: onStrokeActiveChanged
                )
            )
        } else {
            content
        }
    }
}

extension View {
    /// Attach the Pencil circle-to-select overlay to a view.
    /// `rowFrames` is the host-maintained dictionary of row id →
    /// frame in the modifier's coordinate space. `onStrokeActiveChanged`
    /// reports the recognizer's stroke lifecycle (SA-1 — the host
    /// gates its row-frame tracking on it). `onSelectionLoop`
    /// is invoked with the set of enclosed row IDs after a valid
    /// closed loop completes (start/end within 40pt, area ≥ 400
    /// sq-pt).
    func pencilCircleSelect(
        rowFrames: [UUID: CGRect],
        onStrokeActiveChanged: @escaping (Bool) -> Void,
        onSelectionLoop: @escaping (Set<UUID>) -> Void
    ) -> some View {
        modifier(PencilCircleSelectModifier(
            rowFrames: rowFrames,
            onStrokeActiveChanged: onStrokeActiveChanged,
            onSelectionLoop: onSelectionLoop
        ))
    }

    /// Per-row geometry tracker. Each result row attaches this
    /// to its background; the GeometryReader writes the row's frame
    /// (in the shared `PencilCircleSelectCoordinateSpace.name`
    /// coordinate space) into the `RowFramesPreferenceKey`. The host
    /// `SearchResultsSection.resultsList` observes the preference and
    /// updates `rowFrames` for the gesture overlay to consume.
    /// Background `Color.clear` keeps the row layout unaffected.
    /// SA-1 (D-71): the GeometryReader mounts only while `isActive` —
    /// the host's stroke gate — so the per-pixel preference
    /// re-aggregation that taxed every finger scroll exists only
    /// during a live Pencil stroke. Frames resolve on the render pass
    /// after the gate flips (stroke start), well before any physical
    /// loop can close.
    @ViewBuilder
    func trackRowFrameForPencilSelect(id: UUID, isActive: Bool) -> some View {
        background(
            Group {
                if isActive {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: RowFramesPreferenceKey.self,
                            value: [id: proxy.frame(in: .named(PencilCircleSelectCoordinateSpace.name))]
                        )
                    }
                }
            }
        )
    }
}

/// Shared coordinate-space name for the Pencil circle-to-select
/// surface. Both the row-frame trackers and the gesture overlay
/// resolve frames against this named space so the geometry math is
/// consistent (List scroll offsets, safe-area insets, etc., all
/// resolve once at the List boundary).
enum PencilCircleSelectCoordinateSpace {
    static let name: String = "PencilCircleSelect"
}

/// SwiftUI `PreferenceKey` that aggregates per-row frames
/// upward to the List boundary. The reduce step merges new entries
/// in (last-write-wins on id collision, which can only happen if
/// two visible rows share a UUID — never the case in our model).
struct RowFramesPreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(
        value: inout [UUID: CGRect],
        nextValue: () -> [UUID: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
