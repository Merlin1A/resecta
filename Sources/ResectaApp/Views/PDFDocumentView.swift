import SwiftUI
import PDFKit
import RedactionEngine

// ARCH §5.2, §5.4: PDFView wrapped in UIViewRepresentable.
// UI_UX §2.1: Coordinator serves as PDFPageOverlayViewProvider.
// UI_UX §6.1: Opaque background — no glass interference with PDF color accuracy.

struct PDFDocumentView: UIViewRepresentable {
    @Environment(DocumentState.self) private var documentState
    @Environment(RedactionState.self) private var redactionState
    @Environment(ToastQueueManager.self) private var toastManager
    // DRAW-1: needed to register the PDFViewCoordinator back-pointer
    // so SwiftUI buttons on PipelineCoordinator (Cancel / Close polygon
    // in the bottom hint capsule) can reach the polygon commit / cancel
    // hooks that live on the UIKit-side coordinator.
    @Environment(PipelineCoordinator.self) private var pipelineCoordinator

    /// Whether any drawing tool is active. Controls new-region creation.
    var isDrawingMode: Bool

    /// DRAW-1: which shape the active drawing tool produces (rectangle,
    /// polygon, freeform). Ignored when `isDrawingMode == false`.
    var activeShapeTool: RedactionOverlayView.ShapeTool = .rectangle

    /// WU-38: iPhone "Select More" toolbar toggle. While on, a tap on a
    /// region adds to selection instead of replacing it. iPad Shift+tap
    /// continues to work whether the toggle is on or off.
    var isMultiSelectActive: Bool

    /// DRAW-7: rectangle-draw snap-to-text-box assist toggle. Propagated
    /// to every active overlay so the in-progress rectangle drag is
    /// nudged to align with OCR text-block edges within tolerance.
    /// Defaults to true; opt-out lives in Settings
    /// (`SettingsState.snapToTextEnabled`).
    var snapToTextEnabled: Bool = true

    /// SA-3 rider (D-70): rect-level scroll fires only when the view
    /// is zoomed meaningfully past fit — at (or under) fit scale the
    /// whole page is on screen and the page write alone suffices. The
    /// 1% epsilon absorbs autoScales float noise.
    nonisolated static func shouldRectScroll(
        scaleFactor: CGFloat, fitScaleFactor: CGFloat
    ) -> Bool {
        scaleFactor > fitScaleFactor * 1.01
    }

    /// UXC-50 (D-128, RB-123 item 1): the readability formula. The
    /// navigation scale that renders `rectInPage` (page points) at
    /// `ReadabilityZoom.textHeightTarget` on screen, width-guarded so
    /// the whole rect stays visible, clamped to
    /// [fit … min(navZoomCap × fit, maxScale)]. A page-wide rect's
    /// width fit lands at-or-below fit ⇒ clamps to fit = no zoom (no
    /// special-casing); a taller united multi-line rect zooms LESS.
    /// `nil` = leave the scale alone (degenerate rect or geometry).
    /// The cap is a navigation target only — never written to
    /// `maxScaleFactor` (RB-116's pinch ceiling stays PDFKit's).
    nonisolated static func readabilityTargetScale(
        rectInPage: CGRect,
        viewportSize: CGSize,
        fitScale: CGFloat,
        maxScale: CGFloat
    ) -> CGFloat? {
        guard rectInPage.width > 0.001, rectInPage.height > 0.001,
              fitScale > 0, viewportSize.width > 0, viewportSize.height > 0
        else { return nil }
        let heightRule = ReadabilityZoom.textHeightTarget / rectInPage.height
        let widthFit = (viewportSize.width - 2 * ReadabilityZoom.horizontalMargin)
            / rectInPage.width
        let ceiling = min(ReadabilityZoom.navZoomCap * fitScale, maxScale)
        let target = min(heightRule, widthFit)
        return min(max(target, fitScale), max(ceiling, fitScale))
    }

    func makeCoordinator() -> PDFViewCoordinator {
        let coordinator = PDFViewCoordinator()
        coordinator.documentState = documentState
        coordinator.redactionState = redactionState
        coordinator.toastManager = toastManager
        // DRAW-1: hand the PDFViewCoordinator up to PipelineCoordinator
        // so SwiftUI polygon Cancel / Close buttons can forward through
        // the existing `@Environment(PipelineCoordinator.self)` handle.
        pipelineCoordinator.pdfViewCoordinator = coordinator
        return coordinator
    }

