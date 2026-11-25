import UIKit
import PDFKit
import RedactionEngine

// PDFPageOverlayViewProvider coordinator.
// Routes state between RedactionState and per-page overlays.
// Region coordinates are sensitive data — never logged.

/// Coordinator for PDFDocumentView. Serves as PDFPageOverlayViewProvider,
/// PDFViewDelegate (the link policy), NotificationCenter observer for
/// page/scale changes, and Scribble suppressor.
@MainActor
class PDFViewCoordinator: NSObject, PDFPageOverlayViewProvider, PDFViewDelegate, UIScribbleInteractionDelegate,
                          CanvasTouchHolding {

    weak var pdfView: PDFView?
    /// The region state. The coordinator sets itself as the state's canvas,
    /// so the run door can ask whether a finger is down on a page, and the
    /// run entry probes every live canvas through it.
    var redactionState: RedactionState? {
        didSet {
            if oldValue !== redactionState, oldValue?.canvas === self { oldValue?.canvas = nil }
            redactionState?.canvas = self
            redactionState?.probeLiveCanvases = { [weak self] in self?.boxPlaceProbeFailures() ?? [] }
        }
    }
    /// The settings a drawn page's plan is kept with (`noteDrawn`).
    var settingsState: SettingsState?
    /// The run's quality cap (`PipelineCoordinator.dpiCap`: 300, then 150
    /// after a memory warning), set by the view. A drawn page's plan is kept
    /// at the quality a run started now uses, `runQuality` of the chosen
    /// quality under this cap. A change keeps every kept page's plan at the
    /// new quality, on screen or not, and redraws the pages on screen. A
    /// kept plan of an older version of its page, or of a working copy, is
    /// not made again from the stored regions: that would keep a plan of
    /// regions the page was not drawn with. The pages on screen redraw, and
    /// keep a plan of what they draw.
    var qualityCap: Int = defaultDPICap {
        didSet {
            guard qualityCap != oldValue, let state = redactionState else { return }
            for (pageIndex, kept) in state.drawnPlans
            where kept.pageVersion == state.pageVersion(pageIndex) && kept.fromStoredRegions == true {
                noteDrawn(pageIndex: pageIndex, regions: state.regions[pageIndex] ?? [], drawn: false)
            }
            for (pageIndex, overlay) in activeOverlays {
                noteDrawn(pageIndex: pageIndex, regions: state.regions[pageIndex] ?? [], drawn: false)
                overlay.setNeedsDisplay()
            }
        }
    }
    /// Toast surface for the too-small-draw notice, the selection delete's
    /// notice and the lasso's 500-region warning. Optional so the
    /// coordinator stays usable in tests that don't wire the toast manager.
    var toastManager: ToastQueueManager?
    var isDrawingEnabled: Bool = true
    var isDrawingMode: Bool = false
    /// Active shape tool propagated to every overlay. Default
    /// `.rectangle` preserves prior behaviour when callers don't
    /// set the tool explicitly.
    var activeShapeTool: RedactionOverlayView.ShapeTool = .rectangle
    /// iPhone "Select More" toolbar toggle. While on, a tap on a
    /// region toggles its membership in the selection instead of replacing
    /// the selection. Propagates to overlays via `updateMultiSelectMode`.
    var isMultiSelectActive: Bool = false

    /// Active overlays keyed by page index, for targeted refresh.
    private var activeOverlays: [Int: RedactionOverlayView] = [:]
    /// The pages whose read a kept plan waits on (`noteDrawn`).
    private var pageReadsAsked: Set<Int> = []

    /// O(1) dirty-checking via version counter + selection snapshot.
    /// Replaces O(n) deep dictionary comparison.
    private var lastRegionVersion: Int = -1
    private var lastSelectedIDs: Set<UUID>?
    /// Track search results version for overlay refresh.
    private var lastSearchResultsVersion: Int = -1
    /// Track whether an active search existed, to force refresh on search dismissal.
    private var lastHadActiveSearch: Bool = false
    /// Track the visible page index so a page change rebinds the
    /// live-preview overlay (rects are scoped to the visible page only).
    private var lastVisiblePageIndex: Int = -1
    /// The last focused search-result id pushed
    /// to the overlays. Navigation changes `currentResultIndex`
    /// without bumping `resultVersion`, so the ring has its own
    /// dirty check in `refreshAllOverlaysIfNeeded`.
    private var lastFocusedHighlightID: UUID?

    /// The result the walk currently focuses — the
    /// id every overlay `configure` receives for the focus ring.
    private var focusedHighlightID: UUID? {
        redactionState?.activeSearch?.currentResult?.id
    }

    /// Strong reference to DocumentState for page-change sync.
    /// The property is a `var DocumentState?` (strong),
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

    // The last consumed rect-level scroll-to-match
    // token. `PDFDocumentView.updateUIView` compares against the
    // pending target's token so each request fires `go(to:on:)`
    // exactly once without a state write during the update pass.
    var lastHandledCanvasScrollToken: UUID?

    /// The tokens of what this coordinator observes: the page and scale
    /// notices, and the inner scroll view's offset with the view it was
    /// taken on (a new scroll view is observed afresh).
    private nonisolated struct Observations {
        var notices: [NSObjectProtocol] = []
        var offset: NSKeyValueObservation?
        weak var offsetScrollView: UIScrollView?
    }

    // nonisolated(unsafe): every token this coordinator takes, written on
    // the main actor where the observers are set, read once in deinit
    // (nonisolated). No concurrent access.
    private nonisolated(unsafe) var observations = Observations()

    /// The page frames' writes, counted for the hosted test of the rule
    /// that nothing is written while no notice wants them.
    private(set) var pageFramePublishCount = 0
    /// A publish is waiting for the next main-actor turn.
    private var pageFramePublishPending = false

    // MARK: - Observer Setup

    func setupObservers(for pdfView: PDFView) {
        guard observations.notices.isEmpty else { return }
        self.pdfView = pdfView

        // Page change — sync currentPageIndex back to DocumentState.
        // nonisolated(unsafe) bridges isolation; the notification always
        // fires on the main queue, so MainActor.assumeIsolated is sound here.
        nonisolated(unsafe) let docState = documentState
        let pageChangeObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged,
            object: pdfView,
            queue: .main
        ) { [weak self, weak pdfView] _ in
            MainActor.assumeIsolated {
                guard let pdfView,
                      let currentPage = pdfView.currentPage,
                      let doc = pdfView.document else { return }
                let index = doc.index(for: currentPage)
                // The selection keeps only the regions on the page in
                // view, so a delete or a nudge never reaches a region the
                // user cannot see. Runs on every notice: the page bar
                // writes the index before the view follows it.
                if let state = self?.redactionState {
                    let visible = state.selectedRegionIDs.filter { state.pageIndex(for: $0) == index }
                    if visible != state.selectedRegionIDs {
                        state.selectedRegionIDs = visible
                    }
                }
                if docState?.currentPageIndex != index {
                    docState?.currentPageIndex = index
                }
                self?.requestPageFramePublish()
            }
        }

        // Scale change: every overlay held redraws its marks sized in
        // screen points (`zoomChanged()`); the band's page frames move
        // with the page.
        let scaleChangeObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewScaleChanged,
            object: pdfView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.requestPageFramePublish()
                self?.activeOverlays.values.forEach { $0.zoomChanged() }
            }
        }
        observations.notices = [pageChangeObserver, scaleChangeObserver]

        // Suppress Scribble in draw mode — add interaction to the PDF view
        let scribbleInteraction = UIScribbleInteraction(delegate: self)
        pdfView.addInteraction(scribbleInteraction)
    }

    deinit {
        for o in observations.notices { NotificationCenter.default.removeObserver(o) }
        observations.offset?.invalidate()
    }

    // MARK: - Page frames for the notice band

    /// Asks for the page frames to be published on the next main-actor
    /// turn, so no state is written inside a view update or a layout pass
    /// (a page change, a zoom and an offset can each come from one). With
    /// no notice wanting them it does nothing. Several asks in one turn
    /// publish once.
    func requestPageFramePublish() {
        guard documentState?.canvasPageFramesWanted == true, !pageFramePublishPending else { return }
        pageFramePublishPending = true
        Task { [weak self] in
            self?.pageFramePublishPending = false
            self?.publishPageFrames()
        }
    }

    /// Writes the visible pages' frames for the editor's band: each page's
    /// rectangle in the canvas's coordinates, clipped to the canvas, in
    /// whole points rounded outward, and which page each one is. It returns
    /// at once while no notice wants them, and writes only when the
    /// whole-point values or the pages change: a page change at a zoom that
    /// fills the canvas leaves the same rectangle, and is still a move.
    /// Each publish also keeps the scroll offset observed on the scroll
    /// view the canvas has now.
    func publishPageFrames() {
        guard let documentState, documentState.canvasPageFramesWanted, let pdfView else { return }
        observeScrollOffset(of: pdfView)
        let shown = Self.visiblePages(in: pdfView)
        guard shown.frames != documentState.canvasPageFrames || shown.indices != documentState.canvasPageIndices else { return }
        documentState.canvasPageFrames = shown.frames
        documentState.canvasPageIndices = shown.indices
        pageFramePublishCount += 1
    }

    /// Each visible page's rectangle in `pdfView`'s coordinates, clipped to
    /// its bounds and rounded outward, with the document's index of each
    /// page in the same order (-1 for a page the view's document does not
    /// hold); a page with no area on the canvas gives neither.
    static func visiblePages(in pdfView: PDFView) -> (frames: [CanvasRect], indices: [Int]) {
        let canvas = pdfView.bounds
        var frames: [CanvasRect] = [], indices: [Int] = []
        for page in pdfView.visiblePages {
            let frame = pdfView.convert(page.bounds(for: pdfView.displayBox), from: page).intersection(canvas)
            guard !frame.isEmpty, let rect = CanvasRect(outward: frame) else { continue }
            frames.append(rect)
            indices.append(pdfView.document.map { $0.index(for: page) } ?? -1)
        }
        return (frames, indices)
    }

    /// Observes the inner scroll view's offset, so a scroll of a zoomed
    /// page moves the band's frames. The scroll view is looked up afresh
    /// each time; a different one than the observed view ends the old
    /// observation and takes a new one.
    private func observeScrollOffset(of pdfView: PDFView) {
        guard let scrollView = Self.innerScrollView(of: pdfView),
              scrollView !== observations.offsetScrollView else { return }
        observations.offset?.invalidate()
        observations.offsetScrollView = scrollView
        observations.offset = scrollView.observe(\.contentOffset, options: []) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.requestPageFramePublish()
            }
        }
    }

    /// PDFKit's inner scroll view: the first subview that is one.
    private static func innerScrollView(of pdfView: PDFView) -> UIScrollView? {
        pdfView.subviews.first(where: { $0 is UIScrollView }) as? UIScrollView
    }

    // MARK: - Link policy (PDFViewDelegate)

    /// Installs this coordinator as the view's delegate.
    /// `PDFDocumentView.makeUIView` calls this BEFORE the document is
    /// assigned so no annotation in the document is ever live under
    /// PDFKit's default handling.
    func applyLinkPolicy(to pdfView: PDFView) {
        pdfView.delegate = self
    }

    /// Assigns the document to the view and turns data detectors off for
    /// it. Both `PDFDocumentView` assignment sites route through here.
    ///
    /// Data detectors add temporary link annotations for URLs and phone
    /// numbers found in the page text. The switch lives on the document,
    /// where it is ON by default (measured on iOS 26.4: a fresh
    /// `PDFDocument` reports it enabled), but the iOS SDK declares only
    /// the view property, deprecated on iOS 18, which reads and writes
    /// the flag of the view's CURRENT document — with no document it is
    /// inert, and a newly assigned document arrives with its own default.
    /// So the write has to follow every assignment, which is why the
    /// assignment itself is here.
    func assign(_ document: PDFDocument?, to pdfView: PDFView) {
        pdfView.document = document
        pdfView.enableDataDetectors = false
    }

    /// Link annotations inside the source document are not followed: the
    /// app opens no URL from document content (PDFKit's default without
    /// a delegate is to open it). The body is intentionally empty and
    /// touches no state, hence nonisolated.
    nonisolated func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
    }

    // MARK: - PDFPageOverlayViewProvider

    func pdfView(_ view: PDFView,
                 overlayViewFor page: PDFPage) -> UIView? {
        guard let pageIndex = view.document?.index(for: page) else { return nil }

        let overlay = RedactionOverlayView()
        overlay.pageIndex = pageIndex
        // The app shows the crop box and never sets another display box, so
        // the geometry's crop and the page size below read one box.
        assert(PDFDisplayBox.cropBox == view.displayBox)
        overlay.geometry = RunRecord.PageGeometry(page: page, box: view.displayBox)
        overlay.pageSize = page.bounds(for: view.displayBox).size
        overlay.coordinator = self
        overlay.isUserInteractionEnabled = isDrawingEnabled
        overlay.isDrawingMode = isDrawingMode
        overlay.activeShapeTool = activeShapeTool
        overlay.isMultiSelectActive = isMultiSelectActive

        let regions = redactionState?.regions[pageIndex] ?? []
        let searchHighlights = (redactionState?.activeSearch?.resultsByPage[pageIndex] ?? []).filter(\.hasBox)
        let livePreviewRects = livePreviewRects(forPage: pageIndex)
        overlay.configure(
            with: regions,
            selectedIDs: redactionState?.selectedRegionIDs ?? [],
            searchHighlights: searchHighlights,
            livePreviewRects: livePreviewRects,
            focusedHighlightID: focusedHighlightID
        )

        activeOverlays[pageIndex] = overlay
        return overlay
    }

    /// Return live-preview rects for `pageIndex` if it's the visible
    /// page. Rects are computed by the sheet (which owns the searcher) and
    /// stashed on `SearchState.livePreviewRects`.
    private func livePreviewRects(forPage pageIndex: Int) -> [CGRect] {
        guard let search = redactionState?.activeSearch,
              let visible = documentState?.currentPageIndex,
              pageIndex == visible
        else { return [] }
        return search.livePreviewRects
    }

    // MARK: - Box places (the canvas probe)

    /// A canvas's probe answer when PDFKit first placed it: a failure is kept
    /// on the page for the document, and the run refuses the page.
    func recordBoxPlaceProbe(pageIndex: Int, passes: Bool) {
        if !passes { redactionState?.canvasProbeFailures.insert(pageIndex) }
    }

    /// Probes every live canvas now: the pages whose canvas fails, or that
    /// PDFKit has not yet placed.
    func boxPlaceProbeFailures() -> Set<Int> {
        Set(activeOverlays.compactMap { page, overlay in overlay.boxPlaceProbePasses() == true ? nil : page })
    }

    func pdfView(_ view: PDFView,
                 willEndDisplayingOverlayView overlayView: UIView,
                 for page: PDFPage) {
        guard let pageIndex = view.document?.index(for: page) else { return }
        activeOverlays.removeValue(forKey: pageIndex)
    }

    // MARK: - Region Management (called from overlay touch handlers)

    func addRegion(_ region: RedactionRegion, page: Int, undoManager: UndoManager?) {
        assert(RedactionState.admitsEditorShare(region.normalizedRect))
        redactionState?.addRegion(region, page: page, undoManager: undoManager)
        refreshOverlay(for: page)
    }

    func selectRegion(_ id: UUID?) {
        redactionState?.selectedRegionID = id
        // Refresh all active overlays to update selection visuals
        refreshAllOverlays()
    }

    /// What a tap on the canvas clears: with the Rectangle tool off and Add
    /// to Selection off, a tap on no region clears a non-empty selection. A
    /// region under the point is the overlay's own touch.
    static func canvasTapClearsSelection(
        hitsRegion: Bool, isDrawingMode: Bool, isMultiSelectActive: Bool, hasSelection: Bool
    ) -> Bool {
        hasSelection && !hitsRegion && !isDrawingMode && !isMultiSelectActive
    }

    /// The canvas's single tap (`FitFlooredPDFView.onSingleTap`), in
    /// `view`'s coordinates. The visible page's overlay answers whether a
    /// region is under the point, by its own hit test.
    func handleCanvasTap(at point: CGPoint, in view: UIView) {
        guard let state = redactionState else { return }
        let overlay = documentState.flatMap { activeOverlays[$0.currentPageIndex] }
        let hitsRegion = overlay.map { $0.hitTestRegion(at: view.convert(point, to: $0)) != nil } ?? false
        guard Self.canvasTapClearsSelection(
            hitsRegion: hitsRegion,
            isDrawingMode: isDrawingMode,
            isMultiSelectActive: isMultiSelectActive,
            hasSelection: !state.selectedRegionIDs.isEmpty
        ) else { return }
        selectRegion(nil)
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

    /// The resize, move and group-move commits. A tap on a selected region,
    /// or on one region of a selected group, ends its "drag" where it
    /// began; the mutators judge that no-op themselves (no step, no Redo
    /// re-armed, the output kept), and the resize is announced only when
    /// the rect changed.
    func commitResize(_ id: UUID, page: Int, newRect: CGRect, drawnPageRect: CGRect? = nil,
                      undoManager: UndoManager?) {
        assert(RedactionState.admitsEditorShare(newRect))
        if redactionState?.resizeRegion(id, page: page, newRect: newRect, undoManager: undoManager,
                                        drawnPageRect: drawnPageRect) == true {
            UIAccessibility.post(notification: .announcement, argument: Self.commitAnnouncement(.resized))
        }
        refreshOverlay(for: page)
    }

    // Commit region move after drag ends.
    func commitMove(_ id: UUID, page: Int, newRect: CGRect, drawnPageRect: CGRect? = nil,
                    undoManager: UndoManager?) {
        assert(RedactionState.admitsEditorShare(newRect))
        redactionState?.moveRegion(id, page: page, newRect: newRect, undoManager: undoManager,
                                   drawnPageRect: drawnPageRect)
        refreshOverlay(for: page)
    }

    /// Commit a batch move of multiple regions on the same page.
    func commitMoveMultiple(_ moves: [(id: UUID, newRect: CGRect)], page: Int,
                            drawnPageRects: [UUID: CGRect] = [:], undoManager: UndoManager?) {
        #if DEBUG
        // A group whose union lay past the page before the move (a member
        // stored past an edge) keeps that excess: each member is held to it.
        let ids = Set(moves.map(\.id))
        let before = (redactionState?.regions[page] ?? []).filter { ids.contains($0.id) }.map(\.normalizedRect)
        let excess = before.dropFirst().reduce(before.first) { $0?.union($1) }.map(RedactionState.excessPastThePage) ?? 0
        for move in moves { assert(RedactionState.admitsEditorShare(move.newRect, slack: excess)) }
        #endif
        redactionState?.moveRegions(moves, page: page, undoManager: undoManager, drawnPageRects: drawnPageRects)
        refreshOverlay(for: page)
    }

    /// Commit a lasso-marquee selection. Routes the resolved set
    /// through `RedactionState.applyBatch` so the 500-region cap and
    /// warning toast are enforced inside `RedactionState` regardless of
    /// caller route. Overlays are refreshed across all pages because the
    /// marquee can cover cross-page regions on multi-page documents.
    /// With Add to Selection on, the marquee ADDS to the current
    /// selection (current first, so the cap keeps what was already
    /// chosen) and an empty marquee — a tap on the page — changes nothing.
    func commitLassoSelection(_ regions: [RedactionRegion]) {
        guard let state = redactionState else { return }
        var batch = regions
        if isMultiSelectActive {
            guard !regions.isEmpty else { return }
            let current = state.regions.keys.sorted().flatMap { state.regions[$0] ?? [] }
                .filter { state.selectedRegionIDs.contains($0.id) }
            let currentIDs = Set(current.map(\.id))
            batch = current + regions.filter { !currentIDs.contains($0.id) }
        }
        // With Add to Selection on, its capsule holds the slot, not the
        // selection bar: the cut is said by the warning.
        state.applyBatch(batch, barShowing: !isMultiSelectActive, toastManager: toastManager)
        refreshAllOverlays()
    }

    /// What a commit announces to VoiceOver.
    enum CommitAnnouncement {
        case resized
        case deleted
    }

    static func commitAnnouncement(_ kind: CommitAnnouncement) -> String {
        switch kind {
        case .resized: return "Region resized"
        case .deleted: return "Region deleted"
        }
    }

    /// Post the too-small draw's notice as a toast. False when no toast
    /// queue is attached, so the overlay speaks it instead.
    @discardableResult
    func noteRegionTooSmall() -> Bool {
        guard let toastManager else { return false }
        toastManager.post(.boxTooSmall)
        return true
    }

    /// Delete a specific region by ID: the long-press menu's Delete and
    /// the VoiceOver custom action. It registers on the window's undo
    /// manager, the one the canvas gestures use, so the delete is its own
    /// undoable step; the rest of a multi-selection stays selected.
    func deleteRegion(_ id: UUID, page: Int) {
        redactionState?.removeRegion(id, page: page, undoManager: pdfView?.window?.undoManager)
        refreshOverlay(for: page)
        UIAccessibility.post(notification: .announcement, argument: Self.commitAnnouncement(.deleted))
    }

    /// The long-press menu's Delete N Regions: the one delete rule, on the
    /// window's undo manager, with its notice for several. The one door for
    /// the menu's selection delete.
    func deleteSelection() {
        guard let state = redactionState else { return }
        let outcome = RegionDeleteRule.deleteSelection(
            redactionState: state, undoManager: pdfView?.window?.undoManager, toastManager: toastManager)
        for page in outcome.pages { refreshOverlay(for: page) }
    }

    // MARK: - The plan a page is drawn from

    /// Keep the plan `pageIndex` is drawn from: made by the one maker
    /// the run's entry uses (`DrawnPlan`, `RunRecord.Page.makePlan`), from the
    /// regions the overlay draws and the source document's crop box and
    /// rotation, which the run's entry reads too, with the settings now, at
    /// the quality a run started now uses (`runQuality`, the run's own
    /// function, under `qualityCap`), with the user's switch and the page's
    /// read, as the run's entry hands them to the same maker. While the plan
    /// reads words, a page with regions whose read is not held yet keeps no
    /// plan: its read is asked for, and the page redraws when it is held.
    /// `drawn` is false when a change of the cap re-keys a kept plan: the
    /// plan is made again, but the quality the page was shown at stays
    /// until the page is drawn. A page drawn while its read is asked for
    /// still notes the quality it was shown at.
    func noteDrawn(pageIndex: Int, regions: [RedactionRegion], drawn isDrawn: Bool = true) {
        guard let state = redactionState, let settings = settingsState, let documentState,
              let page = documentState.sourceDocument?.page(at: pageIndex) else { return }
        let cropBox = page.bounds(for: .cropBox).size
        // Nil where the run refuses the page for its size; no run fills it.
        let quality = runQuality(chosenDPI: settings.exportDPI, dpiCap: qualityCap, cropBox: cropBox,
                                 rotation: page.rotation) ?? min(settings.exportDPI, qualityCap)
        if isDrawn, state.shownDPIs[pageIndex] != quality { state.shownDPIs[pageIndex] = quality }
        let read = documentState.pageReads[pageIndex]
        if RunRecord.planReadsWords, read == nil, !regions.isEmpty {
            state.drawnPlans[pageIndex] = nil
            askPageRead(pageIndex, of: documentState)
            return
        }
        let drawn = DrawnPlan(pageIndex: pageIndex, regions: regions, cropBox: cropBox,
                              rotation: page.rotation, switchOn: settings.boxesAcrossColumn,
                              exportDPI: quality, fillColor: settings.fillColor, read: read)
            .stamped(pageVersion: state.pageVersion(pageIndex),
                     fromStoredRegions: regions == state.regions[pageIndex] ?? [])
        if state.drawnPlans[pageIndex] != drawn { state.drawnPlans[pageIndex] = drawn }
    }

    /// Reads one page for its kept plan, once at a time, and redraws the page
    /// when its read is held, so the page keeps a plan of what it draws.
    private func askPageRead(_ pageIndex: Int, of documentState: DocumentState) {
        guard pageReadsAsked.insert(pageIndex).inserted else { return }
        Task { @MainActor [weak self] in
            await documentState.fillPageReads(for: [pageIndex])
            guard let self else { return }
            self.pageReadsAsked.remove(pageIndex)
            if documentState.pageReads[pageIndex] != nil { self.activeOverlays[pageIndex]?.setNeedsDisplay() }
        }
    }

    // MARK: - Overlay Refresh

    /// Refresh a single page's overlay from current state.
    func refreshOverlay(for pageIndex: Int) {
        guard let overlay = activeOverlays[pageIndex] else { return }
        let regions = redactionState?.regions[pageIndex] ?? []
        let searchHighlights = (redactionState?.activeSearch?.resultsByPage[pageIndex] ?? []).filter(\.hasBox)
        overlay.configure(
            with: regions,
            selectedIDs: redactionState?.selectedRegionIDs ?? [],
            searchHighlights: searchHighlights,
            livePreviewRects: livePreviewRects(forPage: pageIndex),
            focusedHighlightID: focusedHighlightID
        )
    }

    /// Refresh all active overlays. Called on selection changes and state updates.
    func refreshAllOverlays() {
        let selectedIDs = redactionState?.selectedRegionIDs ?? []
        for (pageIndex, overlay) in activeOverlays {
            let regions = redactionState?.regions[pageIndex] ?? []
            let searchHighlights = (redactionState?.activeSearch?.resultsByPage[pageIndex] ?? []).filter(\.hasBox)
            overlay.configure(
                with: regions,
                selectedIDs: selectedIDs,
                searchHighlights: searchHighlights,
                livePreviewRects: livePreviewRects(forPage: pageIndex),
                focusedHighlightID: focusedHighlightID
            )
        }
    }

    /// Refresh overlays only if regions, selection, search results,
    /// or the walk's focused result changed.
    /// Uses O(1) version counter instead of O(n) dictionary comparison.
    func refreshAllOverlaysIfNeeded() {
        let currentVersion = redactionState?.regionVersion ?? 0
        let currentSelectedIDs = redactionState?.selectedRegionIDs
        let hasActiveSearch = redactionState?.activeSearch != nil
        let currentSearchVersion = redactionState?.activeSearch?.resultVersion ?? 0
        let currentVisible = documentState?.currentPageIndex ?? -1
        // Force refresh when search is dismissed (has→no transition).
        let searchCleared = lastHadActiveSearch && !hasActiveSearch
        // Page change rebinds the live-preview overlay (rects scoped
        // to the visible page only).
        let visibleChanged = currentVisible != lastVisiblePageIndex
        // A step of the result walk moves the focus
        // ring without a resultVersion bump (the SwiftUI update pass
        // still runs — the step writes the page index + scroll target).
        let currentFocusedID = focusedHighlightID
        let focusChanged = currentFocusedID != lastFocusedHighlightID
        guard currentVersion != lastRegionVersion
                || currentSelectedIDs != lastSelectedIDs
                || currentSearchVersion != lastSearchResultsVersion
                || searchCleared
                || visibleChanged
                || focusChanged else { return }
        lastRegionVersion = currentVersion
        lastSelectedIDs = currentSelectedIDs
        lastSearchResultsVersion = currentSearchVersion
        lastHadActiveSearch = hasActiveSearch
        lastVisiblePageIndex = currentVisible
        lastFocusedHighlightID = currentFocusedID
        refreshAllOverlays()
    }

    /// Update drawing mode on all active overlays, and the scroll's fingers.
    func updateDrawingMode(_ enabled: Bool, isDrawing: Bool) {
        isDrawingEnabled = enabled
        isDrawingMode = isDrawing
        for (_, overlay) in activeOverlays {
            overlay.isUserInteractionEnabled = enabled
            overlay.isDrawingMode = isDrawing
        }

        applyScrollFingers()
    }

    /// Whether the overlay claimed the touch now down (a region, a
    /// handle, a draw, a marquee), reported by its hit test at each
    /// touch-down and cleared when the touch ends.
    private var canvasHoldsTouch = false

    /// The run door's question: does any live page overlay hold a touch?
    /// Read from the overlays PDFKit has handed out and not yet ended, so
    /// no flag is kept that a lost lift could leave set.
    var holdsATouch: Bool {
        activeOverlays.values.contains { $0.holdsATouch }
    }

    func setCanvasHoldsTouch(_ held: Bool) {
        guard held != canvasHoldsTouch else { return }
        canvasHoldsTouch = held
        applyScrollFingers()
        // A place that waited for the finger is decided as it lifts.
        if !held, selectionBarPlacePending, let pdfView {
            selectionBarPlacePending = false
            placeSelectionBar(in: pdfView)
        }
    }

    // MARK: - The selection bar's place

    /// The selection bar's frame at the bottom of the canvas, in the PDF
    /// view's own points; nil while the bar does not hold the slot.
    var selectionBarFrame: CGRect?
    /// Where the editor hears the bar's place: true for the top.
    var onSelectionBarPlace: (@MainActor (Bool) -> Void)?
    private var lastSelectionBarInputs: SelectionBarClearance.Inputs?
    private var selectionBarPlacePending = false

    /// Decides the selection bar's place when its inputs change
    /// (`SelectionBarClearance.step`). Called at the end of every update.
    func keepSelectionClearOfBar(in pdfView: PDFView, framedThisPass: Bool) {
        guard let state = redactionState else { return }
        let inputs = SelectionBarClearance.Inputs(
            selectedIDs: state.selectedRegionIDs,
            regionVersion: state.regionVersion,
            bar: selectionBarFrame,
            canvasSize: pdfView.bounds.size,
            pageIndex: documentState?.currentPageIndex ?? 0)
        let changed = inputs != lastSelectionBarInputs
        lastSelectionBarInputs = inputs
        if selectionBarFrame == nil { selectionBarPlacePending = false }
        let scrollView = pdfView.subviews.first { $0 is UIScrollView } as? UIScrollView
        let scrolling = scrollView.map { $0.isDragging || $0.isDecelerating || $0.isZooming || $0.isZoomBouncing } ?? false
        switch SelectionBarClearance.step(
            inputsChanged: changed, barUp: selectionBarFrame != nil, fingerDown: canvasHoldsTouch,
            personScrolling: scrolling, framedThisPass: framedThisPass) {
        case .none: break
        case .drop: selectionBarPlacePending = false
        case .wait: selectionBarPlacePending = true
        case .run:
            selectionBarPlacePending = false
            placeSelectionBar(in: pdfView)
        }
    }

    /// The selected boxes on the page in view, in the PDF view's points,
    /// with the page's frame there. A region is kept in the frame the page
    /// is shown in, so it is turned back to the stored page first, as the
    /// overlay draws it.
    func selectedBoxesInView(_ pdfView: PDFView) -> (boxes: [CGRect], page: CGRect)? {
        guard let state = redactionState, let document = pdfView.document else { return nil }
        let index = documentState?.currentPageIndex ?? 0
        guard let page = document.page(at: index) else { return nil }
        let pageBounds = page.bounds(for: pdfView.displayBox)
        let boxes = (state.regions[index] ?? [])
            .filter { state.selectedRegionIDs.contains($0.id) }
            .map { pdfView.convert(PDFDocumentView.pageRect(forShown: $0.normalizedRect, on: page, box: pdfView.displayBox),
                                   from: page) }
        return (boxes, pdfView.convert(pageBounds, from: page))
    }

    /// Hands out the bar's place one turn later: the update pass that
    /// decided it writes no SwiftUI state.
    private func placeSelectionBar(in pdfView: PDFView) {
        guard let bar = selectionBarFrame, let read = selectedBoxesInView(pdfView) else { return }
        let atTop = SelectionBarClearance.barAtTop(
            selection: SelectionBarClearance.selectionRect(boxes: read.boxes, page: read.page),
            bottomBar: bar, canvas: pdfView.bounds)
        Task { @MainActor [weak self] in
            // A bar taken down before this turn hears nothing: the next bar
            // starts at the bottom and is measured there.
            guard let self, self.selectionBarFrame != nil else { return }
            self.onSelectionBarPlace?(atTop)
        }
    }

    /// The one home for when one finger scrolls: while the Rectangle tool
    /// is on, or while the overlay holds a one-finger touch it claimed, one
    /// finger draws, moves or resizes, so PDFKit's scroll pan needs two
    /// fingers. The pinch is untouched.
    private func applyScrollFingers() {
        if let pdfView, let scrollView = Self.innerScrollView(of: pdfView) {
            scrollView.panGestureRecognizer.minimumNumberOfTouches = isDrawingMode || canvasHoldsTouch ? 2 : 1
        }
    }

    /// Propagate the iPhone "Select More" toolbar toggle to all
    /// active overlays. Layers on top of the existing selection model —
    /// touchesBegan honors `isMultiSelectActive || shiftHeld` so iPad
    /// hardware-keyboard users keep their Shift+tap path unchanged.
    func updateMultiSelectMode(_ active: Bool) {
        isMultiSelectActive = active
        for (_, overlay) in activeOverlays {
            overlay.isMultiSelectActive = active
        }
    }

    /// Propagate the active shape tool to every overlay.
    func updateActiveShapeTool(_ tool: RedactionOverlayView.ShapeTool) {
        activeShapeTool = tool
        for (_, overlay) in activeOverlays {
            overlay.activeShapeTool = tool
        }
    }

    // MARK: - UIScribbleInteractionDelegate

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
