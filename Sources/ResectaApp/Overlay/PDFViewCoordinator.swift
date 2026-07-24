import UIKit
import PDFKit
import RedactionEngine

// ARCH §5.4: PDFPageOverlayViewProvider coordinator.
// UI_UX §2.1: Routes state between RedactionState and per-page overlays.
// UI_UX §2.7: Region coordinates are sensitive data — never logged (R2).

/// Coordinator for PDFDocumentView. Serves as PDFPageOverlayViewProvider,
/// NotificationCenter observer for page/scale changes, and Scribble suppressor (D13/R9).
@MainActor
class PDFViewCoordinator: NSObject, PDFPageOverlayViewProvider, UIScribbleInteractionDelegate {

    weak var pdfView: PDFView?
    var redactionState: RedactionState?
    /// DRAW-6: Toast surface for the lasso-marquee 500-region cap warning.
    /// Optional so the coordinator stays usable in tests that don't wire
    /// the toast manager; the overlay marquee path no-ops the toast when
    /// nil (the cap still truncates).
    var toastManager: ToastQueueManager?
    var isDrawingEnabled: Bool = true
    var isDrawingMode: Bool = false
    /// DRAW-1: active shape tool propagated to every overlay. Default
    /// `.rectangle` preserves prior behaviour when DRAW-1 callers don't
    /// set the tool explicitly.
    var activeShapeTool: RedactionOverlayView.ShapeTool = .rectangle
    /// WU-38: iPhone "Select More" toolbar toggle. While on, a tap on a
    /// region toggles its membership in the selection instead of replacing
    /// the selection. Propagates to overlays via `updateMultiSelectMode`.
    var isMultiSelectActive: Bool = false

    /// Active overlays keyed by page index, for targeted refresh.
    private var activeOverlays: [Int: RedactionOverlayView] = [:]

    /// Phase 5C: O(1) dirty-checking via version counter + selection snapshot.
    /// Replaces O(n) deep dictionary comparison.
    private var lastRegionVersion: Int = -1
    private var lastSelectedIDs: Set<UUID>?
    /// SEARCH-AND-REDACT §7.2: Track search results version for overlay refresh.
    private var lastSearchResultsVersion: Int = -1
    /// Track whether an active search existed, to force refresh on search dismissal.
    private var lastHadActiveSearch: Bool = false
    /// W7 — track the visible page index so a page change rebinds the
    /// live-preview overlay (rects are scoped to the visible page only).
    private var lastVisiblePageIndex: Int = -1

    /// Strong reference to DocumentState for page-change sync.
    /// CONC-3 (Pkg N): the property is a `var DocumentState?` (strong),
    /// not `weak`. The prior docstring claimed "weak" — the docstring
    /// is now accurate. Lifetime is bounded by the SwiftUI Representable
    /// (`PDFDocumentView`) ownership chain: the Representable owns the
    /// coordinator instance, the coordinator borrows the DocumentState
    /// reference. When the Representable is torn down, the coordinator
    /// deallocates and the strong reference dies with it. A `weak` qualifier
    /// would force every page-change site through optional unwrap with no
    /// real lifetime benefit since DocumentState is already retained by
    /// the enclosing `RedactWorkspace`.
    var documentState: DocumentState?

    // SA-3 rider (D-70): the last consumed rect-level scroll-to-match
    // token. `PDFDocumentView.updateUIView` compares against the
    // pending target's token so each request fires `go(to:on:)`
    // exactly once without a state write during the update pass.
    var lastHandledCanvasScrollToken: UUID?

    // nonisolated(unsafe): tokens written once in setupObservers (main),
    // read once in deinit (nonisolated). No concurrent access.
    private nonisolated(unsafe) var pageChangeObserver: Any?

    // MARK: - Observer Setup

