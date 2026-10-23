import Testing
import Foundation
import CoreGraphics
import PDFKit
import RedactionEngine
@testable import ResectaApp

// The coordinator's commit seams. A move or resize commit records a step
// only when the rect changed: a tap on an already-selected region ends
// its "drag" at the start point, and that commit must leave no Move or
// Resize undo step and no `regionVersion` bump behind. A page change
// keeps only the selected regions on the page in view, so a delete or a
// nudge never reaches a region the user can no longer see. The commit announcements name what
// happened to the region.

@Suite("Coordinator commit guard")
@MainActor
struct CoordinatorCommitGuardTests {

    private func seeded() -> (coordinator: PDFViewCoordinator, state: RedactionState, region: RedactionRegion) {
        let state = RedactionState()
        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.10, y: 0.10, width: 0.30, height: 0.05),
            source: .manual
        )
        state.addRegion(region, page: 0, undoManager: nil)
        let coordinator = PDFViewCoordinator()
        coordinator.redactionState = state
        return (coordinator, state, region)
    }

    @Test("A move commit at the stored rect records no step")
    func moveAtTheStoredRectIsANoOp() {
        let (coordinator, state, region) = seeded()
        let undoManager = UndoManager()
        let version = state.regionVersion
        coordinator.commitMove(region.id, page: 0, newRect: region.normalizedRect, undoManager: undoManager)
        #expect(undoManager.canUndo == false)
        #expect(state.regionVersion == version)
    }

    @Test("A resize commit at the stored rect records no step")
    func resizeAtTheStoredRectIsANoOp() {
        let (coordinator, state, region) = seeded()
        let undoManager = UndoManager()
        let version = state.regionVersion
        coordinator.commitResize(region.id, page: 0, newRect: region.normalizedRect, undoManager: undoManager)
        #expect(undoManager.canUndo == false)
        #expect(state.regionVersion == version)
    }

    @Test("A real move still records one undoable step")
    func aRealMoveRecords() {
        let (coordinator, state, region) = seeded()
        let undoManager = UndoManager()
        let moved = region.normalizedRect.offsetBy(dx: 0.05, dy: 0)
        coordinator.commitMove(region.id, page: 0, newRect: moved, undoManager: undoManager)
        #expect(undoManager.canUndo)
        #expect(state.regions[0]?.first?.normalizedRect == moved)
    }

    /// Two regions on page 0, both selected as a group.
    private func seededGroup() -> (coordinator: PDFViewCoordinator, state: RedactionState, first: RedactionRegion, second: RedactionRegion) {
        let (coordinator, state, first) = seeded()
        let second = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.10, y: 0.30, width: 0.30, height: 0.05),
            source: .manual
        )
        state.addRegion(second, page: 0, undoManager: nil)
        state.selectedRegionIDs = [first.id, second.id]
        return (coordinator, state, first, second)
    }

    @Test("A group move at the stored rects records no step")
    func groupMoveAtTheStoredRectsIsANoOp() {
        let (coordinator, state, first, second) = seededGroup()
        let undoManager = UndoManager()
        let version = state.regionVersion
        coordinator.commitMoveMultiple(
            [(id: first.id, newRect: first.normalizedRect), (id: second.id, newRect: second.normalizedRect)],
            page: 0,
            undoManager: undoManager
        )
        #expect(undoManager.canUndo == false)
        #expect(state.regionVersion == version)
    }

    @Test("A group move with one real change records one step and moves only that region")
    func groupMoveWithOneChangeMovesOnlyThatRegion() {
        let (coordinator, state, first, second) = seededGroup()
        let undoManager = UndoManager()
        let moved = second.normalizedRect.offsetBy(dx: 0.05, dy: 0)
        coordinator.commitMoveMultiple(
            [(id: first.id, newRect: first.normalizedRect), (id: second.id, newRect: moved)],
            page: 0,
            undoManager: undoManager
        )
        #expect(undoManager.canUndo)
        #expect(state.regions[0]?.first(where: { $0.id == second.id })?.normalizedRect == moved)
        #expect(state.regions[0]?.first(where: { $0.id == first.id })?.normalizedRect == first.normalizedRect)
        undoManager.undo()
        #expect(state.regions[0]?.first(where: { $0.id == second.id })?.normalizedRect == second.normalizedRect)
        #expect(undoManager.canUndo == false)
    }

    /// A two-page view wired to the coordinator, as the editor mounts it.
    private func twoPageView(
        _ coordinator: PDFViewCoordinator,
        documentState: DocumentState
    ) -> (window: UIWindow, view: FitFlooredPDFView) {
        coordinator.documentState = documentState
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 684))
        let view = FitFlooredPDFView(frame: window.bounds)
        view.displayMode = .singlePage
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        view.document = PDFDocument(data: renderer.pdfData { ctx in
            ctx.beginPage()
            ctx.beginPage()
        })
        window.addSubview(view)
        window.isHidden = false
        view.layoutIfNeeded()
        coordinator.setupObservers(for: view)
        return (window, view)
    }

    @Test("An arrow nudge at the page edge records no step")
    func arrowNudgeAtThePageEdgeIsANoOp() {
        let state = RedactionState()
        let region = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.70, y: 0.10, width: 0.30, height: 0.05),
            source: .manual
        )
        state.addRegion(region, page: 0, undoManager: nil)
        let undoManager = UndoManager()
        let version = state.regionVersion
        let step = DocumentEditorView.nudgeDelta(pageSize: CGSize(width: 612, height: 792))
        let nudged = DocumentEditorView.nudgedRect(region.normalizedRect, dx: step.dx, dy: 0)
        #expect(nudged == region.normalizedRect, "the clamp holds the region at the right edge")
        state.moveRegion(region.id, page: 0, newRect: nudged, undoManager: undoManager)
        #expect(undoManager.canUndo == false)
        #expect(state.regionVersion == version)
    }

    @Test("A page change keeps only the selected regions on the page in view")
    func pageChangeKeepsOnlyTheVisiblePageSelection() {
        let (coordinator, state, firstPageRegion) = seeded()
        let secondPageRegion = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: 0.20, y: 0.40, width: 0.30, height: 0.05),
            source: .manual
        )
        state.addRegion(secondPageRegion, page: 1, undoManager: nil)
        let ghost = UUID()
        let documentState = DocumentState()
        let (window, view) = twoPageView(coordinator, documentState: documentState)
        state.selectedRegionIDs = [firstPageRegion.id, secondPageRegion.id, ghost]

        guard let second = view.document?.page(at: 1) else {
            Issue.record("the two-page fixture lost its second page")
            return
        }
        // The page bar's route: the index is written first, then the view
        // follows it (`PDFDocumentView.updateUIView` calls `go(to:)`).
        documentState.currentPageIndex = 1
        view.go(to: second)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        #expect(documentState.currentPageIndex == 1)
        #expect(state.selectedRegionIDs == [secondPageRegion.id])
        _ = window
    }

    @Test("A page-changed notice on the page in view keeps the selection")
    func samePageNoticeKeepsTheSelection() {
        let (coordinator, state, region) = seeded()
        let documentState = DocumentState()
        let (window, view) = twoPageView(coordinator, documentState: documentState)
        state.selectedRegionIDs = [region.id]
        NotificationCenter.default.post(name: .PDFViewPageChanged, object: view)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        #expect(documentState.currentPageIndex == 0)
        #expect(state.selectedRegionIDs == [region.id])
        _ = window
    }

    @Test("Resize and delete commits announce what happened to the region")
    func commitAnnouncements() {
        #expect(PDFViewCoordinator.commitAnnouncement(.resized) == "Region resized")
        #expect(PDFViewCoordinator.commitAnnouncement(.deleted) == "Region deleted")
    }
}
