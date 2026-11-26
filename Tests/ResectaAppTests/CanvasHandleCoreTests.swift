import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import ResectaApp

private final class HandleCoreCasesBundle: NSObject {}

// The handle core. Within a square of 22 on-screen points centred on a drawn
// handle of the selected box, that handle takes the touch, over another box's
// body too; on the selected box itself the box is decided as if it were
// alone; outside every core the rule is the one without it. The case table is
// Cases/handle-core.json: each geometry twice, the core off and on, on the
// handle centres it was made with.

@Suite("Canvas handle core")
@MainActor
struct CanvasHandleCoreTests {
    static let tableSHA256 = "ea4021e6a6b9213e7fca37878ea54c7c45231604e41fb0a4ba465549721d98e6"

    struct Table: Decodable {
        let rule: String
        let cases: [Row]
    }
    struct Row: Decodable {
        let id: String
        let inputs: Inputs
        let expected: Expected
    }
    struct Inputs: Decodable {
        let point: Point
        let regions: [Region]
        let selected: String?
        let multiSelect: Bool
        let zoom: CGFloat
        let centres: [Centre]
        let sizes: Sizes
        enum CodingKeys: String, CodingKey {
            case point, regions, selected, multiSelect, zoom, centres
            case sizes = "P"
        }
    }
    struct Point: Decodable {
        let x: CGFloat
        let y: CGFloat
        var cgPoint: CGPoint { CGPoint(x: x, y: y) }
    }
    struct Region: Decodable {
        struct Rect: Decodable { let x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat }
        let id: String
        let rect: Rect
        var cgRect: CGRect { CGRect(x: rect.x, y: rect.y, width: rect.w, height: rect.h) }
    }
    struct Centre: Decodable {
        let handle: String
        let point: Point
    }
    /// On-screen points, as the table states them.
    struct Sizes: Decodable {
        let hitHalo: CGFloat
        let handleTarget: CGFloat
        let handleMinimum: CGFloat
        let bodyReachCap: CGFloat
        let handleCore: CGFloat
        let handleModel: String
        let handleStepBelow: CGFloat
        let handleStepMax: CGFloat
        let handleEdgeMinSide: CGFloat
        let handleCoreWins: Bool
    }
    struct Expected: Decodable {
        let pick: String?
        let coreDecided: Bool
    }

    nonisolated static let caseIDs = [
        "app-smallest-body-off",
        "app-smallest-body-on",
        "app-smallest-body-reversed-off",
        "app-smallest-body-reversed-on",
        "app-equal-areas-later-off",
        "app-equal-areas-later-on",
        "app-halo-upper-off",
        "app-halo-upper-on",
        "app-halo-lower-off",
        "app-halo-lower-on",
        "app-outside-every-halo-off",
        "app-outside-every-halo-on",
        "app-corner-off-the-other-off",
        "app-corner-off-the-other-on",
        "app-corner-on-the-other-off",
        "app-corner-on-the-other-on",
        "app-core-scaled-off",
        "app-core-scaled-on",
        "app-past-the-core-off",
        "app-past-the-core-on",
        "app-own-body-off",
        "app-own-body-on",
        "add-to-selection-no-handles-off",
        "add-to-selection-no-handles-on",
        "stacked-AB-fit-off",
        "stacked-AB-fit-on",
        "stacked-AB-3.5x-off",
        "stacked-AB-3.5x-on",
        "stacked-C-fit-off",
        "stacked-C-fit-on",
        "stacked-C-3.5x-off",
        "stacked-C-3.5x-on",
        "tiny-inside-the-core-off",
        "tiny-inside-the-core-on",
        "tiny-halo-outside-the-core-off",
        "tiny-halo-outside-the-core-on",
        "tiny-zoomed-in-off",
        "tiny-zoomed-in-on",
        "overlap-tl-off",
        "overlap-tl-on",
        "overlap-tr-off",
        "overlap-tr-on",
        "overlap-br-off",
        "overlap-br-on",
        "overlap-left-lower-off",
        "overlap-left-lower-on",
        "overlap-own-middle-off",
        "overlap-own-middle-on",
        "own-body-over-a-larger-box-off",
        "own-body-over-a-larger-box-on",
        "whole-page-under-the-corner-off",
        "whole-page-under-the-corner-on",
        "own-body-over-a-smaller-box-off",
        "own-body-over-a-smaller-box-on",
        "stacked-midpoint-3.5x-off",
        "stacked-midpoint-3.5x-on",
    ]

