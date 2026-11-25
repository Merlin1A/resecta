import CoreGraphics
import CryptoKit
import Foundation
import RedactionEngine
import Testing
@testable import ResectaApp

private final class BoxWalkCasesBundle: NSObject {}

// The order for stepping through boxes: the case table in Cases/box-walk-order.json,
// `boxes` on binary-exact shares, and five properties over 1,000 seeded pages.
//
// The table's rectangles are top-left, in page points, and `order` is fed them
// unconverted: it only compares and scales, so the unit does not matter, and no
// division by a page size can decide a case by rounding (tops exactly 6 apart on
// boxes 12 tall must split, which pins the strict "less than").

struct BoxWalkTests {
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

    struct Inputs: Decodable {
        var boxes: [TableBox]?
        var step: StepInput?
        var afterDelete: DeleteInput?
    }

    struct TableBox: Decodable {
        var id: String
        var page: Int
        var rect: TableRect
        var created: Int
    }

    struct TableRect: Decodable {
        var x: Double
        var y: Double
        var w: Double
        var h: Double
    }

    struct StepInput: Decodable {
        var n: Int
        var index: Int
        var dir: Int
        var ends: String?
        var dead: [Int]
    }

    struct DeleteInput: Decodable {
        var n: Int
        var index: Int
        var dead: [Int]
    }

    struct Expected: Decodable {
        var order: [String]?
        var index: Int?
    }

    /// The table's bytes; a changed table changes this digest and this list together.
    static let tableSHA256 = "daf4888cd4a5e2c4e3486e2bbdb913445eb5a1c33737618c7f85ec385c7143f6"

    nonisolated static let caseIDs = [
        "one-row-reads-left-to-right",
        "half-the-smaller-height-joins",
        "half-the-smaller-height-splits",
        "pages-first",
        "ties-keep-creation-order",
        "same-left-in-a-row-keeps-creation-order",
        "top-tie-anchors-on-the-earlier",
        "rows-anchor-on-their-first-box",
        "the-mixed-seed-by-its-rectangles",
        "step-default-wraps-at-the-end",
        "step-default-wraps-back-at-the-start",
        "step-default-one-box-forward",
        "step-default-one-box-back",
        "step-default-one-left-of-three",
        "step-default-wrap-skips-a-deleted-first",
        "step-stop-at-the-end",
        "step-wrap-at-the-end",
        "step-back-stop-at-the-start",
        "step-skips-a-deleted-box",
        "step-none-left",
        "delete-moves-to-the-next",
        "delete-at-the-end-wraps",
        "step-empty-order",
        "delete-empty-order",
        "delete-the-last-one",
    ]

    static func tableData() throws -> Data {
        let url = try #require(Bundle(for: BoxWalkCasesBundle.self).url(
            forResource: "box-walk-order",
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
        #expect(table.rule == "box-walk-order")
        #expect(table.cases.map(\.id) == Self.caseIDs)
    }

    @Test(arguments: BoxWalkTests.caseIDs)
    func tableCase(_ id: String) throws {
        let row = try #require(try Self.table().cases.first { $0.id == id })
        if let boxes = row.inputs.boxes {
            var ids: [String: UUID] = [:]
            var names: [UUID: String] = [:]
            let walkBoxes = boxes.map { box -> BoxWalk.Box in
                let uuid = UUID()
                ids[box.id] = uuid
                names[uuid] = box.id
                return BoxWalk.Box(
                    id: uuid,
                    page: box.page,
                    rect: CGRect(x: box.rect.x, y: box.rect.y, width: box.rect.w, height: box.rect.h),
                    created: box.created
                )
            }
            let expected = try #require(row.expected.order)
            #expect(BoxWalk.order(walkBoxes).map { names[$0] ?? "?" } == expected, "\(id)")
        } else if let step = row.inputs.step {
            let order = (0..<step.n).map { _ in UUID() }
            let dead = Set(step.dead.map { order[$0] })
            let direction = try #require(BoxWalk.Direction(rawValue: step.dir))
            let got: Int?
            switch step.ends {
            case nil:
                // The step-default rows give no ends: they pin the default.
                got = BoxWalk.step(order, from: step.index, direction) { !dead.contains($0) }
            case "wrap":
                got = BoxWalk.step(order, from: step.index, direction, ends: .wrap) { !dead.contains($0) }
            case "stop":
                got = BoxWalk.step(order, from: step.index, direction, ends: .stop) { !dead.contains($0) }
            default:
                Issue.record("\(id): unknown ends \(step.ends ?? "")")
                return
            }
            #expect(got == row.expected.index, "\(id)")
        } else if let delete = row.inputs.afterDelete {
            let order = (0..<delete.n).map { _ in UUID() }
            let dead = Set(delete.dead.map { order[$0] })
            #expect(BoxWalk.afterDelete(order, at: delete.index) { !dead.contains($0) } == row.expected.index, "\(id)")
        } else {
            Issue.record("\(id): no inputs")
        }
    }

