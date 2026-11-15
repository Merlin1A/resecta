import Foundation
import Testing
import RedactionCore

@Suite("A page's text-path rectangles")
struct TextPathRectangleTests {

    /// Built from origin and size alone, as the core reads them.
    static func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
        CGRect(origin: CGPoint(x: x, y: y), size: CGSize(width: width, height: height))
    }

    static let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    static let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    static let c = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!
    static let z = UUID(uuidString: "00000000-0000-0000-0000-00000000000F")!

    /// A region with a hidden letters' rectangle and two ink strips, and a
    /// plain one below it. Every value is a whole or half point, so every
    /// comparison is exact.
    static let regionA = TextPathRegion(
        id: a, rect: rect(100, 700, 80, 12), hiddenLettersRect: rect(98, 699, 84, 14),
        inkStrips: [rect(100, 690, 30, 8), rect(140, 690, 30.5, 8)])
    static let regionB = TextPathRegion(id: b, rect: rect(100, 650, 60, 12))
    static let regionC = TextPathRegion(id: c, rect: rect(300, 650, 40, 12))

    /// A box's inner rectangle in sixty-fourths: 95 to 190 pt across, 698 to
    /// 713.5 pt up.
    static let inner = PageRect64(minX: 6_080, minY: 44_672, maxX: 12_160, maxY: 45_664)
    static let innerPoints = rect(95, 698, 95, 15.5)

    static func box(over ids: Set<UUID>, _ treatment: SwitchTreatment, bandMade: Bool) -> PaintedBox {
        PaintedBox(
            regionIDs: ids, inner: inner, paint: inner, tight: inner,
            limitAbove: nil, limitBelow: nil, exposure: .canShowLength, treatment: treatment,
            bandMade: bandMade, inkEnlargedCovered: false, inkEnlargedToCap: false, asDrawn: false)
    }

    static func ordinary(_ r: CGRect) -> TextPathRectangle { TextPathRectangle(rect: r, kind: .ordinary) }
    static func under(_ r: CGRect) -> TextPathRectangle { TextPathRectangle(rect: r, kind: .underWidenedBox) }
    static let plan = TextPathRectangle(rect: innerPoints, kind: .plansRectangle)

    /// Each region's own rectangle, then its hidden letters' rectangle, then
    /// its ink strips: the list a Searchable export strips under today.
    static let todaysList: [TextPathRectangle] = [
        ordinary(rect(100, 700, 80, 12)), ordinary(rect(98, 699, 84, 14)),
        ordinary(rect(100, 690, 30, 8)), ordinary(rect(140, 690, 30.5, 8)),
        ordinary(rect(100, 650, 60, 12)),
    ]

    /// One case: its regions, and one or more plans that must each give the
    /// same expected list.
    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let regions: [TextPathRegion]
        let runs: [(String, [PaintedBox])]
        let expected: [TextPathRectangle]
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "no boxes",
             regions: [regionA, regionB],
             runs: [("no boxes", [])],
             expected: todaysList),
        Case(name: "a box for which no band was made",
             regions: [regionA, regionB],
             runs: [
                ("as placed", [box(over: [a], .notAsked, bandMade: false)]),
                ("by hand", [box(over: [a], .couldNotWiden(.byHand), bandMade: false)]),
                ("scan or picture", [box(over: [a], .couldNotWiden(.scanOrPicture), bandMade: false)]),
                ("direction", [box(over: [a], .couldNotWiden(.direction), bandMade: false)]),
                ("no usable line", [box(over: [a], .couldNotWiden(.noColumn), bandMade: false)]),
                ("fell back", [box(over: [a], .fellBack, bandMade: false)]),
             ],
             expected: todaysList),
        Case(name: "a box with a band over the region with hidden letters and strips",
             regions: [regionA, regionB],
             runs: [
                ("widened", [box(over: [a], .widened, bandMade: true)]),
                ("already as wide", [box(over: [a], .alreadyAsWide, bandMade: true)]),
                ("could not widen for want of a column", [box(over: [a], .couldNotWiden(.noColumn), bandMade: true)]),
             ],
             expected: [
                plan, under(rect(100, 700, 80, 12)), ordinary(rect(98, 699, 84, 14)),
                ordinary(rect(100, 690, 30, 8)), ordinary(rect(140, 690, 30.5, 8)),
                ordinary(rect(100, 650, 60, 12)),
             ]),
        Case(name: "a box with a band over two regions",
             regions: [regionA, regionB],
             runs: [("over both", [box(over: [a, b], .widened, bandMade: true)])],
             expected: [
                plan, under(rect(100, 700, 80, 12)), ordinary(rect(98, 699, 84, 14)),
                ordinary(rect(100, 690, 30, 8)), ordinary(rect(140, 690, 30.5, 8)),
                under(rect(100, 650, 60, 12)),
             ]),
        Case(name: "a box with a band over one region beside a region no box names",
             regions: [regionC, regionB],
             runs: [("over the first", [box(over: [c], .widened, bandMade: true)])],
             expected: [plan, under(rect(300, 650, 40, 12)), ordinary(rect(100, 650, 60, 12))]),
        Case(name: "a box with a band none of whose regions is listed",
             regions: [regionA, regionB],
             runs: [("over an unlisted region", [box(over: [z], .widened, bandMade: true)])],
             expected: todaysList + [plan]),
    ]

    @Test("The table holds six cases")
    func tableLength() {
        #expect(Self.cases.count == 6)
    }

    @Test("Each region's rectangles, and a banded box's inner rectangle at its first region", arguments: cases)
    func list(_ c: Case) {
        for (run, boxes) in c.runs {
            let got = TextPathRectangle.forPage(regions: c.regions, boxes: boxes)
            #expect(got == c.expected, "\(c.name), \(run): got \(got)")
        }
    }

    /// On a page turned a quarter the caller gives the regions and the plan
    /// in the frame the page is rasterised in, and the function turns
    /// nothing: the inner rectangle comes back as its sixty-fourths divided
    /// by 64, exactly, edges that are not whole points included.
    @Test("On a page turned a quarter the inner rectangle is read in the caller's frame, unturned")
    func quarterTurn() {
        let region = TextPathRegion(id: Self.a, rect: Self.rect(500, 100, 12, 80))
        let turnedInner = PageRect64(minX: 31_999, minY: 6_401, maxX: 32_833, maxY: 11_777)
        let box = PaintedBox(
            regionIDs: [Self.a], inner: turnedInner, paint: turnedInner, tight: turnedInner,
            limitAbove: nil, limitBelow: nil, exposure: .canShowLength, treatment: .widened,
            bandMade: true, inkEnlargedCovered: false, inkEnlargedToCap: false, asDrawn: false)
        let got = TextPathRectangle.forPage(regions: [region], boxes: [box])
        #expect(got == [
            TextPathRectangle(rect: Self.rect(499.984375, 100.015625, 13.03125, 84), kind: .plansRectangle),
            TextPathRectangle(rect: Self.rect(500, 100, 12, 80), kind: .underWidenedBox),
        ])
    }
}
