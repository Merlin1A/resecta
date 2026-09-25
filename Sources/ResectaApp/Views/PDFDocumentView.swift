import SwiftUI
import PDFKit
import RedactionEngine

// PDFView wrapped in UIViewRepresentable.
// Coordinator serves as PDFPageOverlayViewProvider.
// Opaque background — no glass interference with PDF color accuracy.

struct PDFDocumentView: UIViewRepresentable {
    @Environment(DocumentState.self) private var documentState
    @Environment(RedactionState.self) private var redactionState
    @Environment(ToastQueueManager.self) private var toastManager
    // Registers the PDFViewCoordinator back-pointer so SwiftUI buttons
    // on PipelineCoordinator (Cancel / Close polygon in the bottom hint
    // capsule) can reach the polygon commit / cancel hooks that live on
    // the UIKit-side coordinator.
    @Environment(PipelineCoordinator.self) private var pipelineCoordinator

    /// Whether any drawing tool is active. Controls new-region creation.
    var isDrawingMode: Bool

    /// Which shape the active drawing tool produces (rectangle,
    /// polygon, freeform). Ignored when `isDrawingMode == false`.
    var activeShapeTool: RedactionOverlayView.ShapeTool = .rectangle

    /// iPhone "Select More" toolbar toggle. While on, a tap on a
    /// region adds to selection instead of replacing it. iPad Shift+tap
    /// continues to work whether the toggle is on or off.
    var isMultiSelectActive: Bool

    /// Rectangle-draw snap-to-text-box assist toggle. Propagated to
    /// every active overlay so the in-progress rectangle drag is
    /// nudged to align with OCR text-block edges within tolerance.
    /// Defaults to true; opt-out lives in Settings
    /// (`SettingsState.snapToTextEnabled`).
    var snapToTextEnabled: Bool = true

    // `shouldRectScroll` and `readabilityTargetScale` — the framing math
    // — live in `CanvasFraming.swift` beside the centring point.

    func makeCoordinator() -> PDFViewCoordinator {
        let coordinator = PDFViewCoordinator()
        coordinator.documentState = documentState
        coordinator.redactionState = redactionState
        coordinator.toastManager = toastManager
        // Hands the PDFViewCoordinator up to PipelineCoordinator so
        // SwiftUI polygon Cancel / Close buttons can forward through
        // the existing `@Environment(PipelineCoordinator.self)` handle.
        pipelineCoordinator.pdfViewCoordinator = coordinator
        return coordinator
    }

    func makeUIView(context: Context) -> FitFlooredPDFView {
        let pdfView = FitFlooredPDFView()
        // Opaque background prevents glass bleed-through
        pdfView.backgroundColor = .systemGroupedBackground
        // The zoom floor rides the subclass — a pinch out stops at
        // this page's fit size (see `FitFlooredPDFView`).
        pdfView.autoScales = true
        pdfView.displayMode = .singlePage
        // Enable touch routing to overlay views
        pdfView.isInMarkupMode = true

        // Set overlay provider BEFORE assigning document
        pdfView.pageOverlayViewProvider = context.coordinator
        // Link policy BEFORE assigning document: the coordinator is the
        // delegate whose link hook does nothing, so a tap on a link
        // annotation in the document opens nothing. The assignment goes
        // through the coordinator, which turns the document's data
        // detectors off (see `PDFViewCoordinator.assign(_:to:)`).
        context.coordinator.applyLinkPolicy(to: pdfView)

        context.coordinator.assign(documentState.sourceDocument, to: pdfView)

        // Navigate to current page
        if let doc = pdfView.document,
           let page = doc.page(at: documentState.currentPageIndex) {
            pdfView.go(to: page)
        }

        context.coordinator.setupObservers(for: pdfView)
        return pdfView
    }

