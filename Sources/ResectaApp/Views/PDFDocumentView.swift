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

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        // UI_UX §6.1: Opaque background prevents glass bleed-through
        pdfView.backgroundColor = .systemGroupedBackground
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

    func updateUIView(_ pdfView: PDFView, context: Context) {
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
            if let doc = pdfView.document,
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
