import CoreGraphics
import Foundation
import Testing
@testable import RedactionEngine

// The plan the run's record keeps at run entry, the second mark on a region,
// and the refusal of a run whose plan holds a box this release cannot apply.
// The plan is made under the one plan source, "as placed": one box per region
// admission lets through, as placed, whatever the region's kind or the user's
// switch. The two marks: "placed from the page's own text", set once, and
// "anchored", which is that and not moved or resized since.

@Suite("The run's kept plan, the region's two marks, and the refusal")
struct RunPlanKeptTests {

    static let letter = CGSize(width: 612, height: 792)

    static func drawn(_ rect: CGRect, _ kind: RegionKind = .drawnByHand) -> RunRecord.DrawnRegion {
        RunRecord.DrawnRegion(id: UUID(), normalizedRect: rect, kind: kind)
    }

    /// The page's record made under "as placed", unless a case names another source.
    static func page(_ regions: [RunRecord.DrawnRegion], index: Int = 0, switchOn: Bool = false,
                     source: PlanSource = .asPlaced) -> RunRecord.Page {
        RunRecord.Page(pageIndex: index, regions: regions, cropBox: letter, rotation: 0, switchOn: switchOn,
                       read: nil, source: source)
    }

    /// The as-placed plan's boxes for the same regions: the admitted ones, each
    /// its rectangle in sixty-fourths, on Letter's sides.
    static func asPlaced(_ regions: [RunRecord.DrawnRegion]) -> PaintPlan {
        PaintPlan.asPlaced(
            regions: regions.filter { RedactionRegion.isAdmitted(normalizedRect: $0.normalizedRect) }.map { r in
                let s = r.normalizedRect
                return (r.id, PointRect(minX: Double(s.minX), minY: Double(s.minY), maxX: Double(s.maxX), maxY: Double(s.maxY)))
            },
            widthSixtyFourths: 612 * 64, heightSixtyFourths: 792 * 64)
    }

    /// One region of each kind, and one of them reaching past the right edge.
    static func everyKind() -> [RunRecord.DrawnRegion] {
        [drawn(CGRect(x: 0.10, y: 0.10, width: 0.20, height: 0.05), .drawnByHand),
         drawn(CGRect(x: 0.10, y: 0.30, width: 0.15, height: 0.02), .placedFromTextAnchored),
         drawn(CGRect(x: 0.40, y: 0.30, width: 0.15, height: 0.02), .placedFromTextThenEdited),
         drawn(CGRect(x: 0.10, y: 0.50, width: 0.25, height: 0.03), .placedFromPicture),
         drawn(CGRect(x: 0.90, y: 0.70, width: 0.20, height: 0.02), .placedFromTextAnchored)]
    }

    static let box = CGRect(x: 0.2, y: 0.5, width: 0.1, height: 0.02)

    static func result(_ source: SearchSource) -> SearchResult {
        SearchResult(pageIndex: 0, normalizedRect: box, matchedText: "Delia", contextSnippet: "Delia Hartwell",
                     source: source, term: "delia", textLayerRect: CGRect(x: 0.21, y: 0.5, width: 0.09, height: 0.02))
    }

    // MARK: - The kept plan

    @Test("The kept plan's boxes are the as-placed plan's boxes, one per region, whatever its kind")
    func keptPlanIsAsPlaced() throws {
        let regions = Self.everyKind()
        let plan = try #require(Self.page(regions).plan)
        #expect(plan == Self.asPlaced(regions))
        #expect(plan.boxes.map(\.regionIDs) == regions.map { [$0.id] })
    }

    @Test("A page with no region keeps an empty plan with its two sides")
    func noRegionEmptyPlan() throws {
        let plan = try #require(Self.page([]).plan)
        #expect(plan.boxes.isEmpty)
        #expect(plan.widthSixtyFourths == 39_168 && plan.heightSixtyFourths == 50_688)
    }

