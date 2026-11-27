import CoreGraphics
import CryptoKit
import Foundation
import PDFKit
import RedactionEngine
import Testing
import UIKit
@testable import ResectaApp

private final class ScreenLinkCasesBundle: NSObject {}

// The screen link: the fill the canvas draws for a box is the fill the run
// makes for it before ink growth, moved outward to whole pixel lines of
// the overlay's bitmap. The case table is Cases/screen-link.json, its
// expected values exact rationals; this suite runs every row, the
// "quarter-" rows (a page shown turned, its whole transform a quarter turn)
// among them.
@Suite("The screen link: the canvas fills what the run fills")
@MainActor
struct ScreenLinkTests {
    /// The repo copy of the table of record (sha256 008760a8…): its rows
    /// unchanged, its prose without citations.
    static let tableSHA256 = "22049fd5b4db2fc2013fbe8f34bb01af5de430f85e76048fa23b8a4e1573645a"
    static let rowsRun = 301

    // MARK: - The table

    static func rows() throws -> [[String: Any]] {
        let url = try #require(Bundle(for: ScreenLinkCasesBundle.self).url(
            forResource: "screen-link", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(digest == tableSHA256)
        let doc = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(doc["rule"] as? String == "screen-link")
        let cases = try #require(doc["cases"] as? [[String: Any]])
        return cases
    }

    /// One rational, as one correctly rounded division.
    static func num(_ any: Any?) throws -> CGFloat {
        let pair = try #require(any as? [Int])
        return CGFloat(Double(pair[0]) / Double(pair[1]))
    }

    /// A rational written "p/q".
    static func frac(_ any: Any?) throws -> Double {
        let text = try #require(any as? String)
        let parts = text.split(separator: "/").compactMap { Double($0) }
        return parts.count == 2 ? parts[0] / parts[1] : try #require(parts.first)
    }

