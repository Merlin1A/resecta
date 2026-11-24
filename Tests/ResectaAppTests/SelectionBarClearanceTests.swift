import Testing
import UIKit
import PDFKit
import RedactionEngine
@testable import ResectaApp

// The selection bar never covers the selection: when the selected boxes,
// with the reach of their handles, come within 8 pt of the bar's bottom
// place, the bar is drawn at the top of the canvas instead; the page does
// not move. Canvas 402 x 654 (the default editor canvas); the bar's bottom
// place 59, 602, 284 x 44, its foot 8 pt above the canvas's foot.

@Suite("The selection bar never covers the selection")
@MainActor
struct SelectionBarClearanceTests {

    static let canvas = CGRect(x: 0, y: 0, width: 402, height: 654)
    static let bar = CGRect(x: 59, y: 602, width: 284, height: 44)

    private func atTop(_ selection: CGRect?) -> Bool {
        SelectionBarClearance.barAtTop(selection: selection, bottomBar: Self.bar, canvas: Self.canvas)
    }

    @Test("A selection 8 points or more from the bar keeps the bar at the bottom; nearer, it moves the bar")
    func eightPointsKeepTheBottom() {
        // Above the bar: B grown by 8 begins at y 594.
        #expect(!atTop(CGRect(x: 150, y: 500, width: 100, height: 94)))
        #expect(!atTop(CGRect(x: 150, y: 500, width: 100, height: 93.5)))
        #expect(atTop(CGRect(x: 150, y: 500, width: 100, height: 94.5)))
        // Beside the bar: B grown by 8 begins at x 51.
        #expect(!atTop(CGRect(x: 0, y: 600, width: 51, height: 40)))
        #expect(!atTop(CGRect(x: 0, y: 600, width: 50.5, height: 40)))
        #expect(atTop(CGRect(x: 0, y: 600, width: 51.5, height: 40)))
        // Meeting is sharing an inside point: edges that touch do not meet.
        #expect(!SelectionBarClearance.meets(CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 10, y: 0, width: 10, height: 10)))
        #expect(SelectionBarClearance.meets(CGRect(x: 0, y: 0, width: 10.5, height: 10), CGRect(x: 10, y: 0, width: 10, height: 10)))
    }