    func updateUIView(_ pdfView: FitFlooredPDFView, context: Context) {
        let coordinator = context.coordinator

        // Update document if changed (new import). Through the
        // coordinator so the new document's data detectors are off.
        if pdfView.document !== documentState.sourceDocument {
            coordinator.assign(documentState.sourceDocument, to: pdfView)
        }

        // Sync page navigation — avoid re-navigation if already on correct page
        if let doc = pdfView.document,
           let targetPage = doc.page(at: documentState.currentPageIndex),
           pdfView.currentPage != targetPage {
            pdfView.go(to: targetPage)
        }

        // Rect-level scroll-to-match. Consume the pending target
        // exactly once (token guard on the coordinator — no state
        // write during the update pass), and only when the view is
        // zoomed past fit: at fit scale the whole page is visible,
        // page-granular navigation suffices, and an unconditional
        // `go(to:on:)` would zoom unexpectedly. The rect converts
        // through the engine's canonical
        // `normalizedToPDFPageCoordinates` — the same mapping the burn
        // path uses, so the scroll target and the drawn redaction
        // agree by construction.
        if let target = documentState.pendingCanvasScrollTarget,
           coordinator.lastHandledCanvasScrollToken != target.token {
            coordinator.lastHandledCanvasScrollToken = target.token
            // `.readability` normalizes the scale to the readability
            // target FIRST (in or out, never below the zoom floor),
            // then positions the rect per the request's anchor —
            // `.visible` rect-scrolls through the same `shouldRectScroll`
            // gate below; `.center` (the walk) centres it in the visible
            // canvas — instant, no animation. The `.none` path is
            // untouched.
            if target.zoom == .readability,
               let doc = pdfView.document,
               let page = doc.page(at: target.pageIndex) {
                let pageRect = normalizedToPDFPageCoordinates(
                    target.normalizedRect,
                    pageRect: page.bounds(for: pdfView.displayBox)
                )
                pdfView.frameForReadability(
                    rectInPage: pageRect, on: page, anchor: target.anchor)
            } else if let doc = pdfView.document,
               let page = doc.page(at: target.pageIndex),
               Self.shouldRectScroll(
                   scaleFactor: pdfView.scaleFactor,
                   fitScaleFactor: pdfView.scaleFactorForSizeToFit
               ) {
                let pageRect = normalizedToPDFPageCoordinates(
                    target.normalizedRect,
                    pageRect: page.bounds(for: pdfView.displayBox)
                )
                pdfView.go(to: pageRect, on: page)
            }
        }

        // VoiceOver label for the document editor
        pdfView.accessibilityLabel = "Document editor, page \(documentState.currentPageIndex + 1) of \(documentState.pageCount)"

        // Propagate state to coordinator
        coordinator.redactionState = redactionState
        coordinator.toastManager = toastManager
        // Re-stamp the back-pointer in case PipelineCoordinator outlived
        // a prior PDFViewCoordinator and the bridge needs to re-bind to
        // the current one (defensive — the weak ref otherwise nils
        // through reassignment).
        pipelineCoordinator.pdfViewCoordinator = coordinator
        let isEditing = documentState.phaseKind == .editing
        coordinator.updateDrawingMode(isEditing, isDrawing: isEditing && isDrawingMode)
        // Propagate the active shape tool. Reset to .rectangle when
        // drawing is off so the overlay does not retain stale state
        // (e.g., polygon vertices) after the toolbar tool deactivates.
        coordinator.updateActiveShapeTool(
            isEditing && isDrawingMode ? activeShapeTool : .rectangle
        )
        // Propagate "Select More" toggle state to overlays.
        coordinator.updateMultiSelectMode(isEditing && isMultiSelectActive)
        // Propagate snap-to-text-box toggle to overlays so the
        // rectangle drag handler observes the current Settings value
        // even when toggled mid-session.
        coordinator.updateSnapToTextEnabled(snapToTextEnabled)

        // Refresh overlays only when regions or selection actually changed
        coordinator.refreshAllOverlaysIfNeeded()
    }
}

// MARK: - Zoom floor