    // MARK: - `boxes`

    @Test func boxesTurnsTheStoredRectangle() {
        // Edges are sums of powers of two, so every turned value is exact.
        func region(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> RedactionRegion {
            RedactionRegion(id: UUID(), normalizedRect: CGRect(x: x, y: y, width: w, height: h), source: .manual)
        }
        let first = region(0.25, 0.5, 0.125, 0.25)
        let second = region(0.5, 0.125, 0.25, 0.375)
        let third = region(0, 0.75, 0.5, 0.25)
        let boxes = BoxWalk.boxes([0: [first, second], 3: [third]])
        let byID = Dictionary(uniqueKeysWithValues: boxes.map { ($0.id, $0) })
        #expect(boxes.count == 3)
        #expect(byID[first.id] == BoxWalk.Box(id: first.id, page: 0, rect: CGRect(x: 0.25, y: 0.25, width: 0.125, height: 0.25), created: 0))
        #expect(byID[second.id] == BoxWalk.Box(id: second.id, page: 0, rect: CGRect(x: 0.5, y: 0.5, width: 0.25, height: 0.375), created: 1))
        #expect(byID[third.id] == BoxWalk.Box(id: third.id, page: 3, rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.25), created: 0))
    }

    // MARK: - Five properties over 1,000 seeded pages

    /// A box of a seeded page, by name.
    struct Seeded {
        var name: String
        var page: Int
        var rect: CGRect
        var created: Int
    }

    /// mulberry32: a 32-bit generator, ported bit for bit so the seeded pages are
    /// the ones the rule was designed against.
    struct Generator {
        var state: UInt32
        mutating func next() -> Double {
            state = state &+ 0x6D2B_79F5
            var t = (state ^ (state >> 15)) &* (1 | state)
            t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
            return Double(t ^ (t >> 14)) / 4_294_967_296
        }

        mutating func below(_ n: Int) -> Int { Int((next() * Double(n)).rounded(.down)) }
    }

    /// Whole sixty-fourths of a point.
    static func sixtyFourths(_ value: Double) -> Double { (value * 64).rounded(.down) / 64 }

    /// 2 to 15 boxes on pages 1, 2, 3, 10 and 11, with exact ties, a same top with
    /// twice the height plus a box 0.75 of the height below that only the taller
    /// anchor would hold, a same left edge within a row made in the reverse of its
    /// top order, and sometimes a box above all others. Every coordinate is in
    /// whole sixty-fourths, so every comparison is exact.
    static func page(_ r: inout Generator) -> [Seeded] {
        var boxes: [Seeded] = []
        let n = 2 + r.below(14)
        let pages = [1, 2, 3, 10, 11]
        for k in 0..<n {
            let pg = pages[r.below(pages.count)]
            let x = (r.next() * 500 * 64).rounded(.down) / 64
            let y = sixtyFourths(60 + r.next() * 600)
            let w = sixtyFourths(5 + r.next() * 100)
            let h = sixtyFourths(6 + r.next() * 14)
            let rect = CGRect(x: x, y: y, width: w, height: h)
            boxes.append(Seeded(name: "b\(k)", page: pg, rect: rect, created: k))
            let tie = r.next()
            if tie < 0.1 {
                boxes.append(Seeded(name: "b\(k)d", page: pg, rect: rect, created: n + k))
            } else if tie < 0.25 {
                boxes.append(Seeded(name: "b\(k)t", page: pg, rect: CGRect(x: x + 64, y: y, width: w, height: h * 2), created: n + k))
                boxes.append(Seeded(name: "b\(k)u", page: pg,
                                    rect: CGRect(x: x + 128, y: y + (h * 48).rounded(.down) / 64, width: w, height: h * 2),
                                    created: 3 * n + k))
            } else if tie < 0.4 {
                boxes.append(Seeded(name: "b\(k)l", page: pg, rect: CGRect(x: x, y: y - (h * 16).rounded(.down) / 64, width: w, height: h),
                                    created: n + k))
            }
        }
        if r.next() < 0.5 {
            boxes.append(Seeded(name: "top", page: 1, rect: CGRect(x: 300, y: 10, width: 50, height: 12), created: 2 * n + 1))
        }
        return boxes
    }

    static func shuffled(_ boxes: [Seeded], _ r: inout Generator) -> [Seeded] {
        var out = boxes
        var i = out.count - 1
        while i > 0 {
            let j = r.below(i + 1)
            out.swapAt(i, j)
            i -= 1
        }
        return out
    }

    /// The order by name. Ids are made afresh on each call, so nothing but the
    /// rectangles, pages and `created` can decide it.
    static func names(_ boxes: [Seeded]) -> [String] {
        var names: [UUID: String] = [:]
        let walkBoxes = boxes.map { box -> BoxWalk.Box in
            let id = UUID()
            names[id] = box.name
            return BoxWalk.Box(id: id, page: box.page, rect: box.rect, created: box.created)
        }
        return BoxWalk.order(walkBoxes).map { names[$0] ?? "?" }
    }

    @Test func theFivePropertiesOverSeededPages() {
        var r = Generator(state: 0x5A10)
        var failures: [String] = []
        for t in 0..<1000 {
            let boxes = Self.page(&r)
            let got = Self.names(boxes)
            let pageOf = Dictionary(uniqueKeysWithValues: boxes.map { ($0.name, $0.page) })

            // 1. A permutation of the input's ids.
            if got.sorted() != boxes.map(\.name).sorted() { failures.append("page \(t): not a permutation") }

            // 2. Pages ascend.
            for i in got.indices.dropFirst() where (pageOf[got[i - 1]] ?? 0) > (pageOf[got[i]] ?? 0) {
                failures.append("page \(t): pages do not ascend at \(i)")
            }

            // 3. The input's order does not matter.
            if Self.names(Self.shuffled(boxes, &r)) != got { failures.append("page \(t): the input's order changed the order") }

            // 4. One scale and one shift per page give the same order.
            var seen: [Int] = []
            for box in boxes where !seen.contains(box.page) { seen.append(box.page) }
            var moves: [Int: (s: Double, dx: Double, dy: Double)] = [:]
            for pg in seen {
                let s = [0.5, 2, 4][r.below(3)]
                let dx = (r.next() * 64 * 64).rounded(.down) / 64 - 32
                let dy = (r.next() * 64 * 64).rounded(.down) / 64 - 32
                moves[pg] = (s, dx, dy)
            }
            let moved = boxes.map { box -> Seeded in
                let m = moves[box.page] ?? (1, 0, 0)
                var out = box
                out.rect = CGRect(x: box.rect.minX * m.s + m.dx, y: box.rect.minY * m.s + m.dy,
                                  width: box.rect.width * m.s, height: box.rect.height * m.s)
                return out
            }
            if Self.names(moved) != got { failures.append("page \(t): a scale and shift changed the order") }

            // 5. A box wholly above every other box of its page comes first on it.
            for box in boxes {
                let others = boxes.filter { $0.page == box.page && $0.name != box.name }
                if !others.isEmpty, others.allSatisfy({ box.rect.minY + box.rect.height <= $0.rect.minY }),
                   got.first(where: { pageOf[$0] == box.page }) != box.name {
                    failures.append("page \(t): \(box.name) is above all others and not first")
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.prefix(5)) of \(failures.count)")
    }

    /// The same 1,000 pages, drawn the same way, give exactly the reference
    /// implementation's numbers: the generator is the same (every draw of the run,
    /// counted by the boxes and the draw after the last page), and so is the order
    /// on every page (the digest of all 1,000 orders, joined by name).
    @Test func theSeededPagesMatchTheReference() {
        var r = Generator(state: 0x5A10)
        #expect([r.next(), r.next(), r.next()] == [0.6468568677082658, 0.4002974887844175, 0.9265064722858369])
        r = Generator(state: 0x5A10)
        var total = 0
        var joined = ""
        for _ in 0..<1000 {
            let boxes = Self.page(&r)
            total += boxes.count
            joined += Self.names(boxes).joined(separator: ",") + ";"
            _ = Self.shuffled(boxes, &r)
            var seen: [Int] = []
            for box in boxes where !seen.contains(box.page) { seen.append(box.page) }
            for _ in seen { _ = r.next(); _ = r.next(); _ = r.next() }
        }
        let digest = SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(total == 13570)
        #expect(r.next() == 0.22758495225571096)
        #expect(digest == "331c318c341a600fe08bf0f388a2b04130f87bb9eae8a473db5807707581156a")
    }
}