    @Test("Under \"as placed\" the user's switch is not read: switched on, every box is as placed")
    func switchIgnoredAsPlaced() throws {
        let choice = RunRecord.planChoice(source: .asPlaced, switchOn: true)
        #expect(choice.source == .asPlaced && !choice.switchOn)
        let regions = Self.everyKind()
        let on = try #require(Self.page(regions, switchOn: true).plan)
        #expect(on == Self.asPlaced(regions))
        #expect(on.boxes.allSatisfy { !$0.bandMade && $0.treatment == .notAsked })
    }

    @Test("Under the switch's policy, handed in, the user's switch reaches the plan's choice")
    func switchReachesUnderSwitchPolicy() {
        let on = RunRecord.planChoice(source: .switchPolicy, switchOn: true)
        #expect(on.source == .switchPolicy && on.switchOn)
        let off = RunRecord.planChoice(source: .switchPolicy, switchOn: false)
        #expect(off.source == .switchPolicy && !off.switchOn)
    }

    @Test("A region too thin to paint has no box in the kept plan and one row in the refused list")
    func thinRegionRefused() throws {
        let thin = Self.drawn(CGRect(x: 0.2, y: 0.2, width: 0.0005, height: 0.1))
        let kept = Self.drawn(CGRect(x: 0.4, y: 0.2, width: 0.1, height: 0.02))
        let page = Self.page([thin, kept])
        #expect(try #require(page.plan).boxes.map(\.regionIDs) == [[kept.id]])
        #expect(page.refusedRegions.map(\.id) == [thin.id])
        #expect(page.refusedRegions.map(\.reason) == [.tooThinToPaint])
    }

    // MARK: - The refusal

    @Test("The first page whose plan holds a box that cannot show length is found; with none, nil")
    func refusalFindsTheFirstPage() throws {
        let regions = Self.everyKind()
        let good = Self.page(regions, index: 0)
        var plan = try #require(Self.page(regions, index: 1).plan)
        plan.boxes[2].exposure = .hidden
        let hidden = RunRecord.Page(pageIndex: 1, regions: regions, plan: plan)
        plan.boxes[2].exposure = .narrowed
        let narrowed = RunRecord.Page(pageIndex: 2, regions: regions, plan: plan)
        let noPlan = RunRecord.Page(pageIndex: 3, regions: regions)
        func first(_ pages: [RunRecord.Page]) -> Int? {
            RunRecord.Confirmed(fillColor: .black, exportDPI: 300, pages: pages).firstPageWithBoxThatCannotShowLength
        }
        #expect(first([good, hidden, narrowed]) == 1)
        #expect(first([good, narrowed]) == 2)
        #expect(first([good, noPlan]) == nil)
        #expect(first([]) == nil)
    }

    @Test("Every rule of the release gives a box that can show length, so the release never reaches the refusal")
    func releaseCannotReachRefusal() {
        #expect(GeometryPolicy.release.asPlaced.exposure == .canShowLength)
        #expect(!GeometryPolicy.release.rows.isEmpty)
        #expect(GeometryPolicy.release.rows.allSatisfy { $0.rule.exposure == .canShowLength })
    }

    // MARK: - The two marks

    @Test("A text-layer result and an OCR result each get the marks the plan's table expects")
    func makerSetsBothMarks() {
        let text = RedactionRegion(placing: Self.result(.textLayer))
        #expect(text.placedFromPageText && text.textAnchored)
        #expect(text.source == .searchMatch(term: "delia", rationale: nil))
        #expect(text.normalizedRect == Self.box && text.textLayerRect == Self.result(.textLayer).textLayerRect)
        #expect(RegionKind(of: text) == .placedFromTextAnchored)
        let ocr = RedactionRegion(placing: Self.result(.ocr(confidence: 0.9)))
        #expect(!ocr.placedFromPageText && !ocr.textAnchored)
        #expect(RegionKind(of: ocr) == .placedFromPicture)
    }

