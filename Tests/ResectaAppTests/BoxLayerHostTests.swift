import PDFKit
import Testing
import UIKit
@testable import ResectaApp
@testable import RedactionEngine

// The boxes' layers through the real overlay: which keys a pass applies for
// each kind of change, the groups they lie in, that a pass runs once a
// turn in the container's layout and moves nothing with an animation, and
// that the layers lie on the screen's pixel lines once there is a window.
// The touches are the harness's (`CanvasTouchHarness.swift`); its
// coordinator records the commits without making them, so the stored
// regions stay as they were.

@MainActor
@Suite("The boxes' layers: what a pass applies, and where")
struct BoxLayerHostTests {

    static let pageSize = CGSize(width: 612, height: 792)

    /// A box in overlay points (top-left origin) as a stored region.
    static func region(_ rect: CGRect) -> RedactionRegion {
        RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: rect.minX / pageSize.width, y: 1 - rect.maxY / pageSize.height,
                                   width: rect.width / pageSize.width, height: rect.height / pageSize.height),
            source: .manual)
    }

    /// The region ids of a pass's keys.
    static func ids(_ keys: [String]) -> Set<String> { Set(keys.map { String(BoxLayerHost.regionID(of: $0)) }) }

    struct Canvas {
        let window: UIWindow
        let overlay: RedactionOverlayView
        let coordinator: RecordingCoordinator
        let state: RedactionState
        var host: BoxLayerHost { overlay.boxLayers }

        /// Runs the pass asked for, as the container's layout does.
        func flush() { host.root.layoutIfNeeded() }

        /// The group a key's layer lies in.
        func group(of key: String) -> BoxLayerGroup? {
            guard let parent = host.layers[key]?.superlayer else { return nil }
            return host.groupLayers.first { $0.value === parent }?.key
        }

        /// The moving group's layers.
        var moving: [CALayer] { host.groupLayers[.moving]?.sublayers ?? [] }
    }

    /// A canvas placed by PDFKit on a one-page Letter document, in a window,
    /// with the coordinator keeping plans as the editor does.
    static func placed(_ regions: [RedactionRegion], selected: Set<UUID>, suite: String) throws -> Canvas {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize)).pdfData { $0.beginPage() }
        let document = try #require(PDFDocument(data: data))
        let state = RedactionState()
        for r in regions { state.addRegion(r, page: 0, undoManager: nil) }
        state.selectedRegionIDs = selected
        let documentState = DocumentState()
        documentState.sourceDocument = document
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsState(defaults: defaults)
        settings.exportDPI = 300
        let coordinator = RecordingCoordinator()
        coordinator.redactionState = state
        coordinator.documentState = documentState
        coordinator.settingsState = settings
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let view = FitFlooredPDFView(frame: window.bounds)
        view.displayMode = .singlePage
        view.pageOverlayViewProvider = coordinator
        view.document = document
        window.addSubview(view)
        window.isHidden = false
        view.go(to: try #require(document.page(at: 0)))
        view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let overlay = try #require(ScreenLinkTests.overlays(in: view).first { $0.pageIndex == 0 },
                                   "PDFKit installed the coordinator's overlay")
        try #require(overlay.isPlacedOnItsPage, "the page is placed")
        overlay.configure(with: state.regions[0] ?? [], selectedIDs: selected)
        let canvas = Canvas(window: window, overlay: overlay, coordinator: coordinator, state: state)
        canvas.flush()
        return canvas
    }

    /// A canvas of the page's size with no PDF view (so no fill, the boxes
    /// drawn by their lines), in a window when `inWindow`.
    static func mounted(_ regions: [RedactionRegion], selected: Set<UUID>, inWindow: Bool = true) -> Canvas {
        let state = RedactionState()
        for r in regions { state.addRegion(r, page: 0, undoManager: nil) }
        let coordinator = RecordingCoordinator()
        coordinator.redactionState = state
        let window = UIWindow(frame: CGRect(origin: .zero, size: pageSize))
        let overlay = RedactionOverlayView(frame: window.bounds)
        overlay.geometry = .testUnturned
        overlay.pageIndex = 0
        overlay.snapZoomScaleOverride = 0.64
        overlay.coordinator = coordinator
        overlay.configure(with: regions, selectedIDs: selected)
        if inWindow {
            window.addSubview(overlay)
            window.isHidden = false
        }
        // The handles' scale animation, run to its end, so a pass shows them.
        let target: CGFloat = selected.count == 1 ? 1 : 0
        let end = Date().addingTimeInterval(2)
        while overlay.handleScale != target, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        let canvas = Canvas(window: window, overlay: overlay, coordinator: coordinator, state: state)
        canvas.flush()
        return canvas
    }

    /// The centre of a region's box, in overlay points.
    static func centre(_ c: Canvas, _ r: RedactionRegion) -> CGPoint {
        let rect = c.overlay.pdfNormalizedToOverlay(r.normalizedRect)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    // MARK: - c1 to c4: a touch's keys

    @Test("c1: each touch of a move applies the moved box's keys, in the moving group with the lift's shadow, and nothing of a box it leaves alone")
    func moveAppliesTheMovedBox() throws {
        let a = Self.region(CGRect(x: 80, y: 120, width: 200, height: 120))
        let far = Self.region(CGRect(x: 80, y: 560, width: 200, height: 100))
        let c = try Self.placed([a, far], selected: [a.id], suite: "BoxLayerHostTests.c1")
        let start = Self.centre(c, a)
        let touch = StubTouch(location: start, view: c.overlay)
        c.overlay.touchesBegan([touch], with: nil)
        try #require(c.overlay.isDraggingExistingRegion, "touch-down inside the selected box begins a move")
        for step in 1...3 {
            touch.move(to: CGPoint(x: start.x + CGFloat(step) * 6, y: start.y + CGFloat(step) * 4))
            c.overlay.touchesMoved([touch], with: nil)
            let before = c.host.boxPassCount
            c.flush()
            #expect(c.host.boxPassCount == before + 1, "touch \(step): one pass")
            let applied = Self.ids(c.host.lastAppliedKeys)
            #expect(applied == [a.id.uuidString], "touch \(step): the moved box's keys alone, not \(applied)")
            let veil = "veil:\(a.id)"
            #expect(c.group(of: veil) == .moving, "touch \(step): the moved box's veil is in the moving group")
            let shadow = c.host.layers[veil]?.shadowOpacity ?? 0
            #expect(shadow > 0, "touch \(step): with the lift's shadow")
        }
        c.overlay.touchesCancelled([touch], with: nil)
        withExtendedLifetime(c.window) {}
    }

    @Test("c2: a group move of three boxes applies those three boxes' keys; none is in the moving group; each veil is in the veils' group once")
    func groupMoveAppliesTheThree() throws {
        let boxes = [CGRect(x: 60, y: 100, width: 140, height: 90), CGRect(x: 260, y: 100, width: 140, height: 90),
                     CGRect(x: 60, y: 300, width: 140, height: 90)].map(Self.region)
        let still = Self.region(CGRect(x: 300, y: 560, width: 200, height: 100))
        let chosen = Set(boxes.map(\.id))
        let c = try Self.placed(boxes + [still], selected: chosen, suite: "BoxLayerHostTests.c2")
        let start = Self.centre(c, boxes[0])
        let touch = StubTouch(location: start, view: c.overlay)
        c.overlay.touchesBegan([touch], with: nil)
        for step in 1...3 {
            touch.move(to: CGPoint(x: start.x + CGFloat(step) * 10, y: start.y + CGFloat(step) * 8))
            c.overlay.touchesMoved([touch], with: nil)
        }
        try #require(c.overlay.isGroupMoving, "the touch moves the group")
        touch.move(to: CGPoint(x: start.x + 40, y: start.y + 32))
        c.overlay.touchesMoved([touch], with: nil)
        c.flush()
        let applied = Self.ids(c.host.lastAppliedKeys)
        #expect(applied == Set(chosen.map(\.uuidString)), "the three boxes' keys alone, not \(applied)")
        #expect(c.moving.isEmpty, "a group move lifts nothing")
        let veils = c.host.groupLayers[.veils]?.sublayers ?? []
        for box in boxes + [still] {
            let veil = c.host.layers["veil:\(box.id)"]
            let count = veils.filter { $0 === veil }.count
            #expect(veil != nil && count == 1, "one veil for each box in the veils' group")
        }
        c.overlay.touchesCancelled([touch], with: nil)
        withExtendedLifetime(c.window) {}
    }

    @Test("c3: a resize applies the box's keys in their own groups; nothing enters the moving group")
    func resizeAppliesTheBox() throws {
        let a = Self.region(CGRect(x: 120, y: 200, width: 220, height: 140))
        let far = Self.region(CGRect(x: 80, y: 560, width: 200, height: 100))
        let c = try Self.placed([a, far], selected: [a.id], suite: "BoxLayerHostTests.c3")
        let rect = c.overlay.pdfNormalizedToOverlay(a.normalizedRect)
        let handles = RedactionOverlayView.handleCentres(for: rect, fingerScale: c.overlay.fingerScale)
        let corner = try #require(handles.first { $0.0 == .bottomRight }?.1, "the bottom-right handle")
        let touch = StubTouch(location: corner, view: c.overlay)
        c.overlay.touchesBegan([touch], with: nil)
        touch.move(to: CGPoint(x: corner.x + 18, y: corner.y + 14))
        c.overlay.touchesMoved([touch], with: nil)
        try #require(c.overlay.activeResizeHandle != nil, "the touch resizes")
        c.flush()
        let applied = Self.ids(c.host.lastAppliedKeys)
        #expect(applied == [a.id.uuidString], "the box's keys alone, not \(applied)")
        #expect(c.moving.isEmpty, "a resize lifts nothing")
        #expect(c.group(of: "veil:\(a.id)") == .veils)
        c.overlay.touchesCancelled([touch], with: nil)
        withExtendedLifetime(c.window) {}
    }

    @Test("c4: a move cancelled, and a move ended, give a full pass with the moving group empty; the cancelled box is back at its place",
          arguments: [true, false])
    func moveEndGivesAFullPass(cancel: Bool) throws {
        let a = Self.region(CGRect(x: 80, y: 120, width: 200, height: 120))
        let b = Self.region(CGRect(x: 80, y: 560, width: 200, height: 100))
        let c = try Self.placed([a, b], selected: [a.id], suite: "BoxLayerHostTests.c4.\(cancel)")
        let veil = "veil:\(a.id)"
        let resting = c.host.layers[veil]?.frame
        let start = Self.centre(c, a)
        let touch = StubTouch(location: start, view: c.overlay)
        c.overlay.touchesBegan([touch], with: nil)
        touch.move(to: CGPoint(x: start.x + 30, y: start.y + 24))
        c.overlay.touchesMoved([touch], with: nil)
        c.flush()
        try #require(!c.moving.isEmpty, "precondition: the box is lifted")
        if cancel { c.overlay.touchesCancelled([touch], with: nil) } else { c.overlay.touchesEnded([touch], with: nil) }
        c.flush()
        let applied = Set(c.host.lastAppliedKeys)
        let owned = Set(c.host.layers.keys)
        #expect(applied == owned, "a full pass")
        #expect(c.moving.isEmpty, "the moving group is empty")
        if cancel {
            let back = c.host.layers[veil]?.frame
            #expect(back != nil && back == resting, "the cancelled box's veil is at its old place")
        }
        withExtendedLifetime(c.window) {}
    }

    // MARK: - c5, c6: no animation; one pass a turn

    @Test("c5: every layer the host owns moves without an animation")
    func everyLayerIsQuiet() {
        let a = Self.region(CGRect(x: 80, y: 120, width: 200, height: 120))
        let c = Self.mounted([a], selected: [a.id])
        let owned = [c.host.root] + Array(c.host.groupLayers.values) + Array(c.host.layers.values)
        #expect(c.host.layers.count > 3, "precondition: the box has layers")
        // The pass turns actions off for its own changes; a change made
        // outside it, such as a redrawn layer's contents, is kept quiet by
        // the layer's own actions: every property the host sets is in them
        // as NSNull. (action(forKey:) cannot tell: it gives nil for NSNull
        // and for a layer with no actions alike.)
        for layer in owned {
            for key in BoxLayerHost.quietActions.keys.sorted() {
                #expect(layer.actions?[key] is NSNull, "\(layer) has no quiet action for \(key)")
            }
        }
        for layer in owned {
            let frame = layer.frame, opacity = layer.opacity
            layer.frame = frame.offsetBy(dx: 3, dy: 2)
            layer.opacity = 0.5
            #expect(layer.animationKeys() == nil, "\(layer) animated")
            layer.frame = frame
            layer.opacity = opacity
        }
        withExtendedLifetime(c.window) {}
    }

    @Test("c6: ten marks of mixed scope in one turn give one pass, with the union of their keys, and no layout of the view")
    func tenMarksOnePass() {
        let a = Self.region(CGRect(x: 60, y: 100, width: 140, height: 90))
        let b = Self.region(CGRect(x: 260, y: 300, width: 140, height: 90))
        let rest = Self.region(CGRect(x: 60, y: 560, width: 140, height: 90))
        let c = Self.mounted([a, b, rest], selected: [b.id])
        c.overlay.layoutIfNeeded()
        let elements = c.overlay.accessibilityElements
        let first = elements?.first as AnyObject?
        let passes = c.host.boxPassCount
        for i in 0..<10 { c.host.mark(i % 2 == 0 ? .keys([a.id.uuidString]) : .handles) }
        c.flush()
        #expect(c.host.boxPassCount == passes + 1, "one pass for ten marks")
        let applied = c.host.lastAppliedKeys
        let wanted = c.host.layers.keys.filter {
            BoxLayerHost.regionID(of: $0) == Substring(a.id.uuidString) || BoxLayerHost.isHandleKey($0)
        }
        #expect(Set(applied) == Set(wanted), "the union: the first box's keys and the handles")
        let handles = applied.filter(BoxLayerHost.isHandleKey)
        #expect(!handles.isEmpty, "precondition: the selected box shows handles")
        let restKeys = applied.filter { BoxLayerHost.regionID(of: $0) == Substring(rest.id.uuidString) }
        #expect(restKeys.isEmpty, "nothing of the box no mark named")
        let after = c.overlay.accessibilityElements?.first as AnyObject?
        #expect(first != nil && first === after, "the view was not laid out: its elements are the same")
        withExtendedLifetime(c.window) {}
    }

    // MARK: - c8, c9: the keeper and the joins

    @Test("c8: a move feeds the keeper the working copy after a touch, and the lift gives a full pass")
    func moveFeedsTheKeeper() throws {
        let a = Self.region(CGRect(x: 80, y: 120, width: 200, height: 120))
        let c = try Self.placed([a], selected: [a.id], suite: "BoxLayerHostTests.c8")
        let stored = try #require(c.state.drawnPlans[0], "a pass kept the page's plan")
        let start = Self.centre(c, a)
        let touch = StubTouch(location: start, view: c.overlay)
        c.overlay.touchesBegan([touch], with: nil)
        touch.move(to: CGPoint(x: start.x + 30, y: start.y + 24))
        c.overlay.touchesMoved([touch], with: nil)
        c.flush()
        let moved = try #require(c.state.drawnPlans[0])
        #expect(moved != stored, "the keeper was fed the working copy after the touch")
        #expect(moved.fromStoredRegions == false)
        let passes = c.host.boxPassCount
        c.overlay.touchesEnded([touch], with: nil)
        c.flush()
        #expect(c.host.boxPassCount == passes + 1, "the lift's pass ran")
        let kept = c.state.drawnPlans[0]
        let ids = kept?.boxes.map(\.regionIDs)
        #expect(ids == [[a.id]], "the lift's pass kept the page's plan")
        #expect(c.coordinator.movedRegions.count == 1)
        withExtendedLifetime(c.window) {}
    }

    /// The overlay's own pass, with the plan boxes it is given in place of
    /// the kept plan's.
    @MainActor
    final class ScriptedPlanSource: BoxLayerSource {
        let overlay: RedactionOverlayView
        var planBoxes: [DrawnPlan.Box]
        init(_ overlay: RedactionOverlayView, planBoxes: [DrawnPlan.Box]) {
            self.overlay = overlay
            self.planBoxes = planBoxes
        }
        func boxLayerPass(toDevice: CGAffineTransform) -> BoxLayerPass {
            var pass = overlay.boxLayerPass(toDevice: toDevice)
            pass.planBoxes = planBoxes
            return pass
        }
    }

    @Test("c9: a touch on which another box's plan box changes, as when a join breaks, applies that box's keys on that touch")
    func breakingAJoinAppliesTheOther() throws {
        // The canvas's plan reads no page text, so no plan box on it holds
        // two regions; the change a broken join makes to the other member's
        // plan box is given by a scripted source.
        let a = Self.region(CGRect(x: 80, y: 120, width: 200, height: 120))
        let b = Self.region(CGRect(x: 80, y: 560, width: 200, height: 100))
        let c = try Self.placed([a, b], selected: [a.id], suite: "BoxLayerHostTests.c9")
        let kept = try #require(c.state.drawnPlans[0]).boxes
        var shifted = b
        shifted.normalizedRect = b.normalizedRect.offsetBy(dx: 0.05, dy: 0)
        c.coordinator.noteDrawn(pageIndex: 0, regions: [a, shifted])
        let changed = try #require(c.state.drawnPlans[0]).boxes
        let before = kept.first { $0.regionIDs.contains(b.id) }, after = changed.first { $0.regionIDs.contains(b.id) }
        try #require(before != nil && after != nil && before != after, "precondition: the other box's plan box changed")
        try #require(kept.first { $0.regionIDs.contains(a.id) } == changed.first { $0.regionIDs.contains(a.id) })
        let source = ScriptedPlanSource(c.overlay, planBoxes: kept)
        c.host.source = source
        c.host.mark(.keys([a.id.uuidString]))
        c.flush()
        #expect(Self.ids(c.host.lastAppliedKeys) == [a.id.uuidString], "precondition: the touched box's keys alone")
        source.planBoxes = changed
        c.host.mark(.keys([a.id.uuidString]))
        c.flush()
        let applied = Self.ids(c.host.lastAppliedKeys)
        #expect(applied.contains(b.id.uuidString), "the other box's keys were applied on the touch, not only \(applied)")
        c.host.mark(.keys([a.id.uuidString]))
        c.flush()
        #expect(Self.ids(c.host.lastAppliedKeys) == [a.id.uuidString], "with its plan box unchanged, the touched box's keys alone")
        c.host.source = c.overlay
        withExtendedLifetime((c.window, source)) {}
    }

    // MARK: - c10 to c15: groups, settings, windows

    @Test("c10: the veils' group carries the veils' opacity as a group; each veil is opaque")
    func veilsGroupCarriesTheOpacity() throws {
        let a = Self.region(CGRect(x: 80, y: 120, width: 200, height: 120))
        let b = Self.region(CGRect(x: 220, y: 180, width: 200, height: 120))
        let c = try Self.placed([a, b], selected: [], suite: "BoxLayerHostTests.c10")
        let group = try #require(c.host.groupLayers[.veils])
        // The system's setting is not set by a test: the value is read for
        // the one the simulator has. The 0.26 under Reduce Transparency is
        // pinned on the descriptions (BoxLayerSpecTests).
        let wanted: Float = UIAccessibility.isReduceTransparencyEnabled ? 0.26 : 0.18
        #expect(abs(group.opacity - wanted) < 1e-6, "the veils' group at \(wanted), not \(group.opacity)")
        #expect(group.allowsGroupOpacity)
        let veils = group.sublayers ?? []
        #expect(veils.count >= 2)
        for veil in veils { #expect(veil.opacity == 1, "a veil carries no opacity of its own") }
        withExtendedLifetime(c.window) {}
    }

    @Test("c11: the Reduce Transparency and Increase Contrast notices each give a full pass",
          arguments: [UIAccessibility.reduceTransparencyStatusDidChangeNotification,
                      UIAccessibility.darkerSystemColorsStatusDidChangeNotification])
    func settingNoticesGiveAFullPass(_ name: Notification.Name) {
        let a = Self.region(CGRect(x: 80, y: 120, width: 200, height: 120))
        let b = Self.region(CGRect(x: 80, y: 400, width: 200, height: 120))
        let c = Self.mounted([a, b], selected: [a.id])
        #expect(!c.host.isPassPending, "precondition: nothing is asked for")
        NotificationCenter.default.post(name: name, object: nil)
        #expect(c.host.isPassPending, "the notice asks for a pass")
        c.flush()
        #expect(Set(c.host.lastAppliedKeys) == Set(c.host.layers.keys), "a full pass")
        withExtendedLifetime(c.window) {}
    }

    @Test("c12: Add to Selection set to its own value asks for no pass; a change asks for one full pass")
    func addToSelectionAsksOnAChange() {
        let a = Self.region(CGRect(x: 80, y: 120, width: 200, height: 120))
        let c = Self.mounted([a], selected: [a.id])
        let passes = c.host.boxPassCount
        c.overlay.isMultiSelectActive = false
        #expect(!c.host.isPassPending, "the same value: no pass")
        c.overlay.isMultiSelectActive = true
        #expect(c.host.isPassPending)
        c.flush()
        #expect(c.host.boxPassCount == passes + 1, "one pass")
        #expect(Set(c.host.lastAppliedKeys) == Set(c.host.layers.keys), "a full pass")
        withExtendedLifetime(c.window) {}
    }

    @Test("c13: the container lies beneath the top canvas, has the overlay's bounds and clips to them")
    func containerClipsToTheOverlay() throws {
        let a = Self.region(CGRect(x: 0, y: 0, width: 200, height: 60))
        let c = try Self.placed([a], selected: [], suite: "BoxLayerHostTests.c13")
        #expect(c.host.root.masksToBounds)
        #expect(c.host.root.frame == c.overlay.bounds)
        #expect(c.overlay.layer.sublayers?.first === c.host.root, "the boxes lie beneath every subview")
        withExtendedLifetime(c.window) {}
    }

    @Test("c14: with no window a pass applies unsnapped frames and stays asked for; the window's arrival gives a snapped full pass")
    func noWindowThenAWindow() {
        let a = Self.region(CGRect(x: 80, y: 120, width: 200, height: 120))
        let c = Self.mounted([a], selected: [], inWindow: false)
        #expect(c.host.boxPassCount >= 1, "a pass ran with no window")
        #expect(c.host.deviceMap().unsnapped)
        #expect(c.host.isPassPending, "the pass is still asked for")
        let passes = c.host.boxPassCount
        c.window.addSubview(c.overlay)
        c.window.isHidden = false
        c.flush()
        #expect(c.host.boxPassCount == passes + 1)
        #expect(!c.host.deviceMap().unsnapped)
        #expect(!c.host.isPassPending, "on the pixel lines: nothing is left asked for")
        #expect(Set(c.host.lastAppliedKeys) == Set(c.host.layers.keys), "a full pass")
        withExtendedLifetime(c.window) {}
    }

    @Test("c15: on a placed canvas the map is the overlay's to the window times the screen's scale, and each veil lies on its device lines")
    func veilOnTheDeviceLines() throws {
        let a = Self.region(CGRect(x: 81.3, y: 120.7, width: 200.45, height: 120.2))
        let b = Self.region(CGRect(x: 77.7, y: 400.1, width: 150.3, height: 33.3))
        let c = try Self.placed([a, b], selected: [], suite: "BoxLayerHostTests.c15")
        let (t, unsnapped) = c.host.deviceMap()
        #expect(!unsnapped)
        let k = c.window.screen.scale
        let probe = CGRect(x: 10, y: 20, width: 100, height: 50)
        let onWindow = c.overlay.convert(probe, to: c.window)
        let mapped = probe.applying(t)
        let expected = CGRect(x: onWindow.minX * k, y: onWindow.minY * k, width: onWindow.width * k, height: onWindow.height * k)
        #expect(abs(mapped.minX - expected.minX) < 1e-6 && abs(mapped.minY - expected.minY) < 1e-6)
        #expect(abs(mapped.width - expected.width) < 1e-6 && abs(mapped.height - expected.height) < 1e-6)
        for box in [a, b] {
            let veil = try #require(c.host.layers["veil:\(box.id)"], "the box has a veil")
            let device = veil.frame.applying(t)
            for v in [device.minX, device.minY, device.maxX, device.maxY] {
                #expect(abs(v - v.rounded()) < 1e-6, "the veil's edge \(v) is on a device line")
            }
        }
        withExtendedLifetime(c.window) {}
    }
}