    func makeUIView(context: Context) -> FitFlooredPDFView {
        let pdfView = FitFlooredPDFView()
        // UI_UX §6.1: Opaque background prevents glass bleed-through
        pdfView.backgroundColor = .systemGroupedBackground
        // UXC-48 (D-123): the zoom floor rides the subclass — a pinch
        // out stops at this page's fit size (see `FitFlooredPDFView`).
        pdfView.autoScales = true
        pdfView.displayMode = .singlePage
        // ARCH §5.4: Enable touch routing to overlay views
        pdfView.isInMarkupMode = true

        // ARCH §5.4: Set overlay provider BEFORE assigning document
        pdfView.pageOverlayViewProvider = context.coordinator

        pdfView.document = documentState.sourceDocument

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

        // Update document if changed (new import)
        if pdfView.document !== documentState.sourceDocument {
            pdfView.document = documentState.sourceDocument
        }

        // Sync page navigation — avoid re-navigation if already on correct page
        if let doc = pdfView.document,
           let targetPage = doc.page(at: documentState.currentPageIndex),
           pdfView.currentPage != targetPage {
            pdfView.go(to: targetPage)
        }

        // SA-3 rider (D-70): rect-level scroll-to-match. Consume the
        // pending target exactly once (token guard on the
        // coordinator — no state write during the update pass), and
        // only when the view is zoomed past fit: at fit scale the
        // whole page is visible, page-granular navigation suffices,
        // and an unconditional `go(to:on:)` would zoom unexpectedly.
        // The rect converts through the engine's canonical
        // `normalizedToPDFPageCoordinates` (ENGINE §5B.1a) — the same
        // mapping the burn path uses, so the scroll target and the
        // drawn redaction agree by construction.
        if let target = documentState.pendingCanvasScrollTarget,
           coordinator.lastHandledCanvasScrollToken != target.token {
            coordinator.lastHandledCanvasScrollToken = target.token
            // UXC-50 (D-128, RB-123 items 1–2, 7): `.readability`
            // normalizes the scale to the readability target FIRST
            // (in or out, never below the UXC-48 floor), then rect-
            // scrolls through the same `shouldRectScroll` gate below
            // — instant, no animation. The `.none` path is untouched.
            if target.zoom == .readability,
               let doc = pdfView.document,
               let page = doc.page(at: target.pageIndex) {
                let pageRect = normalizedToPDFPageCoordinates(
                    target.normalizedRect,
                    pageRect: page.bounds(for: pdfView.displayBox)
                )
                pdfView.frameForReadability(rectInPage: pageRect, on: page)
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

        // UI_UX §9.1: VoiceOver label for the document editor
        pdfView.accessibilityLabel = "Document editor, page \(documentState.currentPageIndex + 1) of \(documentState.pageCount)"

        // Propagate state to coordinator
        coordinator.redactionState = redactionState
        coordinator.toastManager = toastManager
        // DRAW-1: re-stamp the back-pointer in case PipelineCoordinator
        // outlived a prior PDFViewCoordinator and the bridge needs to
        // re-bind to the current one (defensive — the weak ref otherwise
        // nils through reassignment).
        pipelineCoordinator.pdfViewCoordinator = coordinator
        let isEditing = documentState.phaseKind == .editing
        coordinator.updateDrawingMode(isEditing, isDrawing: isEditing && isDrawingMode)
        // DRAW-1: propagate the active shape tool. Reset to .rectangle
        // when drawing is off so the overlay does not retain stale state
        // (e.g., polygon vertices) after the toolbar tool deactivates.
        coordinator.updateActiveShapeTool(
            isEditing && isDrawingMode ? activeShapeTool : .rectangle
        )
        // WU-38: propagate "Select More" toggle state to overlays.
        coordinator.updateMultiSelectMode(isEditing && isMultiSelectActive)
        // DRAW-7: propagate snap-to-text-box toggle to overlays so the
        // rectangle drag handler observes the current Settings value
        // even when toggled mid-session.
        coordinator.updateSnapToTextEnabled(snapToTextEnabled)

        // Refresh overlays only when regions or selection actually changed
        coordinator.refreshAllOverlaysIfNeeded()
    }
}

// MARK: - Readability zoom constants (UXC-50, D-128, RB-123)

/// The RB-123 tuning surface — the ONE home for the readability
/// formula's numbers (`PDFDocumentView.readabilityTargetScale`). The
/// SHAPE is ruled; the exact values are tuned on-sim and at Jesse's
/// device pass. `navZoomCap` is a navigation target only — it never
/// touches `maxScaleFactor` (RB-116's pinch ceiling stays PDFKit's).
nonisolated enum ReadabilityZoom {
    /// On-screen height (points) the matched text is framed to.
    static let textHeightTarget: CGFloat = 20
    /// Horizontal breathing room (points, each side) in the width guard.
    static let horizontalMargin: CGFloat = 16
    /// Ceiling as a multiple of the fit scale.
    static let navZoomCap: CGFloat = 3.5
    /// Relative dead band (× fit) below which the scale is left alone.
    static let scaleEpsilon: CGFloat = 0.01
}

// MARK: - Zoom floor (UXC-48, D-123)

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

    // MARK: - Readability framing (UXC-50, D-128, RB-123)

    /// The one-shot re-assert store. Trap T1 (mini-toolbar packet):
    /// PDFKit with `autoScales` re-fits even a zoomed-in view when
    /// the canvas bounds change (`CanvasZoomFloorTests.
    /// floorTracksACanvasResize` pins it). The first chevron tap from
    /// medium/large PARKS the sheet, and the compact inset (RB-42 +
    /// the UXC-50 single-page inset) shrinks the bounds AFTER the
    /// consumption in `updateUIView` — a naively applied zoom is thrown
    /// away. Contract: every `.readability` consumption replaces this
    /// store; `layoutSubviews`, after `applyFitFloor()`, re-applies the
    /// framing exactly ONCE when the bounds differ from those at
    /// consumption, then clears it. A tap with stable bounds (already
    /// parked) applies once at consumption and the store simply
    /// expires on the next replacement. Never more than one re-assert
    /// per request token.
    private struct ReadabilityFramingTarget {
        let page: PDFPage
        let rectInPage: CGRect
        let boundsAtConsumption: CGRect
    }

    private var pendingReadabilityFraming: ReadabilityFramingTarget?

    /// Consume a `.readability` scroll target: normalize + rect-scroll
    /// now, and arm the post-layout re-assert.
    func frameForReadability(rectInPage: CGRect, on page: PDFPage) {
        applyReadabilityFraming(rectInPage: rectInPage, on: page)
        pendingReadabilityFraming = ReadabilityFramingTarget(
            page: page, rectInPage: rectInPage, boundsAtConsumption: bounds
        )
    }

    private func reassertReadabilityFramingIfNeeded() {
        guard let pending = pendingReadabilityFraming,
              pending.boundsAtConsumption != bounds
        else { return }
        pendingReadabilityFraming = nil
        applyReadabilityFraming(rectInPage: pending.rectInPage, on: pending.page)
    }

    /// NORMALIZE (RB-123 item 2): write the computed scale up OR down
    /// when it differs meaningfully from the current one — the UXC-48
    /// floor rules out below-fit; a page-wide item from a
    /// pinched state returns to fit by design. Then rect-scroll through
    /// the existing `shouldRectScroll` gate: at fit it self-refuses and
    /// the page write alone suffices, exactly today's behaviour.
    private func applyReadabilityFraming(rectInPage: CGRect, on page: PDFPage) {
        let fit = scaleFactorForSizeToFit
        if let target = PDFDocumentView.readabilityTargetScale(
            rectInPage: rectInPage,
            viewportSize: bounds.size,
            fitScale: fit,
            maxScale: maxScaleFactor
        ), abs(target - scaleFactor) > ReadabilityZoom.scaleEpsilon * fit {
            scaleFactor = target
        }
        guard PDFDocumentView.shouldRectScroll(
            scaleFactor: scaleFactor, fitScaleFactor: scaleFactorForSizeToFit
        ) else { return }
        // The 8-pt page-unit pad keeps the RB-93 ring off the viewport edge.
        let padded = rectInPage
            .insetBy(dx: -8, dy: -8)
            .intersection(page.bounds(for: displayBox))
        guard !padded.isNull else { return }
        go(to: padded, on: page)
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