/// The app's `PDFView`: pinching out stops at the page's fit size.
///
/// PDFKit's own floor (`minScaleFactor`) sits far below fit, so a pinch
/// can shrink the page into the canvas background. `autoScales` only
/// picks the fit scale on load and on resize; the pinch range is governed
/// by `minScaleFactor` / `maxScaleFactor` (PDFView.h). This subclass pins
/// the floor to `scaleFactorForSizeToFit` — best fit in `.singlePage`,
/// fit width in the continuous modes — after every layout and page
/// change, so it follows the canvas bounds (the page bar and the parked
/// search sheet change them) and the current page's size. The ceiling is
/// left at PDFKit's default: zoom-in is unchanged. Pinching past the
/// floor keeps the scroll view's rubber band; nothing here runs mid
/// gesture because the fit does not move while the bounds hold still.
final class FitFlooredPDFView: PDFView {

    /// Relative tolerance for "the floor already matches fit" — narrower
    /// than `PDFDocumentView.shouldRectScroll`'s 1% because a real fit
    /// change must never be mistaken for float noise.
    static let floorTolerance: CGFloat = 0.001

    /// Set once the floor has been applied to a laid-out view. A later
    /// page change re-fits only a view that sat at the old floor (a
    /// zoomed-in view keeps its zoom, floor permitting); a resize still
    /// re-fits through `autoScales`, as it did before the floor.
    private var floorApplied = false

    // nonisolated(unsafe): written once in init (main), read once in
    // deinit (nonisolated) — the `PDFViewCoordinator` observer pattern.
    private nonisolated(unsafe) var pageChangeObserver: Any?

    override init(frame: CGRect) {
        super.init(frame: frame)
        observePageChanges()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        observePageChanges()
    }

