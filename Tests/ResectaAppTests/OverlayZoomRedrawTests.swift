import Testing
import Foundation
import CoreGraphics
import UIKit
import PDFKit
@testable import ResectaApp

// The overlay follows the zoom: the coordinator's scale observer asks every
// overlay it holds to redraw, so the marks sized in screen points take the
// new zoom's size because the zoom asked for it. The view is hosted in a
// window as the editor mounts it (`CanvasPageFrameTests`), with a two-page
// Letter document. The editor shows one page at a time, so PDFKit would
// install one overlay; each test asks the coordinator's provider for the
// pages it needs, which holds each overlay as the app does.

@Suite("Overlay redraw on a zoom", .serialized)
@MainActor
struct OverlayZoomRedrawTests {

    private static let canvas = CGRect(x: 0, y: 0, width: 402, height: 684)
    private static let letter = CGRect(x: 0, y: 0, width: 612, height: 792)

    /// The coordinator, its document state, the view and its window (kept
    /// so they outlive the assertions).
    private struct Mounted {
        let coordinator: PDFViewCoordinator
        let state: DocumentState
        let view: FitFlooredPDFView
        let window: UIWindow
    }

    private func mounted() -> Mounted {
        let state = DocumentState()
        let coordinator = PDFViewCoordinator()
        coordinator.documentState = state
        let window = UIWindow(frame: Self.canvas)
        let view = FitFlooredPDFView(frame: window.bounds)
        view.autoScales = true
        view.displayMode = .singlePage
        let renderer = UIGraphicsPDFRenderer(bounds: Self.letter)
        view.document = PDFDocument(data: renderer.pdfData { ctx in
            ctx.beginPage()
            ctx.beginPage()
        })
        window.addSubview(view)
        window.isHidden = false
        view.layoutIfNeeded()
        coordinator.setupObservers(for: view)
        return Mounted(coordinator: coordinator, state: state, view: view, window: window)
    }

    /// The overlay the provider makes for `index`, held by the coordinator
    /// as in the app, with its frame set to the page's size (the provider
    /// makes it empty, and a view of no size is never drawn).
    private func overlay(_ m: Mounted, page index: Int) throws -> RedactionOverlayView {
        let page = try #require(m.view.document?.page(at: index))
        let made = m.coordinator.pdfView(m.view, overlayViewFor: page)
        let overlay = try #require(made as? RedactionOverlayView)
        overlay.frame = Self.letter
        return overlay
    }

    /// One scale-change notice from the mounted view, posted on the main
    /// actor (the observer is bound to that view).
    private func postScaleChange(_ m: Mounted) {
        NotificationCenter.default.post(name: .PDFViewScaleChanged, object: m.view)
    }

