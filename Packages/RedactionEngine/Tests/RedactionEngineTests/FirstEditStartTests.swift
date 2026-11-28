import CoreGraphics
import CryptoKit
import Foundation
import PDFKit
import Testing
@testable import RedactionCore
@testable import RedactionEngine

// A first edit's start, as the plan works it out: the start rule's cases from
// the table in Fixtures/TestResources/first-edit-start.json, whether a joined
// box stands on one line, the share's round trip to whole sixty-fourths, and a
// plan made with the page's words and without them.
//
// Every comparison of a start is in whole sixty-fourths.

@Suite("First edit's start")
struct FirstEditStartTests {

    // MARK: - The table

    struct Rect: Decodable, Sendable {
        let minX: Int, minY: Int, maxX: Int, maxY: Int
        var r64: PageRect64 { PageRect64(minX: minX, minY: minY, maxX: maxX, maxY: maxY) }
    }

    struct Share: Decodable, Sendable {
        let minX: Double, minY: Double, maxX: Double, maxY: Double
        var rect: CGRect { CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY) }
    }

    struct Side: Decodable, Sendable {
        let W: Int
        let H: Int
    }

    struct Box: Decodable, Sendable {
        let rect: Rect
        let neighbours: [Rect]
        let paint: Rect
        let oneLineBox: Bool
        /// Absent where it equals the rectangle.
        let tight: Rect?
        let neighbourTights: [Rect]?
    }

    struct Start: Decodable, Sendable {
        let box: Box
    }

    struct Inputs: Decodable, Sendable {
        let page: Side
        /// A region of a box, with the box's paint and its other regions.
        let start: Start?
        /// A box alone: its paint.
        let startOf: Rect?
    }

    struct Expected: Decodable, Sendable {
        let rect: Rect
        let clause: Int?
        let share: Share?
        /// The share a rectangle slid back onto the page would give: never
        /// the start's.
        let slidShare: Share?
    }

    struct Case: Decodable, Sendable {
        let id: String
        let inputs: Inputs
        let expected: Expected
    }

    struct Table: Decodable, Sendable {
        let rule: String
        let units: String
        let cases: [Case]
    }

    static let tableSHA256 = "ed3fc783ff997071d0783bc4f729fa7f8138244b837a92c83d61e992b73a4a47"

    static let caseIDs = [
        "start-name",
        "start-past-the-left-and-top",
        "start-past-the-left",
        "start-past-the-bottom",
        "J-start-alone",
        "J-start-held",
        "J-start-held-edges-coincide",
        "J-start-held-left-edge",
        "J-start-held-one-line",
        "J-start-held-level-one-line",
        "J-start-held-by-1-64-out",
        "J-start-not-held-by-two",
        "J-start-personal",
        "J-start-checking",
        "J-start-middle-of-three",
        "J-start-end-of-three",
        "J-start-touching-left",
        "J-start-touching-right",
        "J-start-overlap-sticks-out-right",
        "J-start-overlap-sticks-out-left",
        "J-start-edge-shared-left",
        "J-start-edge-shared-right",
        "J-start-nearest-cut",
        "J-start-bridge",
        "J-start-poke-one-line",
        "J-start-not-level",
        "J-start-level-off-by-one",
        "J-start-poke-several-lines",
        "J-start-stickout",
        "J-start-one-line-holding-a-letter",
        "J-start-level-by-tight",
        "J-start-equal-not-held",
        "J-start-equal-several-lines",
        "J-start-mixed-309-not-level",
        "J-start-columns-2224-not-level",
        "J-start-pokedeep-5342-not-level",
        "J-start-taller-region-not-level",
        "J-start-pokedeep-519-reach",
    ]

    static func tableData() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "first-edit-start", withExtension: "json",
                                                 subdirectory: "TestResources"))
        return try Data(contentsOf: url)
    }

    static func table() throws -> Table {
        try JSONDecoder().decode(Table.self, from: tableData())
    }

    @Test("The table is the one of record: its sha256, its rule and its cases in order")
    func theTableIsTheOneOfRecord() throws {
        let digest = SHA256.hash(data: try Self.tableData()).map { String(format: "%02x", $0) }.joined()
        #expect(digest == Self.tableSHA256)
        let table = try Self.table()
        #expect(table.rule == "first-edit-start")
        #expect(table.cases.map(\.id) == Self.caseIDs)
    }

    /// A share on a page read back in whole sixty-fourths, each edge times the
    /// side and rounded to the nearest whole number.
    static func nearest(_ share: CGRect, _ side: Side) -> PageRect64 {
        let w = Double(side.W), h = Double(side.H)
        return PageRect64(minX: Int((share.minX * w).rounded()), minY: Int((share.minY * h).rounded()),
                          maxX: Int((share.maxX * w).rounded()), maxY: Int((share.maxY * h).rounded()))
    }

    /// A share read back as the plan reads a region: `PageRect64(share:)`.
    static func readBack(_ share: CGRect, _ side: Side) -> PageRect64? {
        PageRect64(share: PointRect(minX: share.minX, minY: share.minY, maxX: share.maxX, maxY: share.maxY),
                   widthSixtyFourths: side.W, heightSixtyFourths: side.H)
    }

    @Test("Each case of the table: the start and the clause that decided it", arguments: caseIDs)
    func tableCase(_ id: String) throws {
        let row = try #require(try Self.table().cases.first { $0.id == id })
        let side = row.inputs.page
        let start: PlannedStart
        if let box = row.inputs.start?.box {
            start = FirstEditStartRule.start(
                own: box.rect.r64, paint: box.paint.r64, neighbours: box.neighbours.map(\.r64),
                tight: (box.tight ?? box.rect).r64,
                neighbourTights: (box.neighbourTights ?? box.neighbours).map(\.r64),
                oneLineBox: box.oneLineBox, widthSixtyFourths: side.W, heightSixtyFourths: side.H)
        } else {
            let paint = try #require(row.inputs.startOf).r64
            start = FirstEditStartRule.start(own: paint, paint: paint, neighbours: [], tight: paint,
                                             neighbourTights: [], oneLineBox: false,
                                             widthSixtyFourths: side.W, heightSixtyFourths: side.H)
        }
        #expect(start.rect == row.expected.rect.r64, "\(id): \(start.rect)")
        if let clause = row.expected.clause { #expect(start.clause == clause, "\(id): clause \(start.clause)") }
        // The share the kept plan gives reads back to the start exactly, and is
        // never the share of the box slid back onto the page.
        let plan = PaintPlan(widthSixtyFourths: side.W, heightSixtyFourths: side.H, boxes: [])
        let share = DrawnPlan.firstEditStart(start, plan: plan).share
        #expect(Self.readBack(share, side) == row.expected.rect.r64, "\(id)")
        if let expected = row.expected.share {
            #expect(Self.nearest(share, side) == Self.nearest(expected.rect, side), "\(id)")
        }
        if let slid = row.expected.slidShare {
            #expect(Self.nearest(share, side) != Self.nearest(slid.rect, side), "\(id): the start was slid")
        }
    }

    // MARK: - One line

    @Test("A joined box stands on one line only with one row and no whole letter of another line in its paint")
    func oneLineBox() {
        // One row of letters, and a paint 64 out round it.
        let row = PageRect64(minX: 0, minY: 1000, maxX: 3000, maxY: 1640)
        let paint = PageRect64(minX: -64, minY: 936, maxX: 3064, maxY: 1704)
        let onTheRow = PageRect64(minX: 100, minY: 1000, maxX: 400, maxY: 1640)
        // A letter of the line above lying wholly inside the paint, and one
        // the paint only cuts.
        let aboveInside = PageRect64(minX: 500, minY: 1650, maxX: 700, maxY: 1700)
        let aboveCut = PageRect64(minX: 500, minY: 1650, maxX: 700, maxY: 2290)
        let second = PageRect64(minX: 0, minY: 0, maxX: 3000, maxY: 640)
        #expect(!FirstEditStartRule.oneLineBox(rows: [row], paint: paint, pageLetters: [onTheRow, aboveInside]),
                "one row, its paint holding another line's whole letter")
        #expect(!FirstEditStartRule.oneLineBox(rows: [row, second], paint: paint, pageLetters: [onTheRow]),
                "two rows")
        #expect(FirstEditStartRule.oneLineBox(rows: [row], paint: paint, pageLetters: [onTheRow, aboveCut]),
                "one row, another line's letter only cut by the paint")
        // A box read as a scan or a picture, or by its direction, has no rows:
        // never one line, so a joined one starts from the whole paint.
        #expect(!FirstEditStartRule.oneLineBox(rows: [], paint: paint, pageLetters: [onTheRow]), "no rows")
        let a = PageRect64(minX: 0, minY: 1000, maxX: 1400, maxY: 1640)
        let b = PageRect64(minX: 1600, minY: 1000, maxX: 3000, maxY: 1640)
        let start = FirstEditStartRule.start(own: a, paint: paint, neighbours: [b], tight: a, neighbourTights: [b],
                                             oneLineBox: false, widthSixtyFourths: 39168, heightSixtyFourths: 50688)
        #expect(start.clause == 4)
        #expect(start.rect == PageRect64(minX: 0, minY: 936, maxX: 3064, maxY: 1704))
    }

    // MARK: - The round trip

    /// How many of the edges given miss their read-back on a side S: each k₀
    /// in `mins` as the min edge, and each k₀ + span for each span as the
    /// max edge, read through `PageRect64(share:)` with the far edge as
    /// `CGRect` adds it.
    static func misses(side s: Int, mins: [Int], spans: [Int]) -> Int {
        var missed = 0
        for k0 in mins {
            for span in spans where k0 + span <= s {
                let k1 = k0 + span
                let x = FirstEditStartRule.share(minEdge: k0, maxEdge: k1, side: s)
                let share = CGRect(x: x.origin, y: 0, width: x.length, height: 1)
                guard let back = PageRect64(share: PointRect(minX: share.minX, minY: 0, maxX: share.maxX, maxY: 1),
                                            widthSixtyFourths: s, heightSixtyFourths: 1),
                      back.minX == k0, back.maxX == k1 else { missed += 1; continue }
            }
        }
        return missed
    }

    static func spans(_ s: Int) -> [Int] { [1, 7, 64, 700, s / 2, s] }

    @Test("A start's share reads back to its sixty-fourths exactly: every edge of Letter's and A4's sides",
          arguments: [39168, 50688, 38098, 53881])
    func roundTripOnLetterAndA4(side: Int) {
        // Every k₀ in 0…S as the min edge; every k₁ = k₀ + span for six spans.
        let mins = Array(0...side)
        #expect(Self.misses(side: side, mins: mins, spans: Self.spans(side)) == 0)
    }

    /// The edges of record that reach the share's fourth step, as (S, k₀,
    /// k₁): three and two on A4's sides, two on 401.123 pt, one on Letter's
    /// height. Over every k₁ at the six spans the seven named sides hold 73
    /// such edges, all with k₀ ≤ 467; these eight are held by name, whatever
    /// the sweep above takes.
    static let stepFourEdges: [(side: Int, k0: Int, k1: Int)] = [
        (38098, 19, 719), (38098, 316, 1016), (38098, 467, 1167),
        (53881, 23, 87), (53881, 140, 840),
        (25672, 4, 11), (25672, 32, 96),
        (50688, 51, 751),
    ]

    @Test("Eight edges of record reach the share's fourth step, and each reads back to its sixty-fourths exactly")
    func stepFourEdgesReadBack() {
        #expect(Self.stepFourEdges.count == 8)
        for (s, k0, k1) in Self.stepFourEdges {
            // Steps 1 to 3 alone, as the rule's comment gives them: the sum
            // still misses k₁, so the edge needs step 4.
            let side = Double(s), hi = Double(k1)
            var x = Double(k0) / side
            if Int((x * side).rounded(.down)) != k0 { x = x.nextUp }
            var m = hi / side
            if Int((m * side).rounded(.up)) != k1 { m = m * side > hi ? m.nextDown : m.nextUp }
            #expect(Int(((x + (m - x)) * side).rounded(.up)) != k1, "side \(s) (\(k0), \(k1)) reaches step 4")
            #expect(Self.misses(side: s, mins: [k0], spans: [k1 - k0]) == 0, "side \(s) (\(k0), \(k1)) reads back")
        }
    }

    /// The model's 200 seeded sides: mulberry32 with its seed, each side from
    /// 72 to 14,400 pt at a thousandth of a point, in sixty-fourths by
    /// `PixelPlan.sixtyFourths(ofSide:)`.
    static func seededSides() throws -> [(points: Double, side: Int)] {
        var generator = Mulberry32(seed: 0x5238_4221)
        return try (0..<200).map { _ in
            let points = ((72 + generator.next() * (14_400 - 72)) * 1000).rounded(.toNearestOrAwayFromZero) / 1000
            return (points, try #require(PixelPlan.sixtyFourths(ofSide: points)))
        }
    }

    /// Set to 1 to read back every edge of the seeded sides too (about 556
    /// million pairs; minutes on a debug build). Otherwise each seeded side
    /// reads back 512 seeded min edges.
    static let everyEdge = ProcessInfo.processInfo.environment["FIRST_EDIT_EVERY_EDGE"] == "1"

    @Test("A start's share reads back to its sixty-fourths exactly on other sides: 401.123, 1008 and 1224 pt, and the model's 200 seeded sides")
    func roundTripOnOtherSides() throws {
        let named = try [401.123, 1008, 1224].map { try #require(PixelPlan.sixtyFourths(ofSide: $0)) }
        let seeded = try Self.seededSides()
        // The model's sides: its seeded range, read from its own run.
        #expect(seeded.map(\.points).min() == 84.925 && seeded.map(\.points).max() == 14_368.229)
        for s in named {
            #expect(Self.misses(side: s, mins: Array(0...s), spans: Self.spans(s)) == 0, "side \(s)")
        }
        var sample = Mulberry32(seed: 0x5EED_F1E5)
        var pairs = 0
        for (_, s) in seeded {
            let mins = Self.everyEdge ? Array(0...s) : (0..<512).map { _ in Int(sample.next() * Double(s + 1)) }
            #expect(Self.misses(side: s, mins: mins, spans: Self.spans(s)) == 0, "side \(s)")
            pairs += mins.count * Self.spans(s).count
        }
        print("[first-edit-round-trip] seeded sides \(seeded.count), every edge \(Self.everyEdge), edge pairs tried at most \(pairs)")
    }

    // MARK: - The plan's own starts

    /// A typed page and one region over each of its words, placed from its
    /// text and anchored to the word's characters.
    static func typedPage(_ text: String) async throws -> (read: RunRecord.PageRead, side: CGSize,
                                                         regions: [RedactionRegion]) {
        let data = TestFixtures.textLayerPDF(text: text, fontSize: 24)
        let document = SendablePDFDocument(try #require(PDFDocument(data: data)))
        let read = try #require(await RunRecord.PageRead.reads(of: document, pages: [0], hasHiddenOCG: false)[0])
        let side = try #require(PDFDocument(data: data)?.page(at: 0)).bounds(for: .cropBox).size
        let regions = try read.words.words.map { word in
            let box = try #require(word.box)
            var region = RedactionRegion(
                id: UUID(),
                normalizedRect: CGRect(x: box.minX / side.width, y: box.minY / side.height,
                                       width: (box.maxX - box.minX) / side.width,
                                       height: (box.maxY - box.minY) / side.height),
                source: .searchMatch(term: text), textAnchored: true)
            region.pageCharacters = try #require(word.letters.first)..<(try #require(word.letters.last) + 1)
            return region
        }
        return (read, side, regions)
    }

    static func plan(_ regions: [RedactionRegion], side: CGSize, read: RunRecord.PageRead?) -> DrawnPlan {
        DrawnPlan(pageIndex: 0, regions: regions, cropBox: side, rotation: 0, switchOn: true, exportDPI: 300,
                  fillColor: .black, read: read, source: .switchPolicy)
    }

    @Test("Two found boxes side by side on one line, level, start by clause 3 with the page's words, and have no start without them")
    func aPlanWithoutTheWordsGivesNoStart() async throws {
        let page = try await Self.typedPage("Ann Ann")
        #expect(page.regions.count == 2)
        let with = Self.plan(page.regions, side: page.side, read: page.read)
        let without = Self.plan(page.regions, side: page.side, read: nil)
        #expect(with.boxes.count == 1, "the two join")
        for region in page.regions {
            let start = try #require(with.firstEditStart(for: region.id))
            #expect(start.clause == 3)
            let w = try #require(with.widthSixtyFourths), h = try #require(with.heightSixtyFourths)
            #expect(PageRect64(share: PointRect(minX: start.share.minX, minY: start.share.minY,
                                                maxX: start.share.maxX, maxY: start.share.maxY),
                               widthSixtyFourths: w, heightSixtyFourths: h) != nil)
            #expect(without.firstEditStart(for: region.id) == nil)
        }
    }

    @Test("A box drawn by hand has no start, nor a region the plan does not hold; a box placed from a picture starts from its whole paint")
    func whoHasAStart() async throws {
        let page = try await Self.typedPage("Ann")
        let hand = RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.05),
                                   source: .manual)
        let picture = RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.2, y: 0.2, width: 0.1, height: 0.05),
                                      source: .detectedFace)
        let drawn = Self.plan(page.regions + [hand, picture], side: page.side, read: page.read)
        #expect(drawn.firstEditStart(for: hand.id) == nil)
        #expect(drawn.firstEditStart(for: UUID()) == nil)
        let start = try #require(drawn.firstEditStart(for: picture.id))
        #expect(start.clause == 1)
        let box = try #require(drawn.boxes.first { $0.regionIDs == [picture.id] })
        let w = try #require(drawn.widthSixtyFourths), h = try #require(drawn.heightSixtyFourths)
        func r64(_ r: CGRect) -> PageRect64 {
            PageRect64(minX: Int((r.minX * Double(w)).rounded()), minY: Int((r.minY * Double(h)).rounded()),
                       maxX: Int((r.maxX * Double(w)).rounded()), maxY: Int((r.maxY * Double(h)).rounded()))
        }
        #expect(r64(start.share) == r64(box.paint))
        #expect(try #require(drawn.firstEditStart(for: page.regions[0].id)).clause == 1, "a found box alone")
    }
}