    @Test("Handles reach 23 points past the boxes, never past the page")
    func handlesReach() throws {
        #expect(SelectionBarClearance.handleReach == ResectaTokens.TouchTarget.minimum / 2)
        #expect(SelectionBarClearance.handleReach == 23)
        #expect(SelectionBarClearance.gap == ResectaTokens.Spacing.sm)
        let page = CGRect(x: 0, y: 0, width: 400, height: 600)
        #expect(SelectionBarClearance.selectionRect(boxes: [CGRect(x: 100, y: 100, width: 50, height: 20)], page: page)
                == CGRect(x: 77, y: 77, width: 96, height: 66))
        // 10 pt above the page's foot: the reach stops at the foot.
        let foot = try #require(SelectionBarClearance.selectionRect(boxes: [CGRect(x: 100, y: 570, width: 50, height: 20)], page: page))
        #expect(foot.maxY == 600)
        #expect(foot.minY == 547)
        // Two boxes: their union, grown.
        #expect(SelectionBarClearance.selectionRect(
            boxes: [CGRect(x: 100, y: 100, width: 10, height: 10), CGRect(x: 200, y: 300, width: 10, height: 10)], page: page)
                == CGRect(x: 77, y: 77, width: 156, height: 256))
        #expect(SelectionBarClearance.selectionRect(boxes: [], page: page) == nil)
        // Nothing of it on the page.
        #expect(SelectionBarClearance.selectionRect(boxes: [CGRect(x: 500, y: 700, width: 10, height: 10)], page: page) == nil)
    }

    @Test("No handle answers a touch beyond that reach")
    func noHandleBeyondTheReach() {
        let sizes: [CGFloat] = [9, 22, 40, 60, 92, 200]
        for w in sizes {
            for h in sizes {
                let box = CGRect(x: 300, y: 300, width: w, height: h)
                let outside: [CGPoint] = [
                    CGPoint(x: box.minX - 23.5, y: box.minY - 23.5), CGPoint(x: box.maxX + 23.5, y: box.minY - 23.5),
                    CGPoint(x: box.minX - 23.5, y: box.maxY + 23.5), CGPoint(x: box.maxX + 23.5, y: box.maxY + 23.5),
                    CGPoint(x: box.midX, y: box.minY - 23.5), CGPoint(x: box.midX, y: box.maxY + 23.5),
                    CGPoint(x: box.minX - 23.5, y: box.midY), CGPoint(x: box.maxX + 23.5, y: box.midY),
                ]
                for point in outside {
                    #expect(RedactionOverlayView.resolveResizeHandle(at: point, regionRect: box) == nil, "\(w) x \(h) at \(point)")
                }
            }
        }
        // The reach is tight: on a large box a corner answers 22.5 pt outside.
        let large = CGRect(x: 300, y: 300, width: 200, height: 200)
        for point in [CGPoint(x: large.minX - 22.5, y: large.minY - 22.5), CGPoint(x: large.maxX + 22.5, y: large.minY - 22.5),
                      CGPoint(x: large.minX - 22.5, y: large.maxY + 22.5), CGPoint(x: large.maxX + 22.5, y: large.maxY + 22.5)] {
            #expect(RedactionOverlayView.resolveResizeHandle(at: point, regionRect: large) != nil, "\(point)")
        }
    }

    @Test("The place is decided once per change, waits for a lifted finger, and gives way to the person and to a Search step")
    func whenThePlaceIsDecided() {
        typealias S = SelectionBarClearance.Step
        // (inputsChanged, barUp, fingerDown, personScrolling, framedThisPass) -> step
        let table: [(Bool, Bool, Bool, Bool, Bool, S)] = [
            (false, false, false, false, false, .none), (false, false, false, false, true, .none),
            (false, false, false, true, false, .none), (false, false, false, true, true, .none),
            (false, false, true, false, false, .none), (false, false, true, false, true, .none),
            (false, false, true, true, false, .none), (false, false, true, true, true, .none),
            (false, true, false, false, false, .none), (false, true, false, false, true, .none),
            (false, true, false, true, false, .none), (false, true, false, true, true, .none),
            (false, true, true, false, false, .none), (false, true, true, false, true, .none),
            (false, true, true, true, false, .none), (false, true, true, true, true, .none),
            (true, false, false, false, false, .none), (true, false, false, false, true, .none),
            (true, false, false, true, false, .none), (true, false, false, true, true, .none),
            (true, false, true, false, false, .none), (true, false, true, false, true, .none),
            (true, false, true, true, false, .none), (true, false, true, true, true, .none),
            (true, true, false, false, false, .run), (true, true, false, false, true, .drop),
            (true, true, false, true, false, .drop), (true, true, false, true, true, .drop),
            (true, true, true, false, false, .wait), (true, true, true, false, true, .drop),
            (true, true, true, true, false, .drop), (true, true, true, true, true, .drop),
        ]
        #expect(table.count == 32)
        #expect(Set(table.map { "\($0.0)\($0.1)\($0.2)\($0.3)\($0.4)" }).count == 32)
        for row in table {
            #expect(SelectionBarClearance.step(inputsChanged: row.0, barUp: row.1, fingerDown: row.2,
                                               personScrolling: row.3, framedThisPass: row.4) == row.5, "\(row)")
        }
        let id = UUID()
        let base = SelectionBarClearance.Inputs(selectedIDs: [id], regionVersion: 3, bar: Self.bar,
                                                canvasSize: Self.canvas.size, pageIndex: 0)
        var other = base; other.regionVersion = 4
        #expect(other != base, "a box moved or resized")
        other = base; other.bar = Self.bar.offsetBy(dx: 0, dy: -8)
        #expect(other != base, "the bar's frame")
        other = base; other.canvasSize = CGSize(width: 402, height: 590)
        #expect(other != base, "the canvas's size")
        other = base; other.bar = nil
        #expect(other != base, "the bar leaving")
        other = base; other.selectedIDs = [id, UUID()]
        #expect(other != base, "the selection")
        #expect(base == base)
    }

    @Test("The bar takes the top place only when the selection meets the bottom place and not the top")
    func topPlaceRule() {
        #expect(SelectionBarClearance.topPlace(of: Self.bar, canvas: Self.canvas) == CGRect(x: 59, y: 8, width: 284, height: 44))
        #expect(SelectionBarClearance.topPlace(of: Self.bar, canvas: Self.canvas.offsetBy(dx: 0, dy: 116))
                == CGRect(x: 59, y: 124, width: 284, height: 44))
        // A box at the canvas's foot: the top.
        #expect(atTop(CGRect(x: 120, y: 589, width: 150, height: 59)))
        // Nothing selected, or clear of the bottom place: the bottom.
        #expect(!atTop(nil))
        #expect(!atTop(CGRect(x: 120, y: 300, width: 150, height: 60)))
        // Near the top place only: the bottom.
        #expect(!atTop(CGRect(x: 120, y: 10, width: 150, height: 60)))
        // Near both (a whole page; boxes at both ends): the bottom.
        #expect(!atTop(CGRect(x: 6, y: 6, width: 390, height: 642)))
        #expect(!atTop(CGRect(x: 120, y: 59, width: 150, height: 560)))
        // Its top edge exactly 8 pt below the top place's foot (52 + 8 = 60): the top.
        #expect(atTop(CGRect(x: 120, y: 60, width: 150, height: 560)))
        #expect(!atTop(CGRect(x: 120, y: 59.5, width: 150, height: 560)))
    }

    @Test("The bar is drawn at the top only while it holds the slot and no notice shows in the top band")
    func drawnAtTop() {
        for barUp in [false, true] {
            for top in [false, true] {
                for notice in [false, true] {
                    #expect(SelectionBarClearance.drawnAtTop(barUp: barUp, placeIsTop: top, topNoticeShowing: notice)
                            == (barUp && top && !notice), "\(barUp) \(top) \(notice)")
                }
            }
        }
    }
}