    func setupObservers(for pdfView: PDFView) {
        guard pageChangeObserver == nil else { return }
        self.pdfView = pdfView

        // Page change — sync currentPageIndex back to DocumentState.
        // nonisolated(unsafe) bridges isolation; .main queue is safe for
        // MainActor.assumeIsolated. See feedback_undo_concurrency memory.
        nonisolated(unsafe) let docState = documentState
        pageChangeObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged,
            object: pdfView,
            queue: .main
        ) { [weak self, weak pdfView] _ in
            MainActor.assumeIsolated {
                guard let pdfView,
                      let currentPage = pdfView.currentPage,
                      let doc = pdfView.document else { return }
                let index = doc.index(for: currentPage)
                // DRAW-1 / §S2.2: page-change mid-polygon discards the
                // in-progress vertex list on every overlay so the bottom
                // capsule cannot describe vertices laid on a page the
                // user has scrolled away from. Runs BEFORE the page-index
                // write so observers see the discard before the new page.
                if let self, self.activeShapeTool == .polygon {
                    for (_, overlay) in self.activeOverlays {
                        overlay.discardInProgressPolygon()
                    }
                }
                if docState?.currentPageIndex != index {
                    docState?.currentPageIndex = index
                }
            }
        }

        // R9/D13: Suppress Scribble in draw mode — add interaction to the PDF view
        let scribbleInteraction = UIScribbleInteraction(delegate: self)
        pdfView.addInteraction(scribbleInteraction)

