import Testing
import Foundation
import CoreGraphics
import UIKit
import PDFKit
@testable import ResectaApp
import RedactionEngine

// No run starts while the canvas holds a touch. During a move, a group
// move, a resize or a draw, the box on screen is the overlay's working
// copy, and the stored regions change only when the finger lifts. A run
// started in between (⇧⌘R on a hardware keyboard, a second finger on
// Redact) would burn the stored place, not the place on the screen. So the
// run funnel refuses, silently, while any live overlay holds a touch, and
// the door opens again at the lift, at a cancel (a system gesture or an
// alert taking the touch), when the app goes to the background, and when
// PDFKit ends the overlay: a touch left held would leave Redact dead. The
// run reads the canvas once more where it fixes its boxes, after the
// capture it waits on, so a finger that came down in between ends it.
//
// The editor here is the real one, minus SwiftUI: the run coordinator, and
// the canvas coordinator on the same document and region state, its
// overlay installed by PDFKit in a fit-floored PDF view in a window. The
// touches go through the overlay's own touch handlers.

@Suite("Run door while the canvas holds a touch", .tags(.coordination))
@MainActor
struct RunDoorHeldTouchTests {

    /// The two boxes on page 1, as shares of the page (bottom-left origin).
    static let upper = CGRect(x: 0.2, y: 0.6, width: 0.3, height: 0.1)
    static let lower = CGRect(x: 0.2, y: 0.3, width: 0.3, height: 0.1)

    @MainActor
    final class Editor {
        let pipeline: PipelineCoordinator
        let canvas: PDFViewCoordinator
        let window: UIWindow
        let view: FitFlooredPDFView
        let page: PDFPage
        let overlay: RedactionOverlayView
        let toasts: ToastQueueManager
        let upperID: UUID
        let lowerID: UUID

        var state: RedactionState { pipeline.redactionState }

        init() throws {
            let document = makeTestPDFDocument()
            let pipeline = makeLoadedCoordinator(document: document)
            pipeline.settingsState.paranoidMode = false
            pipeline.settingsState.autoVerify = false
            let toasts = ToastQueueManager()
            pipeline.toastManager = toasts
            let upper = RedactionRegion(id: UUID(), normalizedRect: RunDoorHeldTouchTests.upper, source: .manual)
            let lower = RedactionRegion(id: UUID(), normalizedRect: RunDoorHeldTouchTests.lower, source: .manual)
            pipeline.redactionState.regions[0] = [upper, lower]

            let canvas = PDFViewCoordinator()
            canvas.documentState = pipeline.documentState
            canvas.redactionState = pipeline.redactionState
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
            let view = FitFlooredPDFView(frame: window.bounds)
            view.displayMode = .singlePage
            view.pageOverlayViewProvider = canvas
            view.document = document
            window.addSubview(view)
            window.isHidden = false
            let page = try #require(document.page(at: 0))
            view.go(to: page)
            view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let overlay = try #require(Self.overlays(in: view).first { $0.pageIndex == 0 },
                                       "PDFKit installed the canvas's overlay for page 1")

            self.pipeline = pipeline
            self.canvas = canvas
            self.window = window
            self.view = view
            self.page = page
            self.overlay = overlay
            self.toasts = toasts
            self.upperID = upper.id
            self.lowerID = lower.id
        }

        private static func overlays(in view: UIView) -> [RedactionOverlayView] {
            view.subviews.flatMap { ($0 as? RedactionOverlayView).map { [$0] } ?? overlays(in: $0) }
        }

        /// Selects `ids` in the state and on the overlay, as the editor's
        /// state sync would.
        func select(_ ids: Set<UUID>) {
            state.selectedRegionIDs = ids
            overlay.configure(with: state.regions[0] ?? [], selectedIDs: ids)
        }

        /// The box's rectangle in the overlay's space.
        func onCanvas(_ share: CGRect) -> CGRect { overlay.pdfNormalizedToOverlay(share) }