    static func tableData() throws -> Data {
        let url = try #require(Bundle(for: HandleCoreCasesBundle.self).url(
            forResource: "handle-core",
            withExtension: "json"
        ))
        return try Data(contentsOf: url)
    }

    static func table() throws -> Table {
        try JSONDecoder().decode(Table.self, from: tableData())
    }

    /// The row's pick through the app's rule, at the row's zoom: every size is
    /// the table's on-screen size over the zoom, with the core or without it.
    /// "handle:<name>", "region:<the table's id>" or nil, as the table writes it.
    static func pick(_ row: Row, core: Bool) -> String? {
        let inputs = row.inputs
        let regions = inputs.regions.map { (name: $0.id, id: UUID(), rect: $0.cgRect) }
        let selected = inputs.multiSelect ? nil : inputs.selected.flatMap { name in
            regions.first { $0.name == name }.map { (id: $0.id, rect: $0.rect) }
        }
        let sizes = inputs.sizes
        let target = RedactionOverlayView.resolveHitTarget(
            at: inputs.point.cgPoint, regions: regions.map { (id: $0.id, rect: $0.rect) }, selected: selected,
            halo: sizes.hitHalo / inputs.zoom, handleSize: sizes.handleTarget / inputs.zoom,
            minimumHandleSize: sizes.handleMinimum / inputs.zoom, containerBounds: nil,
            fingerScale: 1 / inputs.zoom, coreSize: core ? sizes.handleCore / inputs.zoom : nil)
        switch target {
        case .handle(let handle)?: return "handle:\(handle)"
        case .region(let id)?: return regions.first { $0.id == id }.map { "region:" + $0.name }
        case nil: return nil
        }
    }

    @Test("The table is the one of record, made on the app's handle sizes")
    func theTableIsTheOneOfRecord() throws {
        let data = try Self.tableData()
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(digest == Self.tableSHA256)
        let table = try Self.table()
        #expect(table.rule == "handle-core")
        #expect(table.cases.map(\.id) == Self.caseIDs)
        #expect(table.cases.count == 56)
        #expect(table.cases.filter(\.expected.coreDecided).count == 9)
        typealias C = ResectaTokens.Canvas
        for row in table.cases {
            let sizes = row.inputs.sizes
            #expect(sizes.handleModel == "ub14", "\(row.id)")
            #expect(sizes.handleCore == C.handleCore, "\(row.id)")
            #expect(sizes.handleStepBelow == C.handlesStepOutBelow, "\(row.id)")
            #expect(sizes.handleStepMax == C.handleLargestStep, "\(row.id)")
            #expect(sizes.handleEdgeMinSide == C.edgeHandleShortestSide, "\(row.id)")
            #expect(sizes.handleMinimum == 22, "\(row.id)")
            #expect(sizes.bodyReachCap == 0.25, "\(row.id)")
            #expect(sizes.handleCoreWins == row.id.hasSuffix("-on"), "\(row.id)")
        }
    }

    @Test("Each row: the selected box's handle centres, the pick, and whether the core decided it",
          arguments: CanvasHandleCoreTests.caseIDs)
    func tableRow(_ id: String) throws {
        let row = try #require(try Self.table().cases.first { $0.id == id })
        let inputs = row.inputs
        if let name = inputs.selected, !inputs.multiSelect {
            let rect = try #require(inputs.regions.first { $0.id == name }).cgRect
            let centres = RedactionOverlayView.handleCentres(for: rect, fingerScale: 1 / inputs.zoom)
            #expect(centres.map { "\($0.0)" } == inputs.centres.map(\.handle))
            #expect(centres.map { $0.1 } == inputs.centres.map(\.point.cgPoint))
        } else {
            #expect(inputs.centres.isEmpty)
        }
        let on = inputs.sizes.handleCoreWins
        #expect(Self.pick(row, core: on) == row.expected.pick)
        let decided = on && Self.pick(row, core: true) != Self.pick(row, core: false)
        #expect(decided == row.expected.coreDecided)
    }
}