    /// Lets the main actor run for up to a second, until `done` reads true.
    private func settle(until done: () -> Bool) async {
        let deadline = Date().addingTimeInterval(1)
        while !done() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A tenth of a second more on the main actor, so a second delivery
    /// that would follow the first has its turn before the count is read.
    private func idle() async {
        try? await Task.sleep(for: .milliseconds(100))
    }

    @Test("A scale change marks the overlay for a redraw and counts one request")
    func markedOnScaleChange() async throws {
        let m = mounted()
        let overlay = try overlay(m, page: 0)
        overlay.layer.displayIfNeeded()
        #expect(!overlay.layer.needsDisplay())
        let before = overlay.zoomChangedCount

        postScaleChange(m)
        await settle(until: { overlay.zoomChangedCount > before })
        await idle()
        #expect(overlay.layer.needsDisplay())
        #expect(overlay.zoomChangedCount == before + 1)
    }

    @Test("A scale change marks every overlay the coordinator holds")
    func marksEveryOverlay() async throws {
        let m = mounted()
        let first = try overlay(m, page: 0)
        let second = try overlay(m, page: 1)
        let before = (first.zoomChangedCount, second.zoomChangedCount)

        postScaleChange(m)
        await settle(until: { first.zoomChangedCount > before.0 && second.zoomChangedCount > before.1 })
        await idle()
        #expect(first.zoomChangedCount == before.0 + 1)
        #expect(second.zoomChangedCount == before.1 + 1)
    }

    @Test("Ten scale changes in one turn give one draw pass")
    func oneDrawForTenChanges() async throws {
        let m = mounted()
        let overlay = try overlay(m, page: 0)
        overlay.layer.displayIfNeeded()
        let changes = overlay.zoomChangedCount
        let passes = overlay.drawPassCount

        for _ in 0..<10 { postScaleChange(m) }
        await settle(until: { overlay.zoomChangedCount >= changes + 10 })
        overlay.layer.displayIfNeeded()
        #expect(overlay.zoomChangedCount == changes + 10)
        #expect(overlay.drawPassCount == passes + 1, "marking, never drawing: one pass for ten changes")
    }

    /// Holds at main and at any later state: the box's line is drawn at
    /// the zoom of the pass that draws it, because `fingerScale` is read
    /// from the view's scale at each read. A later cache of the scale
    /// would turn this red. With the canvas line change landed, the widths
    /// read here become the line tokens' widths at the new `fingerScale`.
    @Test("After a zoom the next pass draws the box's line at the new scale")
    func widthsAtTheNewScale() async throws {
        let m = mounted()
        let overlay = try overlay(m, page: 0)
        m.view.addSubview(overlay)
        let fit = m.view.scaleFactorForSizeToFit
        #expect(fit > 0)
        m.view.scaleFactor = fit
        m.view.layoutIfNeeded()
        overlay.layer.displayIfNeeded()
        #expect(abs(overlay.fingerScale - 1 / m.view.scaleFactor) < 0.0001)
        let changes = overlay.zoomChangedCount
        let passes = overlay.drawPassCount

        m.view.scaleFactor = fit * 3.5
        m.view.layoutIfNeeded()
        let zoom = m.view.scaleFactor
        #expect(zoom > fit * 2, "the view took the zoom: \(zoom) at fit \(fit)")
        await settle(until: { overlay.zoomChangedCount > changes })
        #expect(overlay.zoomChangedCount > changes, "the zoom asked for a redraw")
        overlay.layer.displayIfNeeded()
        #expect(overlay.drawPassCount > passes, "one pass after the zoom")

        #expect(abs(overlay.fingerScale - 1 / zoom) < 0.0001)
        let selected = RedactionOverlayView.regionLineWidth(isSelected: true, fingerScale: overlay.fingerScale)
        let plain = RedactionOverlayView.regionLineWidth(isSelected: false, fingerScale: overlay.fingerScale)
        let selectedWidth = ResectaTokens.Canvas.lineSelected.width, restingWidth = ResectaTokens.Canvas.line.width
        #expect(abs(selected * zoom - selectedWidth) < 0.0001, "the selected line \(selectedWidth) screen points at \(zoom)")
        #expect(abs(plain * zoom - restingWidth) < 0.0001, "the resting line \(restingWidth) screen points at \(zoom)")
    }

    @Test("Setting up the observers twice still gives one request per scale change")
    func oneObserver() async throws {
        let m = mounted()
        m.coordinator.setupObservers(for: m.view)
        let overlay = try overlay(m, page: 0)
        let before = overlay.zoomChangedCount

        postScaleChange(m)
        await settle(until: { overlay.zoomChangedCount > before })
        await idle()
        #expect(overlay.zoomChangedCount == before + 1, "one observer, not two")
    }

    @Test("The scale observer holds neither the coordinator nor its overlays")
    func noLeak() async throws {
        weak var weakCoordinator: PDFViewCoordinator?
        weak var weakOverlay: RedactionOverlayView?
        do {
            let m = mounted()
            let overlay = try overlay(m, page: 0)
            weakCoordinator = m.coordinator
            weakOverlay = overlay
            postScaleChange(m)
            await settle(until: { overlay.zoomChangedCount > 0 })
            #expect(overlay.zoomChangedCount > 0, "the observer was live")
            m.view.removeFromSuperview()
            m.window.isHidden = true
        }
        await settle(until: { weakCoordinator == nil && weakOverlay == nil })
        #expect(weakCoordinator == nil, "the coordinator is released")
        #expect(weakOverlay == nil, "its overlay is released")
    }

    @Test("An overlay PDFKit has ended is no longer asked to redraw")
    func onlyHeldOverlays() async throws {
        let m = mounted()
        let ended = try overlay(m, page: 0)
        let held = try overlay(m, page: 1)
        let page = try #require(m.view.document?.page(at: 0))
        m.coordinator.pdfView(m.view, willEndDisplayingOverlayView: ended, for: page)
        let before = (ended.zoomChangedCount, held.zoomChangedCount)

        postScaleChange(m)
        await settle(until: { held.zoomChangedCount > before.1 })
        await idle()
        #expect(held.zoomChangedCount == before.1 + 1, "the notice arrived")
        #expect(ended.zoomChangedCount == before.0, "the ended overlay was not asked")
    }
}
