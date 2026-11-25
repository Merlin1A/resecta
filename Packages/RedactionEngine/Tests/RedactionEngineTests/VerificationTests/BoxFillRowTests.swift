import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import RedactionEngine

// The Box Fill row: the box check's report and the run's record, read as
// today's row. The table holds the mapping's seven cells; the cases after it
// hold the containment test, the regions painted outside the plan, the
// sentences' forms, a box the report leaves out, and one export through the
// engine.

@Suite("The box check's result reads as the Box Fill row")
struct BoxFillRowTests {
    /// A square page 2 inches on a side, in sixty-fourths.
    static let side = 9216

    static func share(_ minX: CGFloat, _ minY: CGFloat, _ maxX: CGFloat, _ maxY: CGFloat) -> RunRecord.DrawnRegion {
        RunRecord.DrawnRegion(id: UUID(), normalizedRect: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
    }

    /// A page of the record whose plan holds one box per admitted region, as placed (the plan main makes at run entry).
    static func page(_ index: Int, _ regions: [RunRecord.DrawnRegion], boxes: [PaintedBox]? = nil) -> RunRecord.Page {
        let placed = PaintPlan.asPlaced(
            regions: regions.filter { RedactionRegion.isAdmitted(normalizedRect: $0.normalizedRect) }.map {
                ($0.id, PointRect(minX: Double($0.normalizedRect.minX), minY: Double($0.normalizedRect.minY),
                                  maxX: Double($0.normalizedRect.maxX), maxY: Double($0.normalizedRect.maxY)))
            },
            widthSixtyFourths: side, heightSixtyFourths: side)
        let plan = boxes.map { PaintPlan(widthSixtyFourths: side, heightSixtyFourths: side, boxes: $0) } ?? placed
        return RunRecord.Page(pageIndex: index, regions: regions, plan: plan)
    }

    static func record(_ pages: [RunRecord.Page], paintedOutsideThePlan: [Int: Set<UUID>] = [:]) -> RunRecord {
        var produced = RunRecord.Produced()
        produced.regionsPaintedOutsideThePlan = paintedOutsideThePlan
        return RunRecord(confirmed: .init(fillColor: .black, exportDPI: 300, pages: pages), produced: produced)
    }

    static let done = BoxOutcome.completed(BoxCounts(), .none)
    static let found = BoxOutcome.issue(BoxCounts(), [BoxWrongBlock(component: 0, column: 1, row: 1)])
    static let unjudged = BoxOutcome.inconclusive(ExactFillCheck.reportDoesNotHoldThePaint, BoxCounts())

    static func read(_ boxes: [BoxOutcome]) -> BoxCheckPage {
        BoxCheckPage(picture: .completed, quality: 300, belowChosen: false, noColour: true, boxes: boxes)
    }

    static func unread(_ boxCount: Int) -> BoxCheckPage {
        BoxCheckPage(picture: .fault(.unreadableInput), quality: nil, belowChosen: false, noColour: false,
                     boxes: Array(repeating: .couldNotFinish(.unreadableInput, nil), count: boxCount))
    }

    /// Ten pages of one region each; page 4 also holds a region wholly off the left, which no box covers.
    static let tenPages: RunRecord = record((0..<10).map { i in
        page(i, [share(0.1, 0.1, 0.3, 0.2)] + (i == 3 ? [share(-0.4, 0.1, -0.1, 0.2)] : []))
    })

    /// Every page read and its box exact; page 4's second box, made for the region off the left as drawn, is off its page.
    static func allRead(except changes: [Int: BoxCheckPage]) -> BoxCheckReport {
        .pages((0..<10).map { changes[$0] ?? read($0 == 3 ? [done, .offPage] : [done]) })
    }

    struct Cell: Sendable, CustomTestStringConvertible {
        let name: String
        let report: BoxCheckReport
        let hasRecord: Bool
        let expected: BoxFillRow.Reading
        var testDescription: String { name }
    }

    static let cells: [Cell] = [
        Cell(name: "every box exact (a region wholly off the left needs no box): Passed",
             report: allRead(except: [:]), hasRecord: true, expected: .row(.passed, nil)),
        Cell(name: "a box on page 4 not the fill: Needs Review, the new-check line under it",
             report: allRead(except: [3: read([found, .offPage])]), hasRecord: true,
             expected: .row(CheckRow(status: .attention("A box on page 4 is not exactly the fill"), pages: [3], couldNotVerify: false),
                            LayerCopy(short: "A box on page 4 is not exactly the fill", detail: BoxFillRow.newCheckLine))),
        Cell(name: "page 4's picture unread, no issue: Could not verify, the page's sentence",
             report: allRead(except: [3: unread(2)]), hasRecord: true,
             expected: .row(CheckRow(status: .warn("Page 4 could not be read for this check"), pages: [3], couldNotVerify: true), nil)),
        Cell(name: "a box on page 4 not judged, no issue: Could not verify, the box's sentence",
             report: allRead(except: [3: read([unjudged, .offPage])]), hasRecord: true,
             expected: .row(CheckRow(status: .warn("A box on page 4 could not be checked"), pages: [3], couldNotVerify: true), nil)),
        Cell(name: "page 9 unread and a box on page 4 not judged: both, the page's sentence first",
             report: allRead(except: [3: read([unjudged, .offPage]), 8: unread(1)]), hasRecord: true,
             expected: .row(CheckRow(status: .warn("Page 9 could not be read for this check; A box on page 4 could not be checked"),
                                     pages: [3, 8], couldNotVerify: true), nil)),
        Cell(name: "no record of the run: Skipped", report: .noRecord, hasRecord: false, expected: .skipped),
        Cell(name: "an issue on page 4 and page 9 unread: Needs Review with the could-not-verify part beside it",
             report: allRead(except: [3: read([found, .offPage]), 8: unread(1)]), hasRecord: true,
             expected: .row(CheckRow(status: .attention("A box on page 4 is not exactly the fill"), pages: [3], couldNotVerify: false,
                                     partSentence: "Page 9 could not be read for this check", partPages: [8]),
                            LayerCopy(short: "A box on page 4 is not exactly the fill", detail: BoxFillRow.newCheckLine))),
    ]

    @Test("The mapping has seven cells")
    func cellCount() {
        #expect(Self.cells.count == 7)
    }

    @Test("Each cell of the mapping", arguments: BoxFillRowTests.cells)
    func each(_ cell: Cell) {
        let reading = BoxFillRow.reading(report: cell.report, record: cell.hasRecord ? Self.tenPages : nil)
        #expect(reading == cell.expected)
        if case .row(let row, let copy) = reading, case .row(let want, _) = cell.expected {
            // Status equality ignores the sentence; the sentence is held here.
            #expect(Self.sentence(row.status) == Self.sentence(want.status))
            #expect(copy?.detail == (want.status.isAttention ? BoxFillRow.newCheckLine : nil))
        }
    }

    static func sentence(_ s: VerificationStatus) -> String? {
        switch s {
        case .warn(let m), .attention(let m), .info(let m), .fail(let m), .notApplicable(let m): m
        case .pass, .skipped: nil
        }
    }

    /// The row's sentence: `==` on a status compares its case only, so a
    /// test that names the sentence holds it through this as well.
    static func rowSentence(_ r: BoxFillRow.Reading) -> String? {
        if case .row(let row, _) = r { sentence(row.status) } else { nil }
    }

    @Test("An issue is never an ordinary warning, a could-not-finish never Passed, no record never Nothing to check")
    func neverMapped() {
        for cell in Self.cells {
            let reading = BoxFillRow.reading(report: cell.report, record: cell.hasRecord ? Self.tenPages : nil)
            guard case .row(let row, _) = reading else { #expect(cell.report == .noRecord); continue }
            #expect(!row.status.isFail, "a check's own refusal never reads as a failed file")
            #expect(!row.status.isNotApplicable)
            if row.status.isWarn { #expect(row.couldNotVerify, "every warning of this row says the check could not finish") }
        }
    }

    // MARK: - containment (each region inside the inner of a box that names it)

    @Test("Duplicate and nested regions, each with its own box, are covered")
    func duplicateAndNested() {
        let a = Self.share(0.1, 0.1, 0.5, 0.3)
        let copy = RunRecord.DrawnRegion(id: UUID(), normalizedRect: a.normalizedRect)
        let inside = Self.share(0.2, 0.15, 0.3, 0.25)
        let page = Self.page(0, [a, copy, inside])
        #expect(page.plan?.boxes.count == 3)
        for region in page.regions { #expect(BoxFillRow.isCovered(region, on: page)) }
        let reading = BoxFillRow.reading(report: .pages([Self.read([Self.done, Self.done, Self.done])]), record: Self.record([page]))
        #expect(reading == .row(.passed, nil))
    }

    @Test("A region no box names, and a region whose naming box does not hold it, could not be checked")
    func notCovered() throws {
        let named = Self.share(0.1, 0.1, 0.3, 0.2)
        let orphan = Self.share(0.6, 0.6, 0.8, 0.7)
        let narrow = Self.share(0.1, 0.5, 0.4, 0.6)
        let boxes = try #require(Self.page(0, [named, narrow]).plan?.boxes)
        // The box that names `narrow` holds only its left half.
        var short = boxes[1]
        short.inner.maxX = short.inner.minX + (short.inner.maxX - short.inner.minX) / 2
        let page = Self.page(0, [named, orphan, narrow], boxes: [boxes[0], short])
        #expect(BoxFillRow.isCovered(named, on: page))
        #expect(!BoxFillRow.isCovered(orphan, on: page))
        #expect(!BoxFillRow.isCovered(narrow, on: page))
        let reading = BoxFillRow.reading(report: .pages([Self.read([Self.done, Self.done])]), record: Self.record([page]))
        #expect(reading == .row(CheckRow(status: .warn("2 boxes on page 1 could not be checked"), pages: [0], couldNotVerify: true), nil))
        #expect(Self.rowSentence(reading) == "2 boxes on page 1 could not be checked")
        if case .row(let row, _) = reading { #expect(Self.sentence(row.status) == "2 boxes on page 1 could not be checked") }
    }

    @Test("A region painted outside the plan, named by the row's containment test and by the producer alike, could not be checked, and is counted once")
    func paintedOutsideThePlan() throws {
        let named = Self.share(0.1, 0.1, 0.3, 0.2)
        let stray = Self.share(0.6, 0.6, 0.8, 0.7)
        let boxes = try #require(Self.page(0, [named]).plan?.boxes)
        let page = Self.page(0, [named, stray], boxes: boxes)
        let record = Self.record([page], paintedOutsideThePlan: [0: [stray.id]])
        // The two sets agree: the containment test leaves out the one region the producer names.
        #expect(Set(page.regions.filter { !BoxFillRow.isCovered($0, on: page) }.map(\.id)) == [stray.id])
        let input = try #require(BoxCheckInput(record: record))
        #expect(input.pages[0].outsidePlan == [stray.id])
        var picture = Self.read([Self.done])
        picture.outsidePlan = input.pages[0].outsidePlan
        let reading = BoxFillRow.reading(report: .pages([picture]), record: record)
        #expect(reading == .row(CheckRow(status: .warn("A box on page 1 could not be checked"), pages: [0], couldNotVerify: true), nil))
        #expect(Self.rowSentence(reading) == "A box on page 1 could not be checked")
    }

    @Test("A region the producer reports painted outside the plan could not be checked, even where a box of the plan names and holds it")
    func producerAloneNamesIt() throws {
        let named = Self.share(0.1, 0.1, 0.3, 0.2)
        let page = Self.page(0, [named])
        let record = Self.record([page], paintedOutsideThePlan: [0: [named.id]])
        #expect(BoxFillRow.isCovered(named, on: page))
        var picture = Self.read([Self.done])
        picture.outsidePlan = try #require(BoxCheckInput(record: record)).pages[0].outsidePlan
        let reading = BoxFillRow.reading(report: .pages([picture]), record: record)
        #expect(reading == .row(CheckRow(status: .warn("A box on page 1 could not be checked"), pages: [0], couldNotVerify: true), nil))
        #expect(Self.rowSentence(reading) == "A box on page 1 could not be checked")
    }

    @Test("Wholly off its page is the region as drawn sharing no area with the page; one past the left edge by a hair is on it")
    func offPageIsTheAdaptersOwnTest() {
        let off = Self.share(-0.3, 0.1, 0.0, 0.2)
        let touching = Self.share(-0.3, 0.1, 0.01, 0.2)
        let page = Self.page(0, [off, touching], boxes: [])
        #expect(BoxFillRow.isCovered(off, on: page))
        #expect(!BoxFillRow.isCovered(touching, on: page))
    }

    @Test("A box of the record the report leaves out could not be checked, never passed")
    func boxLeftOut() {
        let page = Self.page(0, [Self.share(0.1, 0.1, 0.3, 0.2), Self.share(0.5, 0.5, 0.7, 0.6)])
        let reading = BoxFillRow.reading(report: .pages([Self.read([Self.done])]), record: Self.record([page]))
        #expect(reading == .row(CheckRow(status: .warn("A box on page 1 could not be checked"), pages: [0], couldNotVerify: true), nil))
        #expect(Self.rowSentence(reading) == "A box on page 1 could not be checked")
    }

    @Test("A record the check could not take reads Could not verify on every page, never Skipped; a file page the record lacks is unread")
    func recordTheCheckCouldNotTake() {
        let outOfOrder = Self.record([Self.page(1, [Self.share(0.1, 0.1, 0.3, 0.2)]), Self.page(0, [Self.share(0.1, 0.1, 0.3, 0.2)])])
        #expect(BoxCheckInput(record: outOfOrder) == nil)
        let reading = BoxFillRow.reading(report: .noRecord, record: outOfOrder)
        #expect(reading == .row(CheckRow(status: .warn("2 pages could not be read for this check: 1, 2"), pages: [0, 1], couldNotVerify: true), nil))
        #expect(Self.rowSentence(reading) == "2 pages could not be read for this check: 1, 2")
        if case .row(let row, _) = reading { #expect(Self.sentence(row.status) == "2 pages could not be read for this check: 1, 2") }
        // Page numbers checked on every page, not the first alone: a repeated number and a gap.
        let repeated = Self.record([Self.page(0, [Self.share(0.1, 0.1, 0.3, 0.2)]), Self.page(0, [Self.share(0.1, 0.1, 0.3, 0.2)])])
        let gap = Self.record([Self.page(0, [Self.share(0.1, 0.1, 0.3, 0.2)]), Self.page(2, [Self.share(0.1, 0.1, 0.3, 0.2)])])
        #expect(BoxCheckInput(record: repeated) == nil)
        #expect(BoxCheckInput(record: gap) == nil)
        #expect(BoxFillRow.reading(report: .noRecord, record: gap)
                == .row(CheckRow(status: .warn("2 pages could not be read for this check: 1, 3"), pages: [0, 2], couldNotVerify: true), nil))
        #expect(Self.rowSentence(BoxFillRow.reading(report: .noRecord, record: gap)) == "2 pages could not be read for this check: 1, 3")
        let one = Self.record([Self.page(0, [Self.share(0.1, 0.1, 0.3, 0.2)])])
        let outside = BoxCheckPage(picture: .fault(.wrongSubject), quality: nil, belowChosen: false, noColour: false, boxes: [])
        let extra = BoxFillRow.reading(report: .pages([Self.read([Self.done]), outside]), record: one)
        #expect(extra == .row(CheckRow(status: .warn("Page 2 could not be read for this check"), pages: [1], couldNotVerify: true), nil))
        #expect(Self.rowSentence(extra) == "Page 2 could not be read for this check")
    }

    @Test("The sentences' forms: one box, boxes on one page, two pages, three pages")
    func forms() {
        #expect(BoxFillRow.findSentence([3]) == "A box on page 4 is not exactly the fill")
        #expect(BoxFillRow.findSentence([3, 3, 8]) == "3 boxes on pages 4 and 9 are not exactly the fill")
        #expect(BoxFillRow.notCheckedSentence([3]) == "A box on page 4 could not be checked")
        #expect(BoxFillRow.notCheckedSentence([3, 8, 8]) == "3 boxes on pages 4 and 9 could not be checked")
        #expect(BoxFillRow.notCheckedSentence([0, 0]) == "2 boxes on page 1 could not be checked")
        #expect(BoxFillRow.findSentence([0, 3, 8]) == "3 boxes on pages 1, 4, and 9 are not exactly the fill")
    }

    // MARK: - the check's place, and one export through the engine

    @Test("Box Fill is declared last, numbered eighth in Secure and fourteenth in Searchable, and runs with the catalog readers")
    func place() {
        let engine = VerificationEngine()
        #expect(VerificationLayer.allCases.last == .boxFill)
        #expect(engine.layers(for: .secureRasterization).count == 8)
        #expect(engine.layers(for: .searchableRedaction).count == 14)
        #expect(engine.layers(for: .secureRasterization).last == .boxFill)
        #expect(engine.layers(for: .searchableRedaction).last == .boxFill)
        #expect(VerificationLayer.boxFill.phase == .catalogSequential)
        #expect(VerificationLayer.boxFill.name == "Box Fill")
    }

    /// One page with one box over print that was never painted, its record made by hand.
    static func unpaintedExport() async throws -> (PDFDocument, RunRecord) {
        let (b, p) = BoxCheckTests.boxAt(PixelPaintRule.Lines(left: 100, top: 100, right: 220, bottom: 140), dpi: 300, width: 600, height: 600)
        let (_, jpeg) = BoxCheckFixtures.walk(BoxCheckFixtures.picture(width: 600, height: 600, print: true, marks: []))
        let file = try await PageImageFixtures.export([jpeg], size: CGSize(width: 144, height: 144))
        let doc = try #require(PDFDocument(data: file))
        // The region as drawn, a sixty-fourth inside the box's inner on every side.
        let i = b.inner, s = CGFloat(side)
        let region = RunRecord.DrawnRegion(id: try #require(b.regionIDs.first), normalizedRect: CGRect(
            x: CGFloat(i.minX + 1) / s, y: CGFloat(i.minY + 1) / s,
            width: CGFloat(i.maxX - i.minX - 2) / s, height: CGFloat(i.maxY - i.minY - 2) / s))
        let record = RunRecord(
            confirmed: .init(fillColor: .black, exportDPI: 300, pages: [
                RunRecord.Page(pageIndex: 0, regions: [region],
                               plan: PaintPlan(widthSixtyFourths: side, heightSixtyFourths: side, boxes: [b])),
            ]),
            produced: .init(pageImageDigests: [0: PageImageFixtures.sha256(jpeg)],
                            paintedRectangles: [.init(pageIndex: 0, box: 0): BoxCheckFixtures.report(p, height: 600)],
                            infoDictionary: nil))
        return (doc, record)
    }

    @Test("An export with its box never painted, through the engine: the row reads Needs Review on page 1; with no record, Skipped")
    func throughTheEngine() async throws {
        let (doc, record) = try await Self.unpaintedExport()
        let engine = VerificationEngine()
        func run(_ record: RunRecord?) async -> LayerResult {
            await engine.runLayer(.boxFill, outputDocument: SendablePDFDocument(doc), sourcePageCount: 1, regions: [:],
                                  sensitiveTerms: [], pipelineMode: .secureRasterization, filterDigests: [nil],
                                  perPageModes: [.secureRasterization], record: record)
        }
        let found = await run(record)
        #expect(found.status == .attention(""))
        #expect(found.shortDescription == "A box on page 1 is not exactly the fill")
        #expect(found.detailDescription == BoxFillRow.newCheckLine)
        #expect(found.pageReferences == [0])
        #expect(found.couldNotVerify == false)
        #expect(engine.aggregateStatus([found]) == .attention(""))
        let none = await run(nil)
        #expect(none.status == .skipped)
    }
}