    /// Each row of the plan's table of kinds.
    enum KindCase: String, CaseIterable, CustomTestStringConvertible {
        case drawnByHand, anchoredFromText, movedAfterPlacedFromText, readFromThePicture, detectedNotFromText
        var testDescription: String { rawValue }
    }

    @Test("Each region's kind, read from its source and its two marks", arguments: KindCase.allCases)
    func kinds(_ c: KindCase) {
        var region: RedactionRegion
        let expected: RegionKind
        switch c {
        case .drawnByHand:
            region = RedactionRegion(id: UUID(), normalizedRect: Self.box, source: .manual)
            expected = .drawnByHand
        case .anchoredFromText:
            region = RedactionRegion(placing: Self.result(.textLayer))
            expected = .placedFromTextAnchored
        case .movedAfterPlacedFromText:
            region = RedactionRegion(placing: Self.result(.textLayer))
            region.textAnchored = false
            expected = .placedFromTextThenEdited
        case .readFromThePicture:
            region = RedactionRegion(placing: Self.result(.ocr(confidence: 0.8)))
            expected = .placedFromPicture
        case .detectedNotFromText:
            region = RedactionRegion(id: UUID(), normalizedRect: Self.box, source: .detectedPII(kind: .ssn))
            expected = .placedFromPicture
        }
        #expect(RegionKind(of: region) == expected)
        #expect(RunRecord.DrawnRegion(region: region).kind == expected)
    }

    @Test("A region not placed from text cannot be set anchored; a moved one is anchored again by its undo")
    func anchoredOnlyWherePlaced() {
        var drawnByHand = RedactionRegion(id: UUID(), normalizedRect: Self.box, source: .manual)
        drawnByHand.textAnchored = true
        #expect(!drawnByHand.textAnchored && !drawnByHand.placedFromPageText)
        var placed = RedactionRegion(placing: Self.result(.textLayer))
        placed.textAnchored = false
        #expect(placed.placedFromPageText && !placed.textAnchored)
        placed.textAnchored = true
        #expect(placed.placedFromPageText && placed.textAnchored)
    }

    @Test("Coding keeps both marks; a region encoded before the new mark takes it from the old; anchored without placed never decodes")
    func marksCoding() throws {
        var moved = RedactionRegion(placing: Self.result(.textLayer))
        moved.textAnchored = false
        let data = try JSONEncoder().encode(moved)
        #expect(try JSONDecoder().decode(RedactionRegion.self, from: data) == moved)

        func decoded(dropping key: String? = nil, setting: [String: Bool] = [:]) throws -> RedactionRegion {
            var object = try #require(JSONSerialization.jsonObject(with: try JSONEncoder().encode(
                RedactionRegion(placing: Self.result(.textLayer)))) as? [String: Any])
            if let key { object.removeValue(forKey: key) }
            for (k, v) in setting { object[k] = v }
            return try JSONDecoder().decode(RedactionRegion.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let old = try decoded(dropping: "placedFromPageText")
        #expect(old.placedFromPageText && old.textAnchored)
        let oldEdited = try decoded(dropping: "placedFromPageText", setting: ["textAnchored": false])
        #expect(!oldEdited.placedFromPageText && !oldEdited.textAnchored)
        let contradictory = try decoded(setting: ["textAnchored": true, "placedFromPageText": false])
        #expect(!contradictory.textAnchored && !contradictory.placedFromPageText)
    }

    @Test("A Search box moved by hand on a page that is not plain does not keep the page's text; unmoved, it does")
    func movedSearchBoxSendsThePageToAPicture() {
        let scan = PageContentFacts(reachesImage: true, drawsInlineImage: false, showsInvisibleText: true, usesType3Font: false)
        var region = RedactionRegion(placing: Self.result(.textLayer))
        #expect(PageContentFacts.keepsTextLayer(regions: [region], facts: { scan }))
        region.textAnchored = false
        #expect(!PageContentFacts.keepsTextLayer(regions: [region], facts: { scan }))
    }
}