// The place as the coordinator decides it from the page in PDFKit, views
// built as `CanvasZoomFloorTests` builds them, the bar's frame given in the
// canvas's points.
@Suite("The selection bar's place, read from the page in PDFKit", .serialized)
@MainActor
struct SelectionBarPlaceHostedTests {

    static let legal = CGSize(width: 612, height: 1008)
    static let letter = CGSize(width: 612, height: 792)
    static let a4 = CGSize(width: 595, height: 842)
    static let defaultCanvas = CGSize(width: 402, height: 654)
    static let largestCanvas = CGSize(width: 402, height: 590)
    static let defaultBar = CGRect(x: 59, y: 602, width: 284, height: 44)
    static let largestBar = CGRect(x: 58.5, y: 530, width: 285, height: 52)

    final class Heard { var places: [Bool] = [] }

    struct Rig {
        let view: FitFlooredPDFView
        let window: UIWindow
        let coordinator: PDFViewCoordinator
        let heard: Heard
    }

    private func document(_ size: CGSize, rotation: Int = 0) -> PDFDocument {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size))
        let data = renderer.pdfData { ctx in
            for _ in 0..<2 {
                ctx.beginPage()
                UIColor.black.setFill()
                ctx.fill(CGRect(x: 36, y: 36, width: 100, height: 12))
            }
        }
        let document = PDFDocument(data: data)!
        for index in 0..<document.pageCount { document.page(at: index)?.rotation = rotation }
        return document
    }

    private func rig(_ size: CGSize, canvas: CGSize = Self.defaultCanvas, bar: CGRect = Self.defaultBar,
                     region normalized: CGRect, zoom: CGFloat = 1, rotation: Int = 0) -> Rig {
        let window = UIWindow(frame: CGRect(origin: .zero, size: canvas))
        let view = FitFlooredPDFView(frame: window.bounds)
        view.autoScales = true
        view.displayMode = .singlePage
        view.document = document(size, rotation: rotation)
        window.addSubview(view)
        window.isHidden = false
        view.layoutIfNeeded()
        if zoom > 1 {
            view.scaleFactor = view.scaleFactorForSizeToFit * zoom
            view.layoutIfNeeded()
            if let scroll = view.subviews.first(where: { $0 is UIScrollView }) as? UIScrollView {
                scroll.setContentOffset(FitFlooredPDFView.clampedOffset(CGPoint(x: scroll.contentOffset.x, y: 1e6), in: scroll), animated: false)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            view.layoutIfNeeded()
        }
        let state = RedactionState()
        let region = RedactionRegion(id: UUID(), normalizedRect: normalized, source: .manual)
        state.addRegion(region, page: 0, undoManager: nil)
        state.selectedRegionIDs = [region.id]
        let coordinator = PDFViewCoordinator()
        coordinator.redactionState = state
        coordinator.documentState = DocumentState()
        coordinator.pdfView = view
        let heard = Heard()
        coordinator.onSelectionBarPlace = { heard.places.append($0) }
        coordinator.selectionBarFrame = bar
        return Rig(view: view, window: window, coordinator: coordinator, heard: heard)
    }

    private func decide(_ rig: Rig, framed: Bool = false) async throws {
        rig.coordinator.keepSelectionClearOfBar(in: rig.view, framedThisPass: framed)
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    private func pageFrame(_ rig: Rig) throws -> CGRect {
        let page = try #require(rig.view.currentPage)
        return rig.view.convert(page.bounds(for: rig.view.displayBox), from: page)
    }

    @Test("A box at the foot of a Legal page at fit takes the bar to the top, and the page does not move")
    func legalFoot() async throws {
        let r = rig(Self.legal, region: CGRect(x: 0.3, y: 0.025, width: 0.3, height: 0.03))
        let before = try pageFrame(r)
        let scale = r.view.scaleFactor
        try await decide(r)
        #expect(r.heard.places == [true])
        let after = try pageFrame(r)
        #expect(abs(after.minY - before.minY) <= 0.5 && abs(after.minX - before.minX) <= 0.5, "\(before) -> \(after)")
        #expect(r.view.scaleFactor == scale)
        #expect(abs(r.view.scaleFactorForSizeToFit - scale) <= scale * 0.001)
    }

    @Test("On an A4 page at fit a box at the foot takes the bar to the top")
    func a4Foot() async throws {
        let r = rig(Self.a4, region: CGRect(x: 0.3, y: 0.005, width: 0.3, height: 0.02))
        try await decide(r)
        #expect(r.heard.places == [true])
    }

    @Test("On a Letter page at fit a box at the foot leaves the bar at the bottom")
    func letterFoot() async throws {
        let r = rig(Self.letter, region: CGRect(x: 0.3, y: 0.005, width: 0.3, height: 0.02))
        try await decide(r)
        #expect(r.heard.places == [false])
    }

    @Test("On the largest text size's canvas a box at the foot of a fit Letter page takes the bar to the top")
    func letterLargest() async throws {
        let r = rig(Self.letter, canvas: Self.largestCanvas, bar: Self.largestBar,
                    region: CGRect(x: 0.3, y: 0.03, width: 0.3, height: 0.03))
        try await decide(r)
        #expect(r.heard.places == [true])
    }

    @Test("Zoomed in at a page's end, a box at the canvas's foot takes the bar to the top, at the same zoom")
    func zoomedEnd() async throws {
        let r = rig(Self.legal, region: CGRect(x: 0.45, y: 0.01, width: 0.1, height: 0.01), zoom: 2)
        let scale = r.view.scaleFactor
        try await decide(r)
        #expect(r.heard.places == [true])
        #expect(r.view.scaleFactor == scale)
    }

    @Test("On a page shown turned a half, a box at the shown foot takes the bar to the top; one at the shown top does not")
    func turnedHalf() async throws {
        // Regions are kept in the shown frame: on a page turned 180° the
        // shown foot is the stored top.
        let foot = rig(Self.legal, region: CGRect(x: 0.3, y: 0.025, width: 0.3, height: 0.03), rotation: 180)
        try await decide(foot)
        #expect(foot.heard.places == [true])
        let top = rig(Self.legal, region: CGRect(x: 0.3, y: 0.945, width: 0.3, height: 0.03), rotation: 180)
        try await decide(top)
        #expect(top.heard.places == [false])
    }

    @Test("On a page shown turned a quarter either way, a box at the shown foot takes the bar to the top")
    func turnedQuarter() async throws {
        // A landscape page turned a quarter is shown as a Legal page upright.
        let stored = CGSize(width: Self.legal.height, height: Self.legal.width)
        var ran = 0
        for rotation in [90, 270] {
            let r = rig(stored, region: CGRect(x: 0.3, y: 0.025, width: 0.3, height: 0.03), rotation: rotation)
            let shown = try pageFrame(r)
            #expect(shown.height > shown.width, "\(rotation): \(shown)")
            try await decide(r)
            #expect(r.heard.places == [true], "\(rotation)")
            ran += 1
        }
        #expect(ran == 2)
    }

    @Test("A bar taken down before the place is handed out hears nothing")
    func barGoneBeforeTheTurn() async throws {
        let r = rig(Self.legal, region: CGRect(x: 0.3, y: 0.025, width: 0.3, height: 0.03))
        r.coordinator.keepSelectionClearOfBar(in: r.view, framedThisPass: false)
        r.coordinator.selectionBarFrame = nil
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(r.heard.places.isEmpty)
    }

    @Test("A whole page selected meets both places: the bar stays at the bottom")
    func wholePage() async throws {
        let r = rig(Self.legal, region: CGRect(x: 0, y: 0, width: 1, height: 1))
        try await decide(r)
        #expect(r.heard.places == [false])
    }

    @Test("While a finger holds the box the place waits, and is decided when it lifts")
    func waitsForTheFinger() async throws {
        let r = rig(Self.legal, region: CGRect(x: 0.3, y: 0.025, width: 0.3, height: 0.03))
        r.coordinator.setCanvasHoldsTouch(true)
        try await decide(r)
        #expect(r.heard.places.isEmpty)
        r.coordinator.setCanvasHoldsTouch(false)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(r.heard.places == [true])
    }

    @Test("In an update a Search step framed, or with no bar, nothing is decided; an unchanged update decides nothing again")
    func givesWay() async throws {
        let framed = rig(Self.legal, region: CGRect(x: 0.3, y: 0.025, width: 0.3, height: 0.03))
        try await decide(framed, framed: true)
        #expect(framed.heard.places.isEmpty)
        let noBar = rig(Self.legal, region: CGRect(x: 0.3, y: 0.025, width: 0.3, height: 0.03))
        noBar.coordinator.selectionBarFrame = nil
        try await decide(noBar)
        #expect(noBar.heard.places.isEmpty)
        let twice = rig(Self.legal, region: CGRect(x: 0.3, y: 0.025, width: 0.3, height: 0.03))
        try await decide(twice)
        try await decide(twice)
        #expect(twice.heard.places == [true])
    }
}