    static func pixel(_ any: Any?) throws -> ScreenLink.PixelBox {
        let p = try #require(any as? [String: Int])
        return ScreenLink.PixelBox(minX: try #require(p["minX"]), minY: try #require(p["minY"]),
                                   maxX: try #require(p["maxX"]), maxY: try #require(p["maxY"]))
    }

    static func lines(_ any: Any?) throws -> (left: Int, top: Int, right: Int, bottom: Int) {
        let l = try #require(any as? [String: Int])
        return (try #require(l["left"]), try #require(l["top"]), try #require(l["right"]), try #require(l["bottom"]))
    }

    /// An overlay of `bounds`, not placed in a PDF view, whose page is its
    /// bounds, under `rotation`.
    static func overlay(bounds: CGSize, rotation: Int) -> RedactionOverlayView {
        let overlay = RedactionOverlayView(frame: CGRect(origin: .zero, size: bounds))
        overlay.geometry = RunRecord.PageGeometry(cropBox: CGRect(origin: .zero, size: bounds), rotation: rotation)
        return overlay
    }

    @Test("Every row of the table, exactly: 301 rows")
    func table() throws {
        var ran = 0
        let k: CGFloat = 100_000
        for row in try Self.rows() {
            let id = try #require(row["id"] as? String)
            let inputs = try #require(row["inputs"] as? [String: Any])
            let expected = try #require(row["expected"] as? [String: Any])
            if id.hasPrefix("rule3-") {
                try Self.ruleThreeRow(id: id, inputs: inputs, expected: expected)
            } else if id.hasPrefix("turn-") {
                try Self.turnRow(id: id, inputs: inputs, expected: expected)
            } else if id.hasPrefix("quarter-") {
                try Self.quarterRow(id: id, inputs: inputs, expected: expected)
            } else {
                // Rule 1's route: the share, the draw map, the clip to the
                // page, then the transform as given and flipped.
                let size = try #require(inputs["overlay"] as? [String: Any])
                let w = try Self.num(size["w"]), h = try Self.num(size["h"])
                let q = try #require(inputs["quality"] as? Int)
                let s = try Self.num(inputs["scale"])
                let offset = try #require(inputs["offset"] as? [String: Any])
                let ox = try Self.num(offset["x"]), oy = try Self.num(offset["y"])
                let view = Self.overlay(bounds: CGSize(width: w, height: h), rotation: 0)
                let share = ScreenLink.share(pixel: try Self.pixel(inputs["painted"]), quality: q,
                                             displayedSize: CGSize(width: w, height: h))
                let rect = view.pdfNormalizedToOverlay(share)
                let clip = CGRect(x: 0, y: 0, width: w, height: h)
                let want = try Self.lines(expected["lines"])
                let given = ScreenLink.deviceLines(rect, toDevice: CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: ox, ty: oy),
                                                   clip: clip)
                #expect(given == ScreenLink.DeviceLines(x0: want.left, y0: want.top, x1: want.right, y1: want.bottom),
                        "\(id) as given")
                let flipped = ScreenLink.deviceLines(rect, toDevice: CGAffineTransform(a: s, b: 0, c: 0, d: -s,
                                                                                         tx: ox, ty: k - oy), clip: clip)
                #expect(flipped == ScreenLink.DeviceLines(x0: want.left, y0: Int(k) - want.bottom,
                                                          x1: want.right, y1: Int(k) - want.top), "\(id) flipped")
            }
            ran += 1
        }
        #expect(ran == Self.rowsRun)
    }

    /// A page shown turned: the pixel box as a rectangle on the canvas, then
    /// its lines through the whole transform, a quarter turn (or, in one
    /// row, axis-aligned), and the rectangle they map back to.
    static func quarterRow(id: String, inputs: [String: Any], expected: [String: Any]) throws {
        let size = try #require(inputs["overlay"] as? [String: Any])
        let w = try num(size["w"]), h = try num(size["h"])
        let q = try #require(inputs["quality"] as? Int)
        let t = try #require(inputs["transform"] as? [String: Any])
        let toDevice = CGAffineTransform(a: try num(t["a"]), b: try num(t["b"]), c: try num(t["c"]),
                                         d: try num(t["d"]), tx: try num(t["tx"]), ty: try num(t["ty"]))
        let view = overlay(bounds: CGSize(width: w, height: h), rotation: 0)
        let share = ScreenLink.share(pixel: try pixel(inputs["painted"]), quality: q,
                                     displayedSize: CGSize(width: w, height: h))
        let rect = view.pdfNormalizedToOverlay(share)
        let clip = CGRect(x: 0, y: 0, width: w, height: h)
        let want = try #require(expected["deviceLines"] as? [String: Int])
        #expect(ScreenLink.deviceLines(rect, toDevice: toDevice, clip: clip)
                    == ScreenLink.DeviceLines(x0: try #require(want["x0"]), y0: try #require(want["y0"]),
                                              x1: try #require(want["x1"]), y1: try #require(want["y1"])), "\(id): lines")
        let exact = try #require(expected["rectExact"] as? [String: String])
        let back = ScreenLink.fillRect(rect, toDevice: toDevice, clip: clip)
        for (key, value) in [("x", back.minX), ("y", back.minY), ("w", back.width), ("h", back.height)] {
            let e = try frac(exact[key])
            #expect(abs(Double(value) - e) <= 1e-9 * max(1, abs(e)), "\(id): \(key) \(value), exactly \(e)")
        }
    }

    /// A hand box off the centre on both axes on an offset crop at a turn:
    /// the fill in shares of the page as displayed goes through the draw
    /// map, cut to the stored bounds, and holds the outline.
    static func turnRow(id: String, inputs: [String: Any], expected: [String: Any]) throws {
        let rotation = try #require(inputs["rotation"] as? Int)
        let b = try #require(inputs["bounds"] as? [String: Any]), d = try #require(inputs["displayed"] as? [String: Any])
        let bounds = CGSize(width: try num(b["w"]), height: try num(b["h"]))
        let displayed = CGSize(width: try num(d["w"]), height: try num(d["h"]))
        let r = try #require(inputs["regionShare"] as? [[Int]])
        let region = CGRect(x: try num(r[0]), y: try num(r[1]), width: try num(r[2]), height: try num(r[3]))
        let s = try num(inputs["scale"])
        let offset = try #require(inputs["offset"] as? [String: Any])
        let view = overlay(bounds: bounds, rotation: rotation)
        #expect(view.geometry.displayedSize == displayed, "\(id): the displayed sides")
        let clip = CGRect(origin: .zero, size: bounds)
        let outline = view.pdfNormalizedToOverlay(region).intersection(clip)
        let share = ScreenLink.share(pixel: try pixel(inputs["painted"]), quality: try #require(inputs["quality"] as? Int),
                                     displayedSize: displayed)
        let fill = view.pdfNormalizedToOverlay(share).intersection(clip)
        #expect(RedactionOverlayView.fillHolds(outline: outline, fill: [fill]) == (expected["identityHolds"] as? Bool),
                "\(id): the identity")
        let want = try lines(expected["lines"])
        let got = ScreenLink.deviceLines(fill, toDevice: CGAffineTransform(a: s, b: 0, c: 0, d: s,
                                                                         tx: try num(offset["x"]), ty: try num(offset["y"])),
                                         clip: clip)
        #expect(got == ScreenLink.DeviceLines(x0: want.left, y0: want.top, x1: want.right, y1: want.bottom), "\(id)")
    }

    /// Rule 3's count rows: a hand box's fill at 150, 200 and 300 in points
    /// is its pixel lines × 72 ÷ q, and whether the lower quality holds the
    /// higher is the table's.
    static func ruleThreeRow(id: String, inputs: [String: Any], expected: [String: Any]) throws {
        let painted = try #require(expected["painted"] as? [String: Any])
        let shown = try #require(expected["shownPt"] as? [String: [String]])
        for q in [150, 200, 300] {
            let p = try pixel(painted[String(q)])
            let pt = try #require(shown[String(q)]).map { try frac($0) }
            let a4 = CGSize(width: 595.276, height: 841.89)
            let share = ScreenLink.share(pixel: p, quality: q, displayedSize: a4)
            #expect(abs(Double(share.minX * a4.width) - pt[0]) < 1e-9 * max(1, pt[0]), "\(id) \(q): left")
            #expect(abs(Double(share.minY * a4.height) - pt[1]) < 1e-9 * max(1, pt[1]), "\(id) \(q): bottom")
        }
        let lowerKey = try #require(inputs["lower"] as? Int)
        let lower = try #require(shown[String(lowerKey)]).map { try frac($0) }
        let higherKey = try #require(inputs["higher"] as? Int)
        let higher = try #require(shown[String(higherKey)]).map { try frac($0) }
        let holds = lower[0] <= higher[0] && lower[1] <= higher[1] && lower[2] >= higher[2] && lower[3] >= higher[3]
        #expect(holds == (expected["lowerHoldsHigher"] as? Bool), "\(id): the lower quality holds the higher")
    }

    // MARK: - What is refused

    @Test("A transform turned by 10° gives no lines and the cut rectangle; a quarter turn is accepted; an empty clip gives nothing")
    func rejects() throws {
        let rect = CGRect(x: 10, y: 20, width: 30, height: 40)
        let clip = CGRect(x: 0, y: 0, width: 35, height: 100)
        let cut = CGRect(x: 10, y: 20, width: 25, height: 40)
        let tenDegrees = CGAffineTransform(rotationAngle: .pi / 18).scaledBy(x: 3, y: 3)
        #expect(ScreenLink.deviceLines(rect, toDevice: tenDegrees, clip: clip) == nil)
        #expect(ScreenLink.fillRect(rect, toDevice: tenDegrees, clip: clip) == cut)
        // A quarter turn's lines, as the table's quarter rows give them.
        let row = try #require(try Self.rows().first { $0["id"] as? String == "quarter-90-fit-300" })
        let inputs = try #require(row["inputs"] as? [String: Any])
        let t = try #require(inputs["transform"] as? [String: Any])
        let quarter = CGAffineTransform(a: try Self.num(t["a"]), b: try Self.num(t["b"]), c: try Self.num(t["c"]),
                                        d: try Self.num(t["d"]), tx: try Self.num(t["tx"]), ty: try Self.num(t["ty"]))
        let overlay = try #require(inputs["overlay"] as? [String: Any])
        let w = try Self.num(overlay["w"]), h = try Self.num(overlay["h"])
        let share = ScreenLink.share(pixel: try Self.pixel(inputs["painted"]), quality: try #require(inputs["quality"] as? Int),
                                     displayedSize: CGSize(width: w, height: h))
        let onCanvas = Self.overlay(bounds: CGSize(width: w, height: h), rotation: 0).pdfNormalizedToOverlay(share)
        let want = try #require((row["expected"] as? [String: Any])?["deviceLines"] as? [String: Int])
        #expect(ScreenLink.deviceLines(onCanvas, toDevice: quarter, clip: CGRect(x: 0, y: 0, width: w, height: h))
                    == ScreenLink.DeviceLines(x0: try #require(want["x0"]), y0: try #require(want["y0"]),
                                              x1: try #require(want["x1"]), y1: try #require(want["y1"])))
        // A hair off either: b = c = 1e-17 is axis-aligned; a = d = 1e-17
        // with b = -c is a quarter turn.
        let hair = CGAffineTransform(a: 3, b: 1e-17, c: 1e-17, d: 3, tx: 0.5, ty: 0.25)
        #expect(ScreenLink.deviceLines(rect, toDevice: hair, clip: clip) != nil)
        let quarterHair = CGAffineTransform(a: 1e-17, b: 3, c: -3, d: 1e-17, tx: 0.5, ty: 0.25)
        #expect(ScreenLink.isQuarterTurn(quarterHair))
        #expect(ScreenLink.deviceLines(rect, toDevice: quarterHair, clip: clip)
                    == ScreenLink.deviceLines(rect, toDevice: CGAffineTransform(a: 0, b: 3, c: -3, d: 0, tx: 0.5, ty: 0.25),
                                              clip: clip))
        let empty = CGRect(x: 100, y: 100, width: 5, height: 5)
        #expect(ScreenLink.deviceLines(rect, toDevice: .identity, clip: empty) == nil)
        #expect(ScreenLink.fillRect(rect, toDevice: .identity, clip: empty).isNull)
    }

    // MARK: - Properties

    @Test("Over 2,000 seeded rectangles at 2× and 3×: the fill holds the rectangle, by under a pixel a side, the same each time")
    func properties() {
        var seed: UInt64 = 0x5C12_EE8
        func next() -> CGFloat {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return CGFloat(Double(seed >> 11) / Double(1 << 53))
        }
        for i in 0..<2_000 {
            let scale: CGFloat = (i % 2 == 0 ? 3 : 2) * (1 + next() * 7)
            let flip = i % 3 == 0
            let t = CGAffineTransform(a: scale, b: 0, c: 0, d: flip ? -scale : scale,
                                      tx: next() * 200 - 100, ty: flip ? 5_000 + next() * 100 : next() * 200 - 100)
            let rect = CGRect(x: next() * 500, y: next() * 700, width: 0.5 + next() * 100, height: 0.5 + next() * 60)
            let clip = CGRect(x: 0, y: 0, width: 612, height: 792)
            let fill = ScreenLink.fillRect(rect, toDevice: t, clip: clip)
            let cut = rect.intersection(clip)
            guard !cut.isNull, !cut.isEmpty else { #expect(fill.isNull); continue }
            let slack = 1e-9 * max(1, max(abs(cut.maxX), abs(cut.maxY))) * scale
            #expect(fill.minX <= cut.minX + slack && fill.minY <= cut.minY + slack, "\(i): holds")
            #expect(fill.maxX >= cut.maxX - slack && fill.maxY >= cut.maxY - slack, "\(i): holds")
            let pixel = 1 / scale
            #expect(cut.minX - fill.minX < pixel && cut.minY - fill.minY < pixel, "\(i): under a pixel")
            #expect(fill.maxX - cut.maxX < pixel && fill.maxY - cut.maxY < pixel, "\(i): under a pixel")
            #expect(ScreenLink.fillRect(rect, toDevice: t, clip: clip) == fill, "\(i): the same each time")
        }
    }
}

