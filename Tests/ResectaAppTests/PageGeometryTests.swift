import Testing
import Foundation
import CoreGraphics
import CryptoKit
import UIKit
import RedactionEngine
@testable import ResectaApp

// The page's geometry, the one value every map on the canvas takes a page's
// turn, sides and origin from, held by its table of record: every row, by
// id, compared on the bit patterns. The expected values are the table's
// numbers, worked out apart from this code; this file keeps no expression of
// its own. The overlay's rows run on a real overlay with its bounds and
// geometry set and no host view, so its maps divide by its bounds.
// Then the app's page map against the engine's: inside the page they agree
// to within 1e-9 pt on every side, on five page shapes at each turn.

private final class PageGeometryTableBundle: NSObject {}

@Suite("The page's geometry: the table of record, and the app's page map against the engine's")
@MainActor
struct PageGeometryTests {

    typealias Row = [String: Any]
    static let tableSHA256 = "2c3f05a67b3f9014330b605e31b8ed09b9e763cdadf0a5f545b95c66dbbda9b4"
    static let letter = CGRect(x: 0, y: 0, width: 612, height: 792)

    static func table() throws -> (data: Data, rows: [Row]) {
        let url = try #require(Bundle(for: PageGeometryTableBundle.self).url(forResource: "page-geometry", withExtension: "json"),
                               "page-geometry.json not bundled")
        let data = try Data(contentsOf: url)
        // Through the decoder, which reads each number as the nearest double:
        // `JSONSerialization` hands long decimals back as `NSDecimalNumber`,
        // whose `doubleValue` is a bit off on 1,600 of the table's numbers,
        // and the table is compared bit for bit.
        let object = try #require(try JSONDecoder().decode(TableValue.self, from: data).any as? Row)
        let rows = try #require(object["cases"] as? [Row])
        return (data, rows)
    }

    /// A JSON value as `JSONDecoder` reads it, handed back in the shapes
    /// `JSONSerialization` gives (numbers as `NSNumber` of the exact double).
    enum TableValue: Decodable {
        case number(Double), string(String), bool(Bool), list([TableValue]), object([String: TableValue]), null
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let b = try? c.decode(Bool.self) { self = .bool(b) }
            else if let x = try? c.decode(Double.self) { self = .number(x) }
            else if let t = try? c.decode(String.self) { self = .string(t) }
            else if let l = try? c.decode([TableValue].self) { self = .list(l) }
            else { self = .object(try c.decode([String: TableValue].self)) }
        }
        var any: Any {
            switch self {
            case .number(let x): NSNumber(value: x)
            case .string(let t): t
            case .bool(let b): b
            case .list(let l): l.map(\.any)
            case .object(let o): o.mapValues(\.any)
            case .null: NSNull()
            }
        }
    }

    static func number(_ any: Any?) throws -> Double {
        try #require((any as? NSNumber)?.doubleValue, "not a number: \(String(describing: any))")
    }
    static func rect(_ any: Any?) throws -> CGRect {
        let d = try #require(any as? Row, "not a rectangle: \(String(describing: any))")
        return CGRect(x: try number(d["x"]), y: try number(d["y"]), width: try number(d["w"]), height: try number(d["h"]))
    }
    static func size(_ any: Any?) throws -> CGSize {
        let d = try #require(any as? Row)
        return CGSize(width: try number(d["w"]), height: try number(d["h"]))
    }
    static func point(_ any: Any?) throws -> CGPoint {
        let d = try #require(any as? Row)
        return CGPoint(x: try number(d["x"]), y: try number(d["y"]))
    }

    /// Equal bit for bit, side by side, as the rectangle was made (origin
    /// and size, not standardised).
    static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        [a.origin.x, a.origin.y, a.size.width, a.size.height].map(\.bitPattern)
            == [b.origin.x, b.origin.y, b.size.width, b.size.height].map(\.bitPattern)
    }
    static func same(_ a: CGSize, _ b: CGSize) -> Bool {
        a.width.bitPattern == b.width.bitPattern && a.height.bitPattern == b.height.bitPattern
    }
    static func same(_ a: CGPoint, _ b: CGPoint) -> Bool {
        a.x.bitPattern == b.x.bitPattern && a.y.bitPattern == b.y.bitPattern
    }

    static func overlay(size: CGSize, geometry: RunRecord.PageGeometry) -> RedactionOverlayView {
        let overlay = RedactionOverlayView(frame: CGRect(origin: .zero, size: size))
        overlay.geometry = geometry
        return overlay
    }

    @Test("The table is the table of record, all 344 rows")
    func tableIsTheRecord() throws {
        let (data, rows) = try Self.table()
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(digest == Self.tableSHA256)
        #expect(rows.count == 344)
        #expect(Set(rows.compactMap { $0["id"] as? String }).count == 344)
    }

    @Test("Every row of the table, by id, bit for bit")
    func everyRow() throws {
        let rows = try Self.table().rows
        var checked = 0
        var counted = 0
        let saved = RedactionOverlayView.noGeometry
        RedactionOverlayView.noGeometry = { counted += 1 }
        defer { RedactionOverlayView.noGeometry = saved }
        for row in rows {
            let id = try #require(row["id"] as? String)
            let input = try #require(row["inputs"] as? Row), want = try #require(row["expected"] as? Row)
            let rotation = (input["rotation"] as? NSNumber)?.intValue ?? 0
            let crop = try input["crop"].map { try Self.rect($0) }

            if id.hasPrefix("rotation") {
                let g = RunRecord.PageGeometry(cropBox: Self.letter, rotation: rotation)
                #expect(g.rotation == (want["rotation"] as? NSNumber)?.intValue, "\(id)")
            } else if id.hasPrefix("landed-turn") {
                let c = try #require(crop)
                let shown = CanvasTurn.shown(fromStored: try Self.rect(input["storedShare"]), rotation: rotation)
                #expect(Self.same(shown, try Self.rect(want["shown"])), "\(id) shown")
                #expect(Self.same(CanvasTurn.stored(fromShown: shown, rotation: rotation), try Self.rect(want["storedOfShown"])), "\(id) back")
                let search = try #require(ConcealingAnnotations.displayNormalized(try Self.rect(input["pageRectIn"]), crop: c, rotation: rotation))
                #expect(Self.same(search, try Self.rect(want["searchesShare"])), "\(id) search")
            } else if id.hasPrefix("landed-scroll") {
                let g = RunRecord.PageGeometry(cropBox: try #require(crop), rotation: rotation)
                #expect(Self.same(g.pageRect(share: try Self.rect(input["share"])), try Self.rect(want["pageRect"])), "\(id)")
            } else if input["displayedPoint"] != nil {
                let g = RunRecord.PageGeometry(cropBox: try #require(crop), rotation: rotation)
                let p = g.pagePoint(displayed: try Self.point(input["displayedPoint"]))
                #expect(Self.same(p, try Self.point(want["pagePoint"])), "\(id)")
                let hand = try Self.point(want["byHand"])
                #expect(abs(p.x - hand.x) <= 1e-9 && abs(p.y - hand.y) <= 1e-9, "\(id) by hand")
            } else if id.hasPrefix("point-step") {
                let g = RunRecord.PageGeometry(cropBox: try #require(crop), rotation: rotation)
                #expect(Self.same(CGPoint(x: g.pointStep.width, y: g.pointStep.height), try Self.point(want["pointStep"])), "\(id)")
            } else if id.hasPrefix("default-geometry") {
                let bounds = try Self.size(input["overlaySize"])
                let empty = Self.overlay(size: bounds, geometry: RunRecord.PageGeometry(cropBox: try #require(crop), rotation: rotation))
                let before = counted
                #expect(Self.same(empty.overlayToPDFNormalized(try Self.rect(input["overlayRect"])), try Self.rect(want["share"])), "\(id) store")
                #expect(Self.same(empty.pdfNormalizedToOverlay(try Self.rect(input["overlayShare"])), try Self.rect(want["overlayRectOfShare"])), "\(id) draw")
                #expect(counted - before == 2, "\(id): one refusal per map call")
                let withACrop = try #require(want["withACrop"] as? Row)
                let placed = Self.overlay(size: bounds, geometry: RunRecord.PageGeometry(cropBox: CGRect(origin: .zero, size: bounds), rotation: rotation))
                #expect(Self.same(placed.overlayToPDFNormalized(try Self.rect(input["overlayRect"])), try Self.rect(withACrop["share"])), "\(id) store, with a crop")
                #expect(Self.same(placed.pdfNormalizedToOverlay(try Self.rect(input["overlayShare"])), try Self.rect(withACrop["overlayRectOfShare"])), "\(id) draw, with a crop")
            } else if input["overlaySize"] != nil {
                let bounds = try Self.size(input["overlaySize"])
                let o = Self.overlay(size: bounds, geometry: RunRecord.PageGeometry(cropBox: crop ?? Self.letter, rotation: rotation))
                if let s1 = input["overlayShare"] {
                    let drawn = o.pdfNormalizedToOverlay(try Self.rect(s1))
                    #expect(Self.same(drawn, try Self.rect(want["overlayRectOfShare"])), "\(id) draw")
                    #expect(Self.same(o.overlayToPDFNormalized(drawn), try Self.rect(want["share"])), "\(id) back")
                    #expect(Self.same(o.geometry.pageRect(share: try Self.rect(s1)), try Self.rect(want["pageRect"])), "\(id) page rect")
                } else {
                    let share = o.overlayToPDFNormalized(try Self.rect(input["overlayRect"]))
                    #expect(Self.same(share, try Self.rect(want["share"])), "\(id) store")
                    #expect(Self.same(o.pdfNormalizedToOverlay(try Self.rect(want["share"])), try Self.rect(want["overlayRectOfShare"])), "\(id) draw")
                }
            } else {
                let g = RunRecord.PageGeometry(cropBox: try #require(crop), rotation: rotation)
                let share = try Self.rect(input["share"])
                #expect(g.rotation == (want["rotation"] as? NSNumber)?.intValue, "\(id) rotation")
                #expect(Self.same(g.displayedSize, try Self.size(want["displayedSize"])), "\(id) displayed size")
                #expect(Self.same(g.displayedRect(share: share), try Self.rect(want["displayedRect"])), "\(id) displayed rect")
                #expect(Self.same(g.pageRect(share: share), try Self.rect(want["pageRect"])), "\(id) page rect")
                #expect(Self.same(CGPoint(x: g.pointStep.width, y: g.pointStep.height), try Self.point(want["pointStep"])), "\(id) step")
            }
            checked += 1
        }
        #expect(checked == 344)
    }

    /// A seeded generator (SplitMix64), so a failure is the same on every run.
    struct Seeded {
        var state: UInt64
        mutating func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
    }

    static let shapes = [CGRect(x: 0, y: 0, width: 612, height: 792),
                         CGRect(x: 0, y: 0, width: 595.276, height: 841.89),
                         CGRect(x: 0, y: 0, width: 498.898, height: 708.661),
                         CGRect(x: 36, y: 54, width: 540, height: 684),
                         CGRect(x: 0, y: 0, width: 500.3, height: 700.7)]

    @Test("Inside the page, the app's page map and the engine's agree to within 1e-9 pt on every side, at each turn",
          arguments: [0, 90, 180, 270])
    func appPageMapIsTheEngines(turn: Int) {
        var random = Seeded(state: 0x5EED_0000 &+ UInt64(turn))
        var worst: CGFloat = 0
        for crop in Self.shapes {
            let g = RunRecord.PageGeometry(cropBox: crop, rotation: turn)
            for _ in 0..<5_000 {
                let x = random.next(), y = random.next()
                let share = CGRect(x: x, y: y, width: random.next() * (1 - x), height: random.next() * (1 - y))
                let gap = RunRecord.sideGap(g.pageRect(share: share), g.pageRect(ofDisplayedShare: share))
                worst = max(worst, gap)
                if gap > 1e-9 {
                    Issue.record("share \(share) on \(crop) at \(turn): the two maps differ by \(gap) pt")
                    return
                }
            }
        }
        #expect(worst <= 1e-9)
    }
}
