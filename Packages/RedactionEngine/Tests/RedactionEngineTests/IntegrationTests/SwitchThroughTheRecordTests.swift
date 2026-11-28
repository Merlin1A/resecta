import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import RedactionCore
@testable import RedactionEngine

// Boxes placed by Search and by Scan on a typed page, carried by the run's
// record as the run makes it: each region keeps the characters its match
// selected, the page's words are read once, and the plan is made under the
// switch's policy. The ink check reads its inputs from that plan.

@Suite("The switch through the run's record")
struct SwitchThroughTheRecordTests {
    typealias M = MatchCharactersTests

    static let lines = M.paragraph + ["", "Account holder: Mara Lindqvist"]

    struct Made {
        let confirmed: RunRecord.Page
        let result: RasterizeResult
    }

    /// The regions Search and Scan place for `terms` and e-mail addresses,
    /// carried through the record with the page's read, under `source`.
    static func run(source: PlanSource, switchOn: Bool, terms: [String]) async throws -> Made {
        let document = try M.document(Self.lines)
        let data = try #require(document.dataRepresentation())
        let reopened = try #require(PDFDocument(data: data))
        defer { withExtendedLifetime(reopened) {} }
        let page = try #require(reopened.page(at: 0))
        var found: [SearchResult] = []
        for term in terms { found += try await M.results(.text(term, options: SearchOptions()), in: reopened) }
        found += try await M.results(.piiScan(categories: [.email], options: SearchOptions()), in: reopened)
        let regions = found.map { RedactionRegion(placing: $0) }
        let read = try await RunRecordPageReadTests.read(data)
        let confirmed = RunRecord.Page(pageIndex: 0, regions: regions.map(RunRecord.DrawnRegion.init(region:)),
                                       cropBox: page.bounds(for: .cropBox).size, rotation: page.rotation,
                                       switchOn: switchOn, read: read, source: source)
        var pageData = PDFPageData(
            page: page, pageIndex: 0, regions: regions, fillColor: .black, targetDPI: 300,
            pipelineMode: .secureRasterization, rotation: page.rotation,
            cropBoxBounds: page.bounds(for: .cropBox), cgPage: page.pageRef,
            hasText: page.string?.isEmpty == false, confirmedPage: confirmed)
        pageData.planSource = source
        return Made(confirmed: confirmed, result: try await PageRasterizer().rasterize(pageData, dpiCap: 300))
    }

    @Test("At the switch a Search box and a Scan box, each carrying its characters, are judged by the ink check, not left undecided",
          arguments: [false, true])
    func searchAndScanBoxesAreJudged(switchOn: Bool) async throws {
        let made = try await Self.run(source: .switchPolicy, switchOn: switchOn, terms: ["Quentin Ashby"])
        let plan = try #require(made.confirmed.plan)
        #expect(plan.boxes.count == 2)
        for (index, box) in plan.boxes.enumerated() {
            #expect(box.inkCheckable, "box \(index)")
            let inputs = try #require(made.confirmed.inkCheckInputs[index])
            #expect(inputs.lineHeight > 0)
            #expect(!inputs.others.isEmpty)
            let verdict = try #require(made.result.inkVerdicts[index])
            #expect(verdict != .indeterminate, "box \(index)")
        }
    }