// MARK: - The steps a placed canvas makes

// These read the steps the canvas makes for a pass, never a drawn fill, on a
// real `FitFlooredPDFView` with the coordinator as its overlay provider.
extension ScreenLinkTests {

    /// Letter at 0, 90, 180 and 270, and at 90 over an offset crop (the five
    /// turned pages); A4 and 500.3 × 700.7, each at 0 and 90; and a crop of
    /// 401.123 × 577.777 turned 270.
    static let pages: [(media: CGRect, crop: CGRect?, turn: Int)] = [
        (CGRect(x: 0, y: 0, width: 612, height: 792), nil, 0),
        (CGRect(x: 0, y: 0, width: 612, height: 792), nil, 90),
        (CGRect(x: 0, y: 0, width: 612, height: 792), nil, 180),
        (CGRect(x: 0, y: 0, width: 612, height: 792), nil, 270),
        (CGRect(x: 0, y: 0, width: 612, height: 792), CGRect(x: 36, y: 54, width: 540, height: 684), 90),
        (CGRect(x: 0, y: 0, width: 595.276, height: 841.89), nil, 0),
        (CGRect(x: 0, y: 0, width: 595.276, height: 841.89), nil, 90),
        (CGRect(x: 0, y: 0, width: 500.3, height: 700.7), nil, 0),
        (CGRect(x: 0, y: 0, width: 500.3, height: 700.7), nil, 90),
        (CGRect(x: 0, y: 0, width: 612, height: 792), CGRect(x: 12.345, y: 67.891, width: 401.123, height: 577.777), 270),
    ]