    deinit {
        if let o = pageChangeObserver { NotificationCenter.default.removeObserver(o) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyFitFloor()
        reassertReadabilityFramingIfNeeded()
    }

    // MARK: - Readability framing

    /// The re-assert store. PDFKit with `autoScales` re-fits even a
    /// zoomed-in view when the canvas bounds change
    /// (`CanvasZoomFloorTests.floorTracksACanvasResize` pins it), and a
    /// walk step moves the bounds AFTER the consumption in
    /// `updateUIView`: the park shrinks the canvas by the compact inset
    /// (animated, so over several layout passes), and the page bar
    /// steps aside in the same step. A framing applied once against the
    /// bounds at consumption is thrown away or lands off-centre.
    /// Contract: every `.readability` consumption replaces this store;
    /// `layoutSubviews`, after `applyFitFloor()`, re-applies the framing
    /// on every pass whose bounds differ from the last applied ones,
    /// until the bounds settle — bounded by `reassertPassCap` passes and
    /// `reassertWindow` seconds per request token, after which the store
    /// expires (a later bounds change, e.g. the sheet expanding, must
    /// not re-frame a stale target). A tap with stable bounds applies
    /// once at consumption and the store expires unused.
    private struct ReadabilityFramingTarget {
        let page: PDFPage
        let rectInPage: CGRect
        let anchor: DocumentState.CanvasScrollAnchor
        let armedAt: TimeInterval
        var lastAppliedBounds: CGRect
        var passes: Int
    }

    /// The most layout passes one request token may re-apply over.
    static let reassertPassCap = 40
    /// The longest a request token stays armed after consumption.
    static let reassertWindow: TimeInterval = 0.8

    private var pendingReadabilityFraming: ReadabilityFramingTarget?

    /// Consume a `.readability` scroll target: normalize + position now,
    /// and arm the post-layout re-assert.
    func frameForReadability(
        rectInPage: CGRect, on page: PDFPage,
        anchor: DocumentState.CanvasScrollAnchor
    ) {
        applyReadabilityFraming(rectInPage: rectInPage, on: page, anchor: anchor)
        pendingReadabilityFraming = ReadabilityFramingTarget(
            page: page, rectInPage: rectInPage, anchor: anchor,
            armedAt: CACurrentMediaTime(), lastAppliedBounds: bounds, passes: 0
        )
    }

    private func reassertReadabilityFramingIfNeeded() {
        guard var pending = pendingReadabilityFraming else { return }
        guard CACurrentMediaTime() - pending.armedAt <= Self.reassertWindow,
              pending.passes < Self.reassertPassCap
        else {
            pendingReadabilityFraming = nil
            return
        }
        guard pending.lastAppliedBounds != bounds else { return }
        pending.lastAppliedBounds = bounds
        pending.passes += 1
        pendingReadabilityFraming = pending
        applyReadabilityFraming(
            rectInPage: pending.rectInPage, on: pending.page, anchor: pending.anchor)
    }

    /// Write the computed scale up or down when it differs meaningfully
    /// from the current one — the zoom floor rules out below-fit; a
    /// page-wide item from a pinched state returns to fit by design.
    /// Then position: `.visible` rect-scrolls through the existing
    /// `shouldRectScroll` gate (at fit it self-refuses and the page
    /// write alone suffices — exactly the prior behaviour); `.center`
    /// centres the rect in the visible canvas at whatever scale the
    /// rule settled on (at fit the page is smaller than the viewport
    /// and PDFKit centres the page itself).
    private func applyReadabilityFraming(
        rectInPage: CGRect, on page: PDFPage,
        anchor: DocumentState.CanvasScrollAnchor
    ) {
        let fit = scaleFactorForSizeToFit
        if let target = PDFDocumentView.readabilityTargetScale(
            rectInPage: rectInPage,
            viewportSize: bounds.size,
            fitScale: fit,
            maxScale: maxScaleFactor
        ), abs(target - scaleFactor) > ReadabilityZoom.scaleEpsilon * fit {
            scaleFactor = target
        }
        switch anchor {
        case .visible:
            guard PDFDocumentView.shouldRectScroll(
                scaleFactor: scaleFactor, fitScaleFactor: scaleFactorForSizeToFit
            ) else { return }
            // The 8-pt page-unit pad keeps the selection ring off the viewport edge.
            let padded = rectInPage
                .insetBy(dx: -8, dy: -8)
                .intersection(page.bounds(for: displayBox))
            guard !padded.isNull else { return }
            go(to: padded, on: page)
        case .center:
            centre(rectInPage, on: page)
        }
    }

    /// Centre `rectInPage` in the visible canvas at the current scale:
    /// ONE `PDFDestination` covers the page change and the position
    /// (the point is the visible area's top-left in page space, clamped
    /// to the page by `centeringDestinationPoint`). Instant; the
    /// re-assert store above rides the parked inset's animation.
    private func centre(_ rectInPage: CGRect, on page: PDFPage) {
        guard scaleFactor > 0, bounds.width > 0, bounds.height > 0 else { return }
        let point = PDFDocumentView.centeringDestinationPoint(
            rectInPage: rectInPage,
            visibleSizeInPage: CGSize(
                width: bounds.width / scaleFactor,
                height: bounds.height / scaleFactor),
            pageBounds: page.bounds(for: displayBox)
        )
        go(to: PDFDestination(page: page, at: point))
    }

    /// Pin `minScaleFactor` to the current fit scale. A no-op while the
    /// fit is unchanged, which is every layout pass a pinch triggers.
    func applyFitFloor() {
        guard document != nil, bounds.width > 0, bounds.height > 0 else { return }
        let fit = scaleFactorForSizeToFit
        guard fit > 0 else { return }
        let previousFloor = minScaleFactor
        guard abs(previousFloor - fit) > fit * Self.floorTolerance else { return }
        let satAtFloor = floorApplied
            && scaleFactor <= previousFloor * (1 + Self.floorTolerance)
        minScaleFactor = fit
        // The setter above turns `autoScales` off (PDFView.h); keep
        // PDFKit's own resize re-fit alongside the floor.
        autoScales = true
        if !floorApplied || satAtFloor || scaleFactor < fit {
            scaleFactor = fit
        }
        floorApplied = true
    }

    /// `.singlePage` fits each page on its own, so a differently sized
    /// page moves the floor. Same isolation bridge as
    /// `PDFViewCoordinator.setupObservers`.
    private func observePageChanges() {
        pageChangeObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged,
            object: self,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyFitFloor()
            }
        }
    }
}
