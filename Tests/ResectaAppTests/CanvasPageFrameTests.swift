import Testing
import Foundation
import CoreGraphics
import UIKit
import PDFKit
@testable import ResectaApp

// The canvas's page frames for the editor's notice band. The coordinator
// writes the visible pages' rectangles to the document's state only while
// a notice wants them, and only when their whole-point values change; with
// no notice up it writes nothing. The view is hosted in a window as the
// editor mounts it (`CoordinatorCommitGuardTests.twoPageView`), on the
// iPhone 17 editor canvas (402 by 684) with a Letter page.

@Suite("Canvas page frames for the notice band", .serialized)
@MainActor
struct CanvasPageFrameTests {

    private static let canvas = CGRect(x: 0, y: 0, width: 402, height: 684)

    /// The coordinator, its document state, the view and its window (kept
    /// so it outlives the assertions).
    private func mounted() -> (coordinator: PDFViewCoordinator, state: DocumentState,
                               view: FitFlooredPDFView, window: UIWindow) {
        let state = DocumentState()
        let coordinator = PDFViewCoordinator()
        coordinator.documentState = state
        let window = UIWindow(frame: Self.canvas)
        let view = FitFlooredPDFView(frame: window.bounds)
        view.autoScales = true
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
        return (coordinator, state, view, window)
    }

    /// Lets the main actor run the publishes asked for, for up to a second,
    /// until `done` reads true.
    private func settle(until done: () -> Bool) async {
        let deadline = Date().addingTimeInterval(1)
        while !done() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("The canvas publishes page frames only while a notice is up")
    func publishesOnlyWhileWanted() {
        let (coordinator, state, view, _) = mounted()
        let fit = view.scaleFactorForSizeToFit
        #expect(fit > 0)
        #expect(!state.canvasPageFramesWanted)
        for call in 0..<100 {
            view.scaleFactor = fit * (1 + CGFloat(call % 3) * 0.5)
            view.layoutIfNeeded()
            coordinator.publishPageFrames()
        }
        #expect(state.canvasPageFrames.isEmpty)
        #expect(coordinator.pageFramePublishCount == 0)

        state.canvasPageFramesWanted = true
        coordinator.publishPageFrames()
        #expect(coordinator.pageFramePublishCount == 1)
        #expect(!state.canvasPageFrames.isEmpty)

        coordinator.publishPageFrames()
        #expect(coordinator.pageFramePublishCount == 1, "the same frames again: no second write")
    }

    @Test("A published frame is the visible page on the canvas, in whole points")
    func frameIsTheVisiblePage() {
        let (coordinator, state, _, _) = mounted()
        state.canvasPageFramesWanted = true
        coordinator.publishPageFrames()
        #expect(state.canvasPageFrames.count == 1, "one page shows at a time at fit")
        for frame in state.canvasPageFrames {
            #expect(frame.minX >= 0 && frame.minY >= 0, "\(frame)")
            #expect(frame.maxX <= 402 && frame.maxY <= 684, "\(frame)")
            #expect(frame.maxX - frame.minX > 300, "a Letter page at fit is nearly the canvas's width: \(frame)")
            #expect(frame.maxY - frame.minY > 300, "\(frame)")
        }
    }

    @Test("A zoom with a notice up publishes on the next turn, not inside the zoom; with none it publishes nothing")
    func zoomPublishesOnTheNextTurn() async {
        let (coordinator, state, view, _) = mounted()
        let fit = view.scaleFactorForSizeToFit

        view.scaleFactor = fit * 2
        view.layoutIfNeeded()
        await settle(until: { false })
        #expect(coordinator.pageFramePublishCount == 0)
        #expect(state.canvasPageFrames.isEmpty)

        view.scaleFactor = fit
        view.layoutIfNeeded()
        state.canvasPageFramesWanted = true
        coordinator.publishPageFrames()
        #expect(coordinator.pageFramePublishCount == 1)
        let atFit = state.canvasPageFrames

        view.scaleFactor = fit * 2
        view.layoutIfNeeded()
        #expect(coordinator.pageFramePublishCount == 1, "nothing is written inside the zoom itself")
        await settle(until: { coordinator.pageFramePublishCount > 1 })
        #expect(coordinator.pageFramePublishCount >= 2)
        #expect(state.canvasPageFrames != atFit)
    }

    @Test("A page change at a zoom that fills the canvas is published: the same rectangle, another page")
    func pageChangeAtAFillingZoomIsPublished() async throws {
        let (coordinator, state, view, _) = mounted()
        view.scaleFactor = view.scaleFactorForSizeToFit * 3
        view.layoutIfNeeded()
        state.canvasPageFramesWanted = true
        coordinator.publishPageFrames()
        let frames = state.canvasPageFrames, count = coordinator.pageFramePublishCount
        #expect(state.canvasPageIndices == [0])
        view.go(to: try #require(view.document?.page(at: 1)))
        view.layoutIfNeeded()
        await settle(until: { state.canvasPageIndices == [1] })
        #expect(state.canvasPageFrames == frames, "precondition: the zoomed page fills the canvas, so its rectangle is the same")
        #expect(state.canvasPageIndices == [1], "the page change is published")
        #expect(coordinator.pageFramePublishCount > count)
    }

    @Test("Turning the page frames off empties them, and a new document's state starts with none")
    func turningOffEmptiesTheFrames() {
        let state = DocumentState()
        #expect(state.canvasPageFrames.isEmpty && state.canvasPageIndices.isEmpty)
        #expect(!state.canvasPageFramesWanted)
        state.canvasPageFramesWanted = true
        state.canvasPageFrames = [CanvasRect(minX: 0, minY: 82, maxX: 402, maxY: 602)]
        state.canvasPageIndices = [0]
        state.canvasPageFramesWanted = false
        #expect(state.canvasPageFrames.isEmpty)
        #expect(state.canvasPageIndices.isEmpty)
    }
}