extension FirstEditStartTests {

    // MARK: - The found boxes of a real page

    struct FoundBoxes: Decodable {
        struct Document: Decodable { let resource: String; let sha256: String; let pageIndex: Int }
        struct Share: Decodable { let x: Double; let y: Double; let width: Double; let height: Double }
        /// A box's start through the real plan, with the model's clause for
        /// the boxes the rows also name (nil for the others).
        struct Expected: Decodable { let rect: Rect; let clause: Int; let modelClause: Int? }
        let document: Document
        let page: Side
        let regions: [Share]
        /// The found boxes that stand for no single range of the page's characters.
        let characterless: [Rect]
        let expected: [Expected]
    }

    static func order(_ a: PageRect64, _ b: PageRect64) -> Bool {
        (a.minX, a.minY, a.maxX, a.maxY) < (b.minX, b.minY, b.maxX, b.maxY)
    }

    static let foundBoxesSHA256 = "11c003eeb87fa4b09a599943c11ba988d2944937e0ae7f7a232a511cc83fbf73"

    @Test("The found boxes of the sample statement's first page start by their clauses through the real plan, the switch off and on",
          arguments: [false, true])
    func foundBoxesOfARealPage(switchOn: Bool) async throws {
        let url = try #require(Bundle.module.url(forResource: "first-edit-start-found-boxes", withExtension: "json",
                                                 subdirectory: "TestResources"))
        let raw = try Data(contentsOf: url)
        #expect(SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined() == Self.foundBoxesSHA256)
        let table = try JSONDecoder().decode(FoundBoxes.self, from: raw)
        let data = try TestFixtures.sampleStatementPDF()
        #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == table.document.sha256)
        let pdf = try #require(PDFDocument(data: data))
        let index = table.document.pageIndex
        // The page's found boxes as the app's searches place them: Search for
        // a common word and for a name, then Scan over every category, each
        // with the app's default options.
        let modes: [SearchMode] = [.text("Balance", options: SearchOptions()), .text("Hartwell", options: SearchOptions()),
                                   .piiScan(categories: Set(PIICategory.allCases), options: SearchOptions())]
        var regions: [RedactionRegion] = []
        for mode in modes {
            for await result in DocumentSearcher().search(SendablePDFDocument(pdf), mode: mode, progress: { _, _ in })
            where result.pageIndex == index {
                regions.append(RedactionRegion(placing: result))
            }
        }
        // They are the boxes the table records, each read from the text layer.
        let found = regions.compactMap { Self.readBack($0.normalizedRect, table.page) }
        let recorded = table.regions.compactMap {
            Self.readBack(CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height), table.page)
        }
        #expect(regions.count == 21 && recorded.count == 21)
        #expect(found.sorted(by: Self.order) == recorded.sorted(by: Self.order))
        #expect(regions.allSatisfy { $0.textAnchored })
        // The two wide Address boxes stand for no single range of the page's
        // characters: the plan selects none of their letters, so nothing
        // joins them and the boxes they hold stand alone.
        let characterless = table.characterless.map(\.r64)
        #expect(regions.filter { $0.pageCharacters == nil }.compactMap { Self.readBack($0.normalizedRect, table.page) }
            .sorted(by: Self.order) == characterless.sorted(by: Self.order))
        let read = try #require(await RunRecord.PageRead.reads(of: SendablePDFDocument(pdf), pages: [index],
                                                               hasHiddenOCG: false)[index])
        let side = try #require(pdf.page(at: index)).bounds(for: .cropBox).size
        let plan = DrawnPlan(pageIndex: index, regions: regions, cropBox: side, rotation: 0, switchOn: switchOn,
                             exportDPI: 300, fillColor: .black, read: read, source: .switchPolicy)
        // Each named box's start, as the rule gives it on the real plan's own
        // boxes. The four the rows name start by clause 1, not by the model's
        // (2, 2, 2, 4): the real plan joins nothing to a box without
        // characters, so each stands alone in its plan box and has no
        // neighbour (rule 1). The reason is held as assertions: the
        // characterless boxes above, and each box alone below.
        for expected in table.expected {
            let matching = regions.filter { Self.readBack($0.normalizedRect, table.page) == expected.rect.r64 }
            try #require(!matching.isEmpty, "a region at \(expected.rect.r64)")
            for region in matching {
                let start = try #require(plan.firstEditStart(for: region.id), "\(expected.rect.r64)")
                #expect(start.clause == expected.clause, "\(expected.rect.r64): clause \(start.clause)")
                let box = try #require(plan.boxes.first { $0.regionIDs.contains(region.id) })
                #expect((box.regionIDs.count == 1) == (expected.clause == 1), "\(expected.rect.r64): alone")
            }
        }
        // Every found box has a start: each was read from the text layer.
        #expect(regions.allSatisfy { plan.firstEditStart(for: $0.id) != nil })
    }
}

/// mulberry32, as the round trip's model draws its sides: the same 32-bit
/// steps, so the same sides from the same seed.
private struct Mulberry32 {
    var state: UInt32
    init(seed: UInt32) { state = seed }
    mutating func next() -> Double {
        state = state &+ 0x6D2B_79F5
        var t = (state ^ (state >> 15)) &* (state | 1)
        t = (t &+ ((t ^ (t >> 7)) &* (t | 61))) ^ t
        return Double(t ^ (t >> 14)) / 4_294_967_296
    }
}