    static func pagesDocument() throws -> PDFDocument {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { ctx in
            for page in pages { ctx.beginPage(withBounds: page.media, pageInfo: [:]) }
        }
        let document = try #require(PDFDocument(data: data))
        try #require(document.pageCount == pages.count)
        for (i, page) in pages.enumerated() {
            document.page(at: i)?.rotation = page.turn
            if let crop = page.crop { document.page(at: i)?.setBounds(crop, for: .cropBox) }
        }
        return document
    }

    struct Placed {
        let window: UIWindow
        let view: FitFlooredPDFView
        let coordinator: PDFViewCoordinator
        let state: RedactionState
        let settings: SettingsState?
        let document: PDFDocument
        let page: PDFPage
        let overlay: RedactionOverlayView
    }

    static func overlays(in view: UIView) -> [RedactionOverlayView] {
        view.subviews.flatMap { ($0 as? RedactionOverlayView).map { [$0] } ?? overlays(in: $0) }
    }

    /// Page `index` shown, its canvas placed by PDFKit. With `suite`, the
    /// coordinator keeps plans as the editor does, at a chosen 300.
    static func placed(_ index: Int, suite: String? = nil) throws -> Placed {
        let document = try pagesDocument()
        let state = RedactionState()
        let coordinator = PDFViewCoordinator()
        coordinator.redactionState = state
        var settings: SettingsState?
        if let suite {
            let documentState = DocumentState()
            documentState.sourceDocument = document
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            let kept = SettingsState(defaults: defaults)
            kept.exportDPI = 300
            coordinator.documentState = documentState
            coordinator.settingsState = kept
            settings = kept
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let view = FitFlooredPDFView(frame: window.bounds)
        view.displayMode = .singlePage
        view.pageOverlayViewProvider = coordinator
        view.document = document
        window.addSubview(view)
        window.isHidden = false
        let page = try #require(document.page(at: index))
        view.go(to: page)
        view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let overlay = try #require(overlays(in: view).first { $0.pageIndex == index },
                                   "PDFKit installed the coordinator's overlay for page \(index)")
        try #require(overlay.isPlacedOnItsPage, "page \(index) is placed")
        return Placed(window: window, view: view, coordinator: coordinator, state: state, settings: settings,
                      document: document, page: page, overlay: overlay)
    }