        /// A finger goes down at `start` and travels to `end` in four steps,
        /// and stays down. Returns the touch, still held.
        func hold(from start: CGPoint, to end: CGPoint) -> StubTouch {
            let touch = StubTouch(location: start, view: overlay)
            overlay.touchesBegan([touch], with: nil)
            for step in 1...4 {
                let t = CGFloat(step) / 4
                touch.move(to: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
                overlay.touchesMoved([touch], with: nil)
            }
            return touch
        }

        /// Redact, through the funnel every route reaches. True when a run
        /// started; the run is then stopped so a red case leaves nothing
        /// running into the next.
        func redact() async -> Bool {
            pipeline.runFullPipeline(documentOverride: .secureRasterization)
            guard let task = pipeline.documentState.activePipelineTask else { return false }
            pipeline.documentState.cancelActivePipeline(redactionState: state)
            _ = await task.value
            return true
        }

        func stored(_ id: UUID) -> CGRect? { state.regions[0]?.first { $0.id == id }?.normalizedRect }
    }

    /// The four gestures that put a box on screen away from its stored
    /// place, or a new one not yet stored.
    nonisolated enum Gesture: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case move, resize, groupMove, draw
        var testDescription: String { rawValue }
    }

    /// Starts `gesture` and holds it past its slop. Returns the touch, still down.
    private func begin(_ gesture: Gesture, on editor: Editor) throws -> StubTouch {
        let box = editor.onCanvas(Self.upper)
        let centre = CGPoint(x: box.midX, y: box.midY)
        switch gesture {
        case .move:
            editor.select([editor.upperID])
            let touch = editor.hold(from: centre, to: CGPoint(x: centre.x + 60, y: centre.y + 40))
            try #require(editor.overlay.regions.first { $0.id == editor.upperID }?.normalizedRect != Self.upper,
                         "the box on screen has left its stored place")
            return touch
        case .resize:
            editor.select([editor.upperID])
            let corner = RedactionOverlayView.handlePoint(.bottomRight, in: box)
            try #require(editor.overlay.hitTestResizeHandle(at: corner) != nil, "the touch lands on a handle")
            let touch = editor.hold(from: corner, to: CGPoint(x: corner.x + 50, y: corner.y + 30))
            try #require(editor.overlay.regions.first { $0.id == editor.upperID }?.normalizedRect != Self.upper,
                         "the box on screen has changed size")
            return touch
        case .groupMove:
            editor.select([editor.upperID, editor.lowerID])
            let touch = editor.hold(from: centre, to: CGPoint(x: centre.x + 60, y: centre.y + 40))
            try #require(editor.overlay.regions.first { $0.id == editor.lowerID }?.normalizedRect != Self.lower,
                         "the group on screen has left its stored place")
            return touch
        case .draw:
            editor.overlay.isDrawingMode = true
            let bounds = editor.overlay.bounds
            let start = CGPoint(x: bounds.width * 0.6, y: bounds.height * 0.05)
            let touch = editor.hold(from: start, to: CGPoint(x: start.x + 120, y: start.y + 60))
            try #require(editor.overlay.currentDragRect != nil, "the rubber band is out")
            return touch
        }
    }

    /// The stored boxes are the two from the start, where they were.
    private func expectStoredAsAtStart(_ editor: Editor, _ what: Comment) {
        #expect(editor.state.regions[0]?.count == 2, what)
        #expect(editor.stored(editor.upperID) == Self.upper, what)
        #expect(editor.stored(editor.lowerID) == Self.lower, what)
    }

    @Test("A touch held on the canvas refuses the run, silently", arguments: Gesture.allCases)
    func heldTouchRefusesTheRun(_ gesture: Gesture) async throws {
        let editor = try Editor()
        let touch = try begin(gesture, on: editor)
        let started = await editor.redact()
        #expect(!started, "held \(gesture.rawValue): no run")
        #expect(editor.pipeline.documentState.phaseKind == .editing)
        expectStoredAsAtStart(editor, "held \(gesture.rawValue): nothing stored mid-gesture")
        #expect(editor.toasts.activeToasts.isEmpty, "the refusal says nothing")
        editor.overlay.touchesCancelled([touch], with: nil)
        withExtendedLifetime(editor) {}
    }

    @Test("After the lift the run starts, on the place shown", arguments: [Gesture.move, .resize, .groupMove])
    func liftedTouchOpensTheDoor(_ gesture: Gesture) async throws {
        let editor = try Editor()
        let touch = try begin(gesture, on: editor)
        let shown = editor.overlay.regions
        editor.overlay.touchesEnded([touch], with: nil)
        // The door reads only the held touch, so it rests on this: once the
        // finger is up, the boxes on screen are the stored page's.
        #expect(editor.state.regions[0] == shown, "the lift stored the boxes on screen (\(gesture.rawValue))")
        #expect(editor.overlay.regions == editor.state.regions[0], "after the lift the overlay shows the stored page")
        let started = await editor.redact()
        #expect(started, "the door is open after the lift of a \(gesture.rawValue)")
        withExtendedLifetime(editor) {}
    }

    @Test("After a system cancel the run starts, on the places from before the gesture", arguments: Gesture.allCases)
    func cancelledTouchOpensTheDoor(_ gesture: Gesture) async throws {
        let editor = try Editor()
        let touch = try begin(gesture, on: editor)
        // A system gesture, an alert or a call takes the touch: UIKit cancels it.
        editor.overlay.touchesCancelled([touch], with: nil)
        #expect(editor.overlay.regions.first { $0.id == editor.upperID }?.normalizedRect == Self.upper,
                "the cancel put the box back")
        expectStoredAsAtStart(editor, "cancelled \(gesture.rawValue)")
        #expect(editor.overlay.regions == editor.state.regions[0], "after the cancel the overlay shows the stored page")
        let started = await editor.redact()
        #expect(started, "the door is open after a cancel of a \(gesture.rawValue)")
        withExtendedLifetime(editor) {}
    }

    @Test("Going to the background mid-gesture lets the touch go, and the run starts", arguments: Gesture.allCases)
    func backgroundOpensTheDoor(_ gesture: Gesture) async throws {
        let editor = try Editor()
        _ = try begin(gesture, on: editor)
        // No lift and no cancel arrive: only the app's move to the background.
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(editor.overlay.regions.first { $0.id == editor.upperID }?.normalizedRect == Self.upper,
                "the gesture was discarded, the box back in place")
        expectStoredAsAtStart(editor, "\(gesture.rawValue) at the background")
        let started = await editor.redact()
        #expect(started, "the door is open after the background, from a \(gesture.rawValue)")
        withExtendedLifetime(editor) {}
    }

    @Test("A finger down on the canvas while the run's entry is read ends the run")
    func touchDuringTheRunEntryEndsTheRun() async throws {
        let editor = try Editor()
        let settings = PipelineCoordinator.RunSettings.snapshot(from: editor.pipeline.settingsState)
        // The control: with no finger down the entry is read.
        let entry = try await PipelineRunner.captureRunEntry(
            coordinator: editor.pipeline, effectiveMode: .secureRasterization, runSettings: settings,
            capture: { await editor.pipeline.collectSensitiveTermSet(planInk: false) })
        #expect(!entry.pages.isEmpty)
        // A finger comes down and moves a box while the capture runs, after
        // the funnel let the run in.
        editor.select([editor.upperID])
        let box = editor.onCanvas(Self.upper)
        final class Held { var touch: StubTouch? }
        let held = Held()
        await #expect(throws: CancellationError.self) {
            _ = try await PipelineRunner.captureRunEntry(
                coordinator: editor.pipeline, effectiveMode: .secureRasterization, runSettings: settings,
                capture: {
                    held.touch = editor.hold(from: CGPoint(x: box.midX, y: box.midY), to: CGPoint(x: box.midX + 60, y: box.midY + 40))
                    return await editor.pipeline.collectSensitiveTermSet(planInk: false)
                })
        }
        if let touch = held.touch { editor.overlay.touchesCancelled([touch], with: nil) }
        withExtendedLifetime(editor) {}
    }

    @Test("An overlay PDFKit has ended holds nothing")
    func endedOverlayHoldsNothing() async throws {
        let editor = try Editor()
        _ = try begin(.move, on: editor)
        editor.canvas.pdfView(editor.view, willEndDisplayingOverlayView: editor.overlay, for: editor.page)
        let started = await editor.redact()
        #expect(started, "an ended overlay's touch does not hold the door")
        withExtendedLifetime(editor) {}
    }
}
