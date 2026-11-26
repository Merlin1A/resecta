import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import ResectaApp

private final class BoxPictureCasesBundle: NSObject {}

// One box's picture: the case table in Cases/box-picture.json, every field of every
// row, and the two share functions on their rows. The table's numbers are exact
// rationals [numerator, denominator], in overlay points on an unturned Letter page
// (origin top-left); sizes named ...Screen are screen points. A row's `paint` or
// `fill` of null means the region's own rectangle.

struct BoxPictureTests {
    // MARK: - The table

    struct Table: Decodable {
        var rule: String
        var cases: [Case]
    }

    struct Case: Decodable {
        var id: String
        var inputs: Inputs
        var expected: Expected
    }

    /// An exact rational, [numerator, denominator].
    struct Q: Decodable {
        var value: CGFloat
        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            let n = try c.decode(Double.self), d = try c.decode(Double.self)
            value = CGFloat(n / d)
        }
    }

    struct R: Decodable {
        var x: Q, y: Q, w: Q, h: Q
        var rect: CGRect { CGRect(x: x.value, y: y.value, width: w.value, height: h.value) }
    }

    struct P: Decodable {
        var x: Q, y: Q
        var point: CGPoint { CGPoint(x: x.value, y: y.value) }
    }

    struct Size: Decodable {
        var w: Q, h: Q
    }

    struct Settings: Decodable {
        var reduceTransparency: Bool?
        var increaseContrast: Bool?
        var differentiateWithoutColor: Bool?
    }

    struct ShareInput: Decodable {
        var own: R
        var fill: R?
        var paint: R?
        var start: R?
        var single: Bool
    }

    struct WalkInput: Decodable {
        var resultRect: R?
        var applied: Bool
        var keepInView: R?
    }

    struct Inputs: Decodable {
        var own: R?
        var fill: R?
        var paint: R?
        var start: R?
        var drawnByHand: Bool?
        var tagWord: String?
        var tagTextWidth: Q?
        var selection: String?
        var ink: Bool?
        var settings: Settings?
        var fs: Q?
        var page: Size?
        var keepInViewShare: ShareInput?
        var walkFrame: WalkInput?
    }

    struct NamedPoint: Decodable {
        var handle: String
        var point: P
    }

    struct NamedBox: Decodable {
        var handle: String
        var box: R
    }

    struct LiftRects: Decodable {
        var line: R
        var fill: R
    }

    struct Expected: Decodable {
        var share: R?
        var fill: R?
        var lineRect: R?
        var lineWidthScreen: Q?
        var lineWidth: Q?
        var handleCentres: [NamedPoint]?
        var dotCentres: [P]?
        var tagRect: R?
        var hitBody: R?
        var handleBoxes: [NamedBox]?
        var bodyZone: R?
        var cores: [NamedBox]?
        var lift: LiftRects?
        var accessibilityFrame: R?
        var keepInView: R?
        var showsInkLine: Bool?
        var showsCue: Bool?
    }

    /// The table's bytes; a changed table changes this digest and this list together.
    /// Copied from the table of record, sha256 7b6a5fe02d8a88572143df260c53908bdf014d360f82eb512c5872a85ae70b53:
    /// the same rows' inputs and expected, without its notes, the reason on each row,
    /// and its one row for the box before the Ink fields.
    static let tableSHA256 = "46d9d5ed51fc4eb3d2ee49362b1e9f8c977148f73cbdee86e362c668e9e7707c"

    nonisolated static let caseIDs = [
        "hand-rest-fs-1",
        "hand-rest-fs-1/0.64",
        "hand-rest-fs-0.5",
        "hand-single-fs-1",
        "hand-single-fs-1/0.64",
        "hand-single-fs-0.5",
        "hand-oneOfSeveral-fs-1",
        "hand-oneOfSeveral-fs-1/0.64",
        "hand-oneOfSeveral-fs-0.5",
        "hand-addToSelection-fs-1",
        "hand-addToSelection-fs-1/0.64",
        "hand-addToSelection-fs-0.5",
        "hand-moving-fs-1",
        "hand-moving-fs-1/0.64",
        "hand-moving-fs-0.5",
        "found-rest",
        "found-single-2c",
        "found-deselected-2d",
        "found-edited-2e",
        "found-several-no-exception",
        "case5-height-9-fs-1",
        "case5-height-9-fs-1/0.64",
        "case5-height-9-fs-0.5",
        "case5-height-20-fs-1",
        "case5-height-20-fs-1/0.64",
        "case5-height-20-fs-0.5",
        "case5-height-22-fs-1",
        "case5-height-22-fs-1/0.64",
        "case5-height-22-fs-0.5",
        "case5-side-59.9-fs-1",
        "case5-side-59.9-fs-1/0.64",
        "case5-side-59.9-fs-0.5",
        "case5-side-60-fs-1",
        "case5-side-60-fs-1/0.64",
        "case5-side-60-fs-0.5",
        "case5-side-105-fs-1",
        "case5-side-105-fs-1/0.64",
        "case5-side-105-fs-0.5",
        "t4-dots-8",
        "t4-dots-11.9",
        "t4-dots-12",
        "t4-dots-30",
        "tag-line-14.9-fs-1",
        "tag-line-14.9-fs-1/0.64",
        "tag-line-14.9-fs-0.5",
        "tag-line-15-fs-1",
        "tag-line-15-fs-1/0.64",
        "tag-line-15-fs-0.5",
        "tag-too-narrow",
        "tag-below-near-the-top",
        "tag-none-page-tall",
        "tag-hand-box-never",
        "tag-never-single",
        "tag-never-oneOfSeveral",
        "tag-never-addToSelection",
        "tag-never-moving",
        "keep-in-view-share-hand",
        "keep-in-view-share-found-rest",
        "keep-in-view-share-found-single",
        "keep-in-view-share-paint-only",
        "walk-frame-unapplied",
        "walk-frame-applied",
        "walk-frame-no-box",
        "a11y-frame-found",
        "settings-ic-dwc",
        "handles-slide-inside-the-page",
        "cue-not-with-handles",
        "cue-not-at-rest",
    ]

    static func tableData() throws -> Data {
        let url = try #require(Bundle(for: BoxPictureCasesBundle.self).url(
            forResource: "box-picture",
            withExtension: "json"
        ))
        return try Data(contentsOf: url)
    }

    static func table() throws -> Table {
        try JSONDecoder().decode(Table.self, from: tableData())
    }

    @Test func theTableIsTheOneOfRecord() throws {
        let data = try Self.tableData()
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(digest == Self.tableSHA256)
        let table = try Self.table()
        #expect(table.rule == "box-picture")
        #expect(table.cases.map(\.id) == Self.caseIDs)
    }

    // MARK: - Reading a row

    static let tolerance: CGFloat = 1e-9

    static func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= tolerance }

    static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        close(a.minX, b.minX) && close(a.minY, b.minY) && close(a.width, b.width) && close(a.height, b.height)
    }

    static func close(_ a: CGPoint, _ b: CGPoint) -> Bool { close(a.x, b.x) && close(a.y, b.y) }

    static func close(_ a: CGRect?, _ b: R?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): close(a, b.rect)
        default: false
        }
    }

    static func handle(_ name: String) -> RedactionOverlayView.ResizeHandle? {
        switch name {
        case "topLeft": .topLeft
        case "topRight": .topRight
        case "bottomLeft": .bottomLeft
        case "bottomRight": .bottomRight
        case "topCenter": .topCenter
        case "bottomCenter": .bottomCenter
        case "leftCenter": .leftCenter
        case "rightCenter": .rightCenter
        default: nil
        }
    }

    static func selection(_ name: String) -> BoxPicture.Selection? {
        switch name {
        case "rest": .rest
        case "single": .single
        case "oneOfSeveral": .oneOfSeveral
        case "addToSelection": .addToSelection
        case "moving": .moving
        default: nil
        }
    }

    static func input(_ i: Inputs) throws -> BoxPicture.Input {
        let own = try #require(i.own).rect
        let page = try #require(i.page)
        let name = try #require(i.selection)
        let selection = try #require(Self.selection(name))
        try #require(i.drawnByHand != nil)
        return BoxPicture.Input(
            own: own,
            fill: i.fill?.rect,
            veilShares: [],
            paint: i.paint?.rect,
            start: i.start?.rect,
            drawnByHand: i.drawnByHand == true,
            tagWord: i.tagWord,
            tagTextWidth: i.tagTextWidth?.value,
            selection: selection,
            settings: CanvasDisplaySettings(
                reduceTransparency: i.settings?.reduceTransparency ?? false,
                increaseContrast: i.settings?.increaseContrast ?? false,
                differentiateWithoutColor: i.settings?.differentiateWithoutColor ?? false),
            fingerScale: try #require(i.fs).value,
            page: CGSize(width: page.w.value, height: page.h.value))
    }

    static func matches(_ got: [BoxPicture.Handle], _ want: [NamedPoint]) -> Bool {
        got.count == want.count && zip(got, want).allSatisfy { g, w in
            Self.handle(w.handle) == g.handle && close(g.point, w.point.point)
        }
    }

    static func matches(_ got: [BoxPicture.HandleBox], _ want: [NamedBox]) -> Bool {
        got.count == want.count && zip(got, want).allSatisfy { g, w in
            Self.handle(w.handle) == g.handle && close(g.box, w.box.rect)
        }
    }

    // MARK: - Case 1: every row, every field

    @Test(arguments: BoxPictureTests.caseIDs)
    func tableCase(_ id: String) throws {
        let row = try #require(try Self.table().cases.first { $0.id == id })
        let want = row.expected

        if let s = row.inputs.keepInViewShare {
            let got = BoxPicture.keepInViewShare(own: s.own.rect, fill: s.fill?.rect, paint: s.paint?.rect,
                                                 start: s.start?.rect, selectedAlone: s.single)
            #expect(Self.close(got, try #require(want.share).rect))
            return
        }
        if let w = row.inputs.walkFrame {
            let got = BoxPicture.walkFrame(resultRect: w.resultRect?.rect, applied: w.applied,
                                           keepInView: w.keepInView?.rect)
            #expect(Self.close(got, try #require(want.share).rect))
            return
        }

        // Every row is of the look with handles, dots and the ink settings.
        #expect(row.inputs.ink == true)
        let picture = BoxPicture.make(try Self.input(row.inputs))

        #expect(Self.close(picture.fill, try #require(want.fill).rect), "fill")
        #expect(Self.close(picture.lineRect, try #require(want.lineRect).rect), "lineRect")
        #expect(Self.close(picture.lineWidthScreen, try #require(want.lineWidthScreen).value), "lineWidthScreen")
        #expect(Self.close(picture.lineWidth, try #require(want.lineWidth).value), "lineWidth")
        #expect(Self.matches(picture.handleCentres, try #require(want.handleCentres)), "handleCentres")
        let dots = try #require(want.dotCentres)
        #expect(picture.dotCentres.count == dots.count
            && zip(picture.dotCentres, dots).allSatisfy { Self.close($0, $1.point) }, "dotCentres")
        #expect(Self.close(picture.tagRect, want.tagRect), "tagRect")
        #expect(Self.close(picture.hitBody, try #require(want.hitBody).rect), "hitBody")
        #expect(Self.matches(picture.handleBoxes, try #require(want.handleBoxes)), "handleBoxes")
        #expect(Self.close(picture.bodyZone, want.bodyZone), "bodyZone")
        #expect(Self.matches(picture.cores, try #require(want.cores)), "cores")
        switch (picture.lift, want.lift) {
        case (nil, nil): break
        case let (got?, lift?):
            #expect(Self.close(got.line, lift.line.rect) && Self.close(got.fill, lift.fill.rect), "lift")
        default: Issue.record("lift: got \(String(describing: picture.lift))")
        }
        #expect(Self.close(picture.accessibilityFrame, try #require(want.accessibilityFrame).rect), "accessibilityFrame")
        #expect(Self.close(picture.keepInView, try #require(want.keepInView).rect), "keepInView")
        #expect(picture.showsInkLine == want.showsInkLine, "showsInkLine")
        #expect(picture.showsCue == want.showsCue, "showsCue")
    }

    // MARK: - Case 2: a hand-drawn box in any selection

    nonisolated static let selections: [BoxPicture.Selection] = [.rest, .single, .oneOfSeveral, .addToSelection, .moving]

    @Test(arguments: BoxPictureTests.selections)
    func aHandDrawnBoxIsItsOwnRectangle(_ selection: BoxPicture.Selection) throws {
        let hand = try Self.table().cases.filter { $0.inputs.drawnByHand == true }
        #expect(hand.count >= 15)
        for row in hand {
            var input = try Self.input(row.inputs)
            input.selection = selection
            input.fill = nil
            input.paint = nil
            input.start = nil
            let picture = BoxPicture.make(input)
            #expect(picture.fill == input.own, "\(row.id)")
            #expect(picture.lineRect == input.own, "\(row.id)")
            #expect(picture.accessibilityFrame == input.own, "\(row.id)")
        }
    }

    // MARK: - The veil's shares are handed through

    @Test func theVeilSharesAreHandedThroughUnchanged() {
        let shares = [CGRect(x: 0.1, y: 0.2, width: 0.05, height: 0.01),
                      CGRect(x: 0.3, y: 0.2, width: 0.04, height: 0.01)]
        let input = BoxPicture.Input(
            own: CGRect(x: 100, y: 200, width: 120, height: 40), fill: nil, veilShares: shares, paint: nil,
            start: nil, drawnByHand: false, tagWord: nil, tagTextWidth: nil, selection: .rest,
            settings: CanvasDisplaySettings(), fingerScale: 1, page: CGSize(width: 612, height: 792))
        #expect(BoxPicture.make(input).veilShares == shares)
    }
}