        // Scale change: overlays auto-resize via PDFView transform (UI_UX §2.6).
        // No observer needed — coordinate system scales automatically.
    }

    deinit {
        if let o = pageChangeObserver { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: - PDFPageOverlayViewProvider (ARCH §5.4)

    func pdfView(_ view: PDFView,
                 overlayViewFor page: PDFPage) -> UIView? {
        guard let pageIndex = view.document?.index(for: page) else { return nil }

        let overlay = RedactionOverlayView()
        overlay.pageIndex = pageIndex
        overlay.coordinator = self
        overlay.isUserInteractionEnabled = isDrawingEnabled
        overlay.isDrawingMode = isDrawingMode
        overlay.activeShapeTool = activeShapeTool
        overlay.isMultiSelectActive = isMultiSelectActive
        // DRAW-7: inherit current snap toggle. Without this a page that
        // first appears mid-session would default-on, ignoring a user
        // who had already toggled the assist off.
        overlay.snapToTextEnabled = snapToTextEnabled

        let regions = redactionState?.regions[pageIndex] ?? []
        let searchHighlights = redactionState?.activeSearch?.resultsByPage[pageIndex] ?? []
        let livePreviewRects = livePreviewRects(forPage: pageIndex)
        overlay.configure(
            with: regions,
            selectedIDs: redactionState?.selectedRegionIDs ?? [],
            searchHighlights: searchHighlights,
            livePreviewRects: livePreviewRects
        )

        activeOverlays[pageIndex] = overlay
        return overlay
    }

    /// W7 — return live-preview rects for `pageIndex` if it's the visible
    /// page. Rects are computed by the sheet (which owns the searcher) and
    /// stashed on `SearchState.livePreviewRects`.
    private func livePreviewRects(forPage pageIndex: Int) -> [CGRect] {
        guard let search = redactionState?.activeSearch,
              let visible = documentState?.currentPageIndex,
              pageIndex == visible
        else { return [] }
        return search.livePreviewRects
    }

    func pdfView(_ view: PDFView,
                 willEndDisplayingOverlayView overlayView: UIView,
                 for page: PDFPage) {
        guard let pageIndex = view.document?.index(for: page) else { return }
        activeOverlays.removeValue(forKey: pageIndex)
    }

    // MARK: - Region Management (called from overlay touch handlers)

    func addRegion(_ region: RedactionRegion, page: Int, undoManager: UndoManager?) {
        redactionState?.addRegion(region, page: page, undoManager: undoManager)
        refreshOverlay(for: page)
    }

    func selectRegion(_ id: UUID?) {
        redactionState?.selectedRegionID = id
        // Refresh all active overlays to update selection visuals
        refreshAllOverlays()
    }

    /// Toggle a region in/out of the multi-selection set (Shift+tap on iPad).
    func toggleRegionSelection(_ id: UUID) {
        guard let state = redactionState else { return }
        if state.selectedRegionIDs.contains(id) {
            state.selectedRegionIDs.remove(id)
        } else {
            state.selectedRegionIDs.insert(id)
        }
        refreshAllOverlays()
    }

    /// Select all regions on a given page.
    func selectAllRegions(on page: Int) {
        guard let state = redactionState,
              let pageRegions = state.regions[page] else { return }
        state.selectedRegionIDs = Set(pageRegions.map(\.id))
        refreshAllOverlays()
    }

    /// Clear multi-selection.
    func deselectAll() {
        redactionState?.selectedRegionIDs = []
        refreshAllOverlays()
    }

    func commitResize(_ id: UUID, page: Int, newRect: CGRect, undoManager: UndoManager?) {
        redactionState?.resizeRegion(id, page: page, newRect: newRect, undoManager: undoManager)
        refreshOverlay(for: page)
    }

    // §A8: Commit region move after drag ends.
    func commitMove(_ id: UUID, page: Int, newRect: CGRect, undoManager: UndoManager?) {
        redactionState?.moveRegion(id, page: page, newRect: newRect, undoManager: undoManager)
        refreshOverlay(for: page)
    }

    /// Commit a batch move of multiple regions on the same page.
    func commitMoveMultiple(_ moves: [(id: UUID, newRect: CGRect)], page: Int, undoManager: UndoManager?) {
        redactionState?.moveRegions(moves, page: page, undoManager: undoManager)
        refreshOverlay(for: page)
    }

    /// DRAW-6: Commit a lasso-marquee selection. Routes the resolved set
    /// through `RedactionState.applyBatch` so the 500-region cap and
    /// warning toast are enforced inside `RedactionState` regardless of
    /// caller route. Overlays are refreshed across all pages because the
    /// marquee can cover cross-page regions on multi-page documents.
    func commitLassoSelection(_ regions: [RedactionRegion], undoManager: UndoManager?) {
        guard let state = redactionState else { return }
        state.applyBatch(regions, undoManager: undoManager, toastManager: toastManager)
        refreshAllOverlays()
    }

    /// GAP-7: Delete all selected regions. Delegates to RedactionState.deleteSelected.
    func deleteSelectedRegions(undoManager: UndoManager?) {
        guard let redactionState else { return }
        let affectedPages = redactionState.deleteSelected(undoManager: undoManager)
        for page in affectedPages { refreshOverlay(for: page) }
    }

    // Backward compat alias
    func deleteSelectedRegion(undoManager: UndoManager?) {
        deleteSelectedRegions(undoManager: undoManager)
    }

    /// UI_UX §9.2: Delete a specific region by ID (used by VoiceOver custom action).
    func deleteRegion(_ id: UUID, page: Int) {
        redactionState?.removeRegion(id, page: page, undoManager: nil)
        redactionState?.selectedRegionID = nil
        refreshOverlay(for: page)
    }

    // MARK: - Overlay Refresh

    /// Refresh a single page's overlay from current state.
    func refreshOverlay(for pageIndex: Int) {
        guard let overlay = activeOverlays[pageIndex] else { return }
        let regions = redactionState?.regions[pageIndex] ?? []
        let searchHighlights = redactionState?.activeSearch?.resultsByPage[pageIndex] ?? []
        overlay.configure(
            with: regions,
            selectedIDs: redactionState?.selectedRegionIDs ?? [],
            searchHighlights: searchHighlights,
            livePreviewRects: livePreviewRects(forPage: pageIndex)
        )
    }

    /// Refresh all active overlays. Called on selection changes and state updates.
    func refreshAllOverlays() {
        let selectedIDs = redactionState?.selectedRegionIDs ?? []
        for (pageIndex, overlay) in activeOverlays {
            let regions = redactionState?.regions[pageIndex] ?? []
            let searchHighlights = redactionState?.activeSearch?.resultsByPage[pageIndex] ?? []
            overlay.configure(
                with: regions,
                selectedIDs: selectedIDs,
                searchHighlights: searchHighlights,
                livePreviewRects: livePreviewRects(forPage: pageIndex)
            )
        }
    }

    /// Phase 5C: Refresh overlays only if regions, selection, or search results changed.
    /// Uses O(1) version counter instead of O(n) dictionary comparison.
    func refreshAllOverlaysIfNeeded() {
        let currentVersion = redactionState?.regionVersion ?? 0
        let currentSelectedIDs = redactionState?.selectedRegionIDs
        let hasActiveSearch = redactionState?.activeSearch != nil
        let currentSearchVersion = redactionState?.activeSearch?.resultVersion ?? 0
        let currentVisible = documentState?.currentPageIndex ?? -1
        // Force refresh when search is dismissed (has→no transition).
        let searchCleared = lastHadActiveSearch && !hasActiveSearch
        // W7 — page change rebinds the live-preview overlay (rects scoped
        // to the visible page only).
        let visibleChanged = currentVisible != lastVisiblePageIndex
        guard currentVersion != lastRegionVersion
                || currentSelectedIDs != lastSelectedIDs
                || currentSearchVersion != lastSearchResultsVersion
                || searchCleared
                || visibleChanged else { return }
        lastRegionVersion = currentVersion
        lastSelectedIDs = currentSelectedIDs
        lastSearchResultsVersion = currentSearchVersion
        lastHadActiveSearch = hasActiveSearch
        lastVisiblePageIndex = currentVisible
        refreshAllOverlays()
    }

    /// Update drawing mode on all active overlays.
    /// R8/D9: Also configures two-finger scroll when draw mode is active.
    func updateDrawingMode(_ enabled: Bool, isDrawing: Bool) {
        isDrawingEnabled = enabled
        isDrawingMode = isDrawing
        for (_, overlay) in activeOverlays {
            overlay.isUserInteractionEnabled = enabled
            overlay.isDrawingMode = isDrawing
        }

        // R8/D9: Two-finger scroll in draw mode — universal iOS annotation pattern.
        // When draw is active, single-finger pans are used for drawing, so scroll
        // requires two fingers. Reset to one finger when draw is inactive.
        if let scrollView = pdfView?.subviews.first(where: { $0 is UIScrollView }) as? UIScrollView {
            scrollView.panGestureRecognizer.minimumNumberOfTouches = isDrawing ? 2 : 1
        }
    }

    /// WU-38: Propagate the iPhone "Select More" toolbar toggle to all
    /// active overlays. Layers on top of the existing selection model —
    /// touchesBegan honors `isMultiSelectActive || shiftHeld` so iPad
    /// hardware-keyboard users keep their Shift+tap path unchanged.
    func updateMultiSelectMode(_ active: Bool) {
        isMultiSelectActive = active
        for (_, overlay) in activeOverlays {
            overlay.isMultiSelectActive = active
        }
    }

    /// DRAW-1: propagate the active shape tool to every overlay. Changing
    /// tools discards any in-progress polygon vertex list (the user's
    /// intent for the previous tool's shape is lost on tool switch).
    func updateActiveShapeTool(_ tool: RedactionOverlayView.ShapeTool) {
        let changed = activeShapeTool != tool
        activeShapeTool = tool
        for (_, overlay) in activeOverlays {
            overlay.activeShapeTool = tool
            if changed { overlay.discardInProgressPolygon() }
        }
    }

    /// DRAW-1 / §S2.2: commit the in-progress polygon on the visible-page
    /// overlay. Routed from the SwiftUI "Close polygon" button on the
    /// bottom hint capsule. No-op if the visible page has no active
    /// overlay (e.g., page off-screen) or the overlay's vertex count is
    /// below the 3-vertex floor — the overlay enforces both invariants.
    func commitInProgressPolygon() {
        let pageIndex = documentState?.currentPageIndex ?? 0
        guard let overlay = activeOverlays[pageIndex] else { return }
        overlay.commitInProgressPolygon()
    }

    /// DRAW-1 / §S2.2: discard the in-progress polygon on the visible-page
    /// overlay. Routed from the SwiftUI "Cancel" button on the bottom
    /// hint capsule AND from the Escape-key handler.
    func cancelInProgressPolygon() {
        let pageIndex = documentState?.currentPageIndex ?? 0
        guard let overlay = activeOverlays[pageIndex] else { return }
        overlay.discardInProgressPolygon()
    }

    /// DRAW-7: snap-to-text-box toggle propagated from Settings. Stored
    /// so newly-attached overlays inherit the current value, and pushed
    /// into all active overlays whenever the user flips the toggle.
    private var snapToTextEnabled: Bool = true
    func updateSnapToTextEnabled(_ enabled: Bool) {
        snapToTextEnabled = enabled
        for (_, overlay) in activeOverlays {
            overlay.snapToTextEnabled = enabled
        }
    }

    // MARK: - UIScribbleInteractionDelegate (R9/D13)

    /// Suppress Scribble in draw mode to prevent Apple Pencil stylus gestures
    /// from being intercepted by the handwriting recognizer.
    nonisolated func scribbleInteraction(
        _ interaction: UIScribbleInteraction,
        shouldBeginAt location: CGPoint
    ) -> Bool {
        // Return false in draw mode to suppress Scribble
        MainActor.assumeIsolated {
            return !isDrawingMode
        }
    }
}