    @Test("The editor's kept plan, made with the page's read and the switch, is the record's plan", arguments: [false, true])
    func keptPlanIsTheRecordsPlan(switchOn: Bool) async throws {
        let document = try M.document(Self.lines)
        let data = try #require(document.dataRepresentation())
        let reopened = try #require(PDFDocument(data: data))
        defer { withExtendedLifetime(reopened) {} }
        let page = try #require(reopened.page(at: 0))
        let found = try await M.results(.text("Mara Lindqvist", options: SearchOptions()), in: reopened)
        let regions = found.map { RedactionRegion(placing: $0) }
        let read = try await RunRecordPageReadTests.read(data)
        let cropBox = page.bounds(for: .cropBox).size
        let record = RunRecord.Page(pageIndex: 0, regions: regions.map(RunRecord.DrawnRegion.init(region:)),
                                    cropBox: cropBox, rotation: page.rotation, switchOn: switchOn, read: read)
        let kept = DrawnPlan(pageIndex: 0, regions: regions, cropBox: cropBox, rotation: page.rotation,
                             switchOn: switchOn, exportDPI: 300, fillColor: .black, read: read)
        #expect(kept.plan == record.plan)
        let wordless = DrawnPlan(pageIndex: 0, regions: regions, cropBox: cropBox, rotation: page.rotation,
                                 switchOn: switchOn, exportDPI: 300, fillColor: .black)
        #expect(wordless.plan != record.plan, "the read changes the plan, so the case means something")
    }

    @Test("Under \"as placed\" the record carries no ink-check inputs and nothing is judged")
    func asPlacedCarriesNoInputs() async throws {
        let made = try await Self.run(source: .asPlaced, switchOn: true, terms: ["Quentin Ashby"])
        #expect(made.confirmed.inkCheckInputs.isEmpty)
        #expect(made.result.inkVerdicts.isEmpty)
    }

    @Test("With its characters carried, the switch widens an anchored Search box in the paragraph's column through the run; with the switch off it is not widened")
    func switchWidensAnAnchoredBoxInTheColumnThroughTheRecord() async throws {
        let on = try await Self.run(source: .switchPolicy, switchOn: true, terms: ["Quentin Ashby"])
        let off = try await Self.run(source: .switchPolicy, switchOn: false, terms: ["Quentin Ashby"])
        /// The box that holds the Search region (the first region; Scan's follow).
        func searchBox(_ made: Made) throws -> PaintedBox {
            let id = try #require(made.confirmed.regions.first).id
            return try #require(made.confirmed.plan?.boxes.first { $0.regionIDs.contains(id) })
        }
        let onBox = try searchBox(on), offBox = try searchBox(off)
        #expect(onBox.treatment == .widened, "\(onBox.treatment)")
        #expect(offBox.treatment != .widened, "\(offBox.treatment)")
        #expect(onBox.paint.contains(offBox.paint))
    }

    @Test("The run entry's page, made from the page's geometry, carries the ink check's inputs and the default band's fallbacks as the page made from its crop box does",
          arguments: [false, true])
    func runEntryPageCarriesTheInkChecksInputs(switchOn: Bool) async throws {
        let document = try M.document(Self.lines)
        let data = try #require(document.dataRepresentation())
        let reopened = try #require(PDFDocument(data: data))
        defer { withExtendedLifetime(reopened) {} }
        let page = try #require(reopened.page(at: 0))
        var found = try await M.results(.text("Quentin Ashby", options: SearchOptions()), in: reopened)
        found += try await M.results(.text("Mara Lindqvist", options: SearchOptions()), in: reopened)
        let drawn = found.map { RunRecord.DrawnRegion(region: RedactionRegion(placing: $0)) }
        let read = try await RunRecordPageReadTests.read(data)
        let geometry = RunRecord.PageGeometry(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
        let atEntry = RunRecord.Page(pageIndex: 0, regions: drawn, geometry: geometry, geometryAtStore: geometry,
                                     switchOn: switchOn, read: read)
        let fromCropBox = RunRecord.Page(pageIndex: 0, regions: drawn, cropBox: geometry.cropBox.size,
                                         rotation: geometry.rotation, switchOn: switchOn, read: read)
        #expect(!fromCropBox.inkCheckInputs.isEmpty, "the page has inputs to carry, so the case means something")
        #expect(atEntry.plan == fromCropBox.plan)
        #expect(atEntry.inkCheckInputs == fromCropBox.inkCheckInputs)
        // The record's plan is made with the page's drawing not read, so no
        // default band is taken and no fallback made yet: equal, and empty.
        #expect(atEntry.defaultFallbacks == fromCropBox.defaultFallbacks)
    }
}