    /// A box at shares of the page as displayed, from its bottom-left.
    static func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, id: UUID = UUID()) -> RedactionRegion {
        RedactionRegion(id: id, normalizedRect: CGRect(x: x, y: y, width: w, height: h), source: .manual)
    }

    /// The plan a run keeps for `regions` on `page`, read with the crop's
    /// sides `crop` (the page's own unless given).
    static func plan(_ regions: [RedactionRegion], index: Int, page: PDFPage, crop: CGSize? = nil) -> DrawnPlan {
        DrawnPlan(pageIndex: index, regions: regions, cropBox: crop ?? page.bounds(for: .cropBox).size,
                  rotation: page.rotation, switchOn: false, exportDPI: 300, fillColor: .black)
    }

    static func veil(_ steps: [InkStep]) -> [CGRect] { steps.filter { $0.layer == .veil }.flatMap(\.rects) }
    static func lineRects(_ steps: [InkStep]) -> [CGRect] { steps.filter { $0.layer == .line }.flatMap(\.rects) }

    /// The run's record of `state`'s boxes and the page it refuses, if any.
    static func refused(_ c: Placed) -> Int? {
        let document = c.document
        let record = RunInputs.confirmedRecord(
            pageCount: document.pageCount, geometry: RunInputs.pageGeometry(of: document),
            geometryAtStore: c.state.geometryAtStore, shownDPIs: [:], regions: c.state.regions, reads: [:],
            settings: .init(pipelineMode: .secureRasterization, autoVerify: false, paranoidMode: false,
                            fillColor: .black, exportDPI: 300))
        return record.firstPageWithUnconfirmedBoxPlace(canvasFailures: c.state.canvasProbeFailuresAtRunEntry())
    }

    static func turned(_ region: RedactionRegion, _ rotation: Int) -> RedactionRegion {
        RedactionRegion(id: region.id, normalizedRect: CanvasTurn.stored(fromShown: region.normalizedRect, rotation: rotation),
                        source: .manual)
    }

    @Test("Rule 2 on placed canvases: on every turned and guard page the veil holds each box's outline, inside the page; a fill in the stored frame or a read of the wrong sides gives the line alone and is reported; an unplaced canvas writes nothing")
    func identityOnTurnedPages() throws {
        for index in Self.pages.indices {
            let c = try Self.placed(index)
            let crop = c.page.bounds(for: .cropBox)
            let p = c.overlay.pageRectOnCanvas
            #expect(abs(p.width - crop.width) <= 0.01 && abs(p.height - crop.height) <= 0.01,
                    "page \(index): the page on the canvas \(p.size), the crop \(crop.size)")
            let clip = p.intersection(c.overlay.bounds)
            // One box off the centre on both axes, and one at each far edge.
            let word = Self.box(0.18, 0.62, 0.22, 0.03)
            let regions = [word, Self.box(0.9, 0, 0.1, 0.04), Self.box(0, 0.96, 0.1, 0.04)]
            c.overlay.configure(with: regions, selectedIDs: [])
            let steps = c.overlay.committedSteps(in: c.overlay.bounds,
                                                 plan: Self.plan(regions, index: index, page: c.page))
            let veil = Self.veil(steps)
            #expect(!veil.isEmpty, "page \(index): a veil step")
            #expect(Self.lineRects(steps).count == regions.count)
            for region in regions {
                let outline = c.overlay.pdfNormalizedToOverlay(region.normalizedRect).intersection(clip)
                #expect(RedactionOverlayView.fillHolds(outline: outline, fill: veil),
                        "page \(index): the veil holds \(region.normalizedRect)")
            }
            for rect in veil {
                #expect(rect.minX >= clip.minX - 1e-9 && rect.minY >= clip.minY - 1e-9
                            && rect.maxX <= clip.maxX + 1e-9 && rect.maxY <= clip.maxY + 1e-9,
                        "page \(index): the veil \(rect) lies inside the page on the canvas \(clip)")
            }
            #expect(!c.state.pagesWithUnconfirmedFill.contains(index))

            if c.page.rotation != 0 {
                // The plan's fill handed in the stored frame.
                c.overlay.configure(with: [word], selectedIDs: [])
                let stored = c.overlay.committedSteps(
                    in: c.overlay.bounds, plan: Self.plan([Self.turned(word, c.page.rotation)], index: index, page: c.page))
                #expect(Self.veil(stored).isEmpty, "page \(index): a fill in the stored frame gives no veil")
                #expect(Self.lineRects(stored).count == 1)
                #expect(c.state.pagesWithUnconfirmedFill.contains(index), "page \(index): reported")
                _ = c.overlay.committedSteps(in: c.overlay.bounds, plan: Self.plan([word], index: index, page: c.page))
                #expect(!c.state.pagesWithUnconfirmedFill.contains(index), "page \(index): a pass clears it")
            }
            if c.page.rotation % 180 != 0 {
                // A read whose sides are the page's turned the wrong way.
                c.overlay.configure(with: [word], selectedIDs: [])
                let swapped = c.overlay.committedSteps(
                    in: c.overlay.bounds,
                    plan: Self.plan([word], index: index, page: c.page, crop: CGSize(width: crop.height, height: crop.width)))
                #expect(Self.veil(swapped).isEmpty, "page \(index): a read of swapped sides gives no veil")
                #expect(c.state.pagesWithUnconfirmedFill.contains(index), "page \(index): reported")
            }
            if index == 1 {
                // A read 0.05 pt off the geometry's sides, of a box whose
                // edges lie mid-pixel, so that its fill alone would pass.
                let mid = Self.box(0.10015, 0.4002, 0.2, 0.0302)
                c.overlay.configure(with: [mid], selectedIDs: [])
                _ = c.overlay.committedSteps(in: c.overlay.bounds, plan: Self.plan([mid], index: index, page: c.page))
                #expect(!c.state.pagesWithUnconfirmedFill.contains(index))
                let off = c.overlay.committedSteps(
                    in: c.overlay.bounds,
                    plan: Self.plan([mid], index: index, page: c.page,
                                    crop: CGSize(width: crop.width + 0.05, height: crop.height)))
                #expect(Self.veil(off).isEmpty, "page \(index): a read of other sides gives no veil")
                #expect(c.state.pagesWithUnconfirmedFill.contains(index), "page \(index): reported")
            }

            // Not yet placed: its page's size alone would pass, so the
            // predicate holds the veil back, and nothing is written.
            let unplaced = RedactionOverlayView(frame: c.overlay.bounds)
            unplaced.pageIndex = index
            unplaced.geometry = c.overlay.geometry
            unplaced.pageSize = crop.size
            unplaced.coordinator = c.coordinator
            unplaced.configure(with: [word], selectedIDs: [])
            let before = c.state.pagesWithUnconfirmedFill
            #expect(!unplaced.isPlacedOnItsPage)
            let early = unplaced.committedSteps(in: unplaced.bounds, plan: Self.plan([word], index: index, page: c.page))
            #expect(Self.veil(early).isEmpty && Self.lineRects(early).count == 1, "page \(index): an unplaced canvas gives the line alone")
            _ = unplaced.committedSteps(
                in: unplaced.bounds,
                plan: Self.plan([word], index: index, page: c.page, crop: CGSize(width: crop.height + 1, height: crop.width)))
            #expect(c.state.pagesWithUnconfirmedFill == before, "page \(index): an unplaced canvas writes nothing")
            withExtendedLifetime((c.coordinator, c.window)) {}
        }

        // A read's sides are held in whole sixty-fourths, rounded up: on
        // ISO B5 and on 500.3 × 700.7 a side is more than 0.01 pt over.
        for size in [CGSize(width: 498.898, height: 708.661), CGSize(width: 500.3, height: 700.7)] {
            let overlay = RedactionOverlayView(frame: CGRect(origin: .zero, size: size))
            overlay.geometry = RunRecord.PageGeometry(cropBox: CGRect(origin: .zero, size: size), rotation: 0)
            overlay.pageSize = size
            let word = Self.box(0.18, 0.62, 0.22, 0.03)
            let plan = DrawnPlan(pageIndex: 0, regions: [word], cropBox: size, rotation: 0, switchOn: false,
                                 exportDPI: 300, fillColor: .black)
            let w64 = try #require(plan.widthSixtyFourths), h64 = try #require(plan.heightSixtyFourths)
            let over = max(CGFloat(w64) / 64 - size.width, CGFloat(h64) / 64 - size.height)
            #expect(over > 0.01 && over <= 0.016, "\(size): a side is \(over) pt over")
            let made = RedactionOverlayView.inkBoxes(
                regions: [word], plan: plan, pageIndex: 0, geometry: overlay.geometry, placed: true,
                page: overlay.pageRectOnCanvas, clip: overlay.bounds, selectedIDs: [], tags: [:],
                map: overlay.pdfNormalizedToOverlay)
            let filled = made.boxes.allSatisfy { !$0.fill.isEmpty }
            #expect(made.check == .confirmed && filled, "\(size)")
        }
    }

    @Test("The identity's door: a failure refuses the run for its page; a pass clears it; a probe's failure outlives the pass; a partial pass never clears another box's failure")
    func identityDoor() throws {
        let c = try Self.placed(1)
        let document = c.document
        c.state.pageGeometryReader = { document.page(at: $0).map {
            RunRecord.PageGeometry(cropBox: $0.bounds(for: .cropBox), rotation: $0.rotation) } }
        let crop = c.page.bounds(for: .cropBox).size
        let a = Self.box(0.12, 0.2, 0.2, 0.04), b = Self.box(0.6, 0.7, 0.25, 0.04)
        for region in [a, b] { c.state.addRegion(region, page: 1, undoManager: nil) }
        c.overlay.configure(with: [a, b], selectedIDs: [])
        try #require(!c.state.canvasProbeFailuresAtRunEntry().contains(1), "the canvas passes the probe")
        try #require(Self.refused(c) == nil)
        let good = Self.plan([a, b], index: 1, page: c.page)

        // The identity made to fail: the read's sides swapped.
        let failing = c.overlay.committedSteps(
            in: c.overlay.bounds,
            plan: Self.plan([a, b], index: 1, page: c.page, crop: CGSize(width: crop.height, height: crop.width)))
        #expect(Self.veil(failing).isEmpty)
        #expect(!c.state.canvasProbeFailures.contains(1), "the refusal is the identity's alone")
        #expect(c.state.pagesWithUnconfirmedFill == [1])
        #expect(Self.refused(c) == 1)

        // Drawn again, passing.
        #expect(!Self.veil(c.overlay.committedSteps(in: c.overlay.bounds, plan: good)).isEmpty)
        #expect(c.state.pagesWithUnconfirmedFill.isEmpty)
        #expect(Self.refused(c) == nil)

        // The probe's failure outlives the identity's pass.
        c.state.canvasProbeFailures.insert(1)
        _ = c.overlay.committedSteps(in: c.overlay.bounds, plan: good)
        #expect(c.state.canvasProbeFailures.contains(1))
        #expect(Self.refused(c) == 1)
        c.state.canvasProbeFailures.remove(1)

        // B fails clause 1; A, elsewhere, is moved in partial passes over
        // its own dirty rectangle, each driven here before any full pass.
        let storedB = Self.turned(b, 90)
        _ = c.overlay.committedSteps(in: c.overlay.bounds, plan: Self.plan([a, storedB], index: 1, page: c.page))
        #expect(c.state.pagesWithUnconfirmedFill == [1])
        c.overlay.selectedIDs = [a.id]
        c.overlay.isDraggingExistingRegion = true
        let farB = c.overlay.pdfNormalizedToOverlay(b.normalizedRect)
        for step in 1...4 {
            var moved = a
            moved.normalizedRect = a.normalizedRect.offsetBy(dx: 0.01 * CGFloat(step), dy: 0)
            c.overlay.regions = [moved, b]
            let dirty = c.overlay.pdfNormalizedToOverlay(moved.normalizedRect).insetBy(dx: -8, dy: -8)
            try #require(!dirty.insetBy(dx: -120, dy: -120).intersects(farB), "the pass never reaches B")
            _ = c.overlay.committedSteps(in: dirty, plan: Self.plan([moved, storedB], index: 1, page: c.page))
            #expect(c.state.pagesWithUnconfirmedFill == [1], "partial pass \(step)")
            #expect(Self.refused(c) == 1, "partial pass \(step)")
        }
        c.overlay.isDraggingExistingRegion = false
        withExtendedLifetime((c.coordinator, c.window)) {}
    }

    @Test("The boxes' pass on each of the five turned pages reads a map square to the screen (debug builds stop otherwise)",
          arguments: 0..<5)
    func turnedContext(index: Int) throws {
        let c = try Self.placed(index, suite: "ScreenLinkTests.turnedContext.\(index)")
        let word = Self.box(0.18, 0.62, 0.22, 0.03)
        c.state.addRegion(word, page: index, undoManager: nil)
        c.overlay.configure(with: [word], selectedIDs: [])
        c.state.drawnPlans[index] = nil
        c.overlay.setNeedsDisplay()
        c.overlay.boxLayers.applyPendingPass()
        #expect(c.state.drawnPlans[index] != nil, "page \(index): a pass ran")
        #expect(!c.overlay.boxLayers.isPassPending, "page \(index): the pass is on the pixel lines")
        #expect(!c.state.pagesWithUnconfirmedFill.contains(index))
        withExtendedLifetime((c.coordinator, c.window)) {}
    }

    @Test("Rule 9: a change of the chosen quality, and the memory warning's cap, keep the page's plan at the new quality and mark its canvas")
    func qualityRedraws() throws {
        let c = try Self.placed(0, suite: "ScreenLinkTests.qualityRedraws")
        let settings = try #require(c.settings)
        let word = Self.box(0.18, 0.62, 0.22, 0.03)
        c.state.addRegion(word, page: 0, undoManager: nil)
        c.overlay.configure(with: [word], selectedIDs: [])
        c.coordinator.noteDrawn(pageIndex: 0, regions: [word])
        #expect(c.state.drawnPlans[0]?.exportDPI == 300)

        c.overlay.boxLayers.root.layoutIfNeeded()
        try #require(!c.overlay.boxLayers.isPassPending)
        settings.exportDPI = 150
        c.coordinator.chosenQuality = 150
        #expect(c.state.drawnPlans[0]?.exportDPI == 150, "the setting's change keeps the plan at 150")
        #expect(c.overlay.boxLayers.isPassPending, "the setting's change marks the canvas")

        settings.exportDPI = 300
        c.coordinator.chosenQuality = 300
        c.overlay.boxLayers.root.layoutIfNeeded()
        try #require(!c.overlay.boxLayers.isPassPending)
        c.coordinator.qualityCap = 150
        #expect(c.state.drawnPlans[0]?.exportDPI == 150, "the memory warning's cap keeps the plan at 150")
        #expect(c.overlay.boxLayers.isPassPending, "the memory warning's cap marks the canvas")
        withExtendedLifetime((c.coordinator, c.window)) {}
    }

    @Test("Rule 7: the canvas of page 1 handed page 0's plan draws no veil, and reports the page")
    func otherPagesPlan() throws {
        let c = try Self.placed(1)
        let word = Self.box(0.18, 0.62, 0.22, 0.03)
        c.overlay.configure(with: [word], selectedIDs: [])
        #expect(!Self.veil(c.overlay.committedSteps(
            in: c.overlay.bounds, plan: Self.plan([word], index: 1, page: c.page))).isEmpty)
        let other = c.overlay.committedSteps(in: c.overlay.bounds, plan: Self.plan([word], index: 0, page: c.page))
        #expect(Self.veil(other).isEmpty)
        #expect(Self.lineRects(other).count == 1)
        #expect(c.state.pagesWithUnconfirmedFill.contains(1))
        withExtendedLifetime((c.coordinator, c.window)) {}
    }

    @Test("Rule 8: a box being moved has the veil and the line of a resting box with its rectangle")
    func liftAtRest() throws {
        let c = try Self.placed(2)
        let word = Self.box(0.18, 0.62, 0.22, 0.03)
        let plan = Self.plan([word], index: 2, page: c.page)
        c.overlay.configure(with: [word], selectedIDs: [word.id])
        c.overlay.isDraggingExistingRegion = true
        let moving = c.overlay.committedSteps(in: c.overlay.bounds, plan: plan)
        c.overlay.isDraggingExistingRegion = false
        let resting = c.overlay.committedSteps(in: c.overlay.bounds, plan: plan)
        let lifted = moving.contains { $0.lifted }
        #expect(lifted)
        #expect(!Self.veil(resting).isEmpty)
        #expect(Self.veil(moving) == Self.veil(resting))
        #expect(Self.lineRects(moving) == Self.lineRects(resting))
        withExtendedLifetime((c.coordinator, c.window)) {}
    }
}
