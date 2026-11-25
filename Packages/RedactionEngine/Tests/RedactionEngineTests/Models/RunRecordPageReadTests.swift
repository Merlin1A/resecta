import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import RedactionCore
@testable import RedactionEngine

/// A page's read: the words, text and facts made once for a page and handed
/// to the record's plan.
@Suite struct RunRecordPageReadTests {

    static func page(_ data: Data) throws -> PDFPage {
        try #require(PDFDocument(data: data)?.page(at: 0))
    }

    static let typed = TestFixtures.textLayerPDF(text: "Roe. Ann Lee-Park", fontSize: 24)

    /// The first page's read, from a document of its own.
    static func read(_ data: Data) async throws -> RunRecord.PageRead {
        let document = SendablePDFDocument(try #require(PDFDocument(data: data)))
        return try #require(await RunRecord.PageRead.reads(of: document, pages: [0], hasHiddenOCG: false)[0])
    }

    @Test("A typed page's read holds its string and the extractor's words, and its print is not a picture")
    func typedPageRead() async throws {
        let read = try await Self.read(Self.typed)
        #expect(read.text == (try Self.page(Self.typed)).string)
        let again = try Self.page(Self.typed)
        let characters = try await TextLayerExtractor().extractCharacters(from: again)
        #expect(read.words == PageWordReader.words(text: read.text, characters: characters))
        #expect(read.words.words.count == 3)
        #expect(read.facts == PageTextFacts(showsInvisibleText: false, carriesPageScaleImage: false))
    }

    @Test("A page whose print is a picture, read through the record's word path, reads that its print is a picture")
    func pictureRead() async throws {
        let read = try await Self.read(TestFixtures.lineOverScanPDF("Account 4417"))
        #expect(read.facts.carriesPageScaleImage)
        #expect(read.facts.showsInvisibleText, "the scan's line is drawn in the invisible mode")
        #expect(!read.words.words.isEmpty)
    }

    /// A Search box over "Ann" and a box over "Lee-Park", on the typed page,
    /// as the record carries them: their kinds and rectangles, no selection.
    static func regions(on page: PDFPage, read: RunRecord.PageRead) throws -> [RunRecord.DrawnRegion] {
        let side = page.bounds(for: .cropBox)
        return try [1, 2].map { i in
            let box = try #require(read.words.words[i].box)
            let rect = CGRect(x: box.minX / Double(side.width), y: box.minY / Double(side.height),
                              width: (box.maxX - box.minX) / Double(side.width),
                              height: (box.maxY - box.minY) / Double(side.height))
            return RunRecord.DrawnRegion(id: UUID(), normalizedRect: rect, kind: .placedFromTextAnchored)
        }
    }

    @Test("Through the record, a page's plan with its read equals the plan with none, while its regions carry no selection",
          arguments: [PlanSource.asPlaced, .switchPolicy], [false, true])
    func readIsInertWithoutSelection(source: PlanSource, switchOn: Bool) async throws {
        let read = try await Self.read(Self.typed)
        let page = try Self.page(Self.typed)
        let regions = try Self.regions(on: page, read: read)
        let side = page.bounds(for: .cropBox).size
        func made(_ read: RunRecord.PageRead?) -> RunRecord.Page {
            RunRecord.Page(pageIndex: 0, regions: regions, cropBox: side, rotation: 0, switchOn: switchOn,
                           read: read, source: source)
        }
        let with = made(read), without = made(nil)
        #expect(with.plan != nil)
        #expect(with == without)
    }

    @Test("The run's own page init passes its read to the plan maker under the run's plan source")
    func publicInitTakesTheRead() async throws {
        let read = try await Self.read(Self.typed)
        let page = try Self.page(Self.typed)
        let regions = try Self.regions(on: page, read: read)
        let side = page.bounds(for: .cropBox).size
        let run = RunRecord.Page(pageIndex: 0, regions: regions, cropBox: side, rotation: 0, switchOn: true, read: read)
        let named = RunRecord.Page(pageIndex: 0, regions: regions, cropBox: side, rotation: 0, switchOn: true,
                                   read: read, source: RunRecord.planSource)
        #expect(run == named)
    }

    @Test("Through the record, a Search box that carries its match's characters, on a read page, is widened by the switch; with no read it could not be")
    func switchWidensACarriedSelection() async throws {
        let document = try MatchCharactersTests.document(MatchCharactersTests.paragraph)
        let found = try await MatchCharactersTests.results(.text("Quentin Ashby", options: SearchOptions()), in: document)
        let region = RunRecord.DrawnRegion(region: RedactionRegion(placing: try #require(found.first)))
        #expect(region.kind == .placedFromTextAnchored && region.pageCharacters != nil)
        // The page read from a document of its own, drawn the same way.
        let other = SendablePDFDocument(try MatchCharactersTests.document(MatchCharactersTests.paragraph))
        let read = try #require(await RunRecord.PageRead.reads(of: other, pages: [0], hasHiddenOCG: false)[0])
        let side = CGSize(width: 612, height: 792)
        func box(_ read: RunRecord.PageRead?) throws -> PaintedBox {
            let page = RunRecord.Page(pageIndex: 0, regions: [region], cropBox: side, rotation: 0, switchOn: true,
                                      read: read, source: .switchPolicy)
            return try #require(page.plan?.boxes.first)
        }
        let widened = try box(read)
        #expect(widened.treatment == .widened, "\(widened.treatment)")
        #expect(widened.paint.width > widened.tight.width, "the paint reaches past the match's own letters")
        let unread = try box(nil)
        if case .couldNotWiden = unread.treatment {} else { Issue.record("no read: \(unread.treatment)") }
    }

    @Test("Through the record, with the selection carried, the page's words keep two Search boxes apart: a word between them stays two boxes; next to each other they join")
    func wordsKeepTwoBoxesApart() async throws {
        let document = try MatchCharactersTests.document(MatchCharactersTests.paragraph)
        let other = SendablePDFDocument(try MatchCharactersTests.document(MatchCharactersTests.paragraph))
        let read = try #require(await RunRecord.PageRead.reads(of: other, pages: [0], hasHiddenOCG: false)[0])
        func region(_ term: String) async throws -> RunRecord.DrawnRegion {
            let found = try await MatchCharactersTests.results(.text(term, options: SearchOptions()), in: document)
            return RunRecord.DrawnRegion(region: RedactionRegion(placing: try #require(found.first)))
        }
        func plan(_ regions: [RunRecord.DrawnRegion]) throws -> PaintPlan {
            try #require(RunRecord.Page(pageIndex: 0, regions: regions, cropBox: CGSize(width: 612, height: 792),
                                        rotation: 0, switchOn: false, read: read, source: .switchPolicy).plan)
        }
        let quentin = try await region("Quentin"), ashby = try await region("Ashby"), opened = try await region("opened")
        let joined = try plan([quentin, ashby])
        #expect(joined.boxes.map(\.regionIDs) == [[quentin.id, ashby.id]], "next to each other: one box")
        let apart = try plan([quentin, opened])
        #expect(apart.boxes.count == 2, "a word between them: two boxes")
        let at = try #require(read.text.range(of: "Ashby opened")).lowerBound
        let offset = read.text.utf16.distance(from: read.text.utf16.startIndex, to: at)
        let between = try #require(read.words.words.first { $0.letters.contains(offset) }?.box)
        let word = PageRect64(minX: Int((between.minX * 64).rounded()), minY: Int((between.minY * 64).rounded()),
                              maxX: Int((between.maxX * 64).rounded()), maxY: Int((between.maxY * 64).rounded()))
        #expect(apart.boxes.allSatisfy { !$0.paint.sharesArea(with: word) }, "no paint over the word between")
    }

    /// The engine's sources, every Swift file.
    static func sources() throws -> [(name: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        return try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    /// Each `facts: .noPageRead` site with the source just before it.
    static func noReadSites(_ text: String) -> [String] {
        var out: [String] = []
        var rest = text[...]
        while let r = rest.range(of: "facts: .noPageRead") {
            let start = text.index(r.lowerBound, offsetBy: -160, limitedBy: text.startIndex) ?? text.startIndex
            out.append(String(text[start..<r.upperBound]))
            rest = text[r.upperBound...]
        }
        return out
    }

    /// Whether a no-read site hands the plan the empty page's words.
    static func besideNoWords(_ site: String) -> Bool { site.contains("words: PageWords(words: [])") }

    @Test("The no-read facts sit only beside the empty page, and a read is made in one place")
    func noReadOnlyBesideNoWords() throws {
        let files = try Self.sources()
        #expect(files.count > 100, "the scan reads the engine's sources (\(files.count) files)")
        var sites = 0
        for (name, text) in files {
            for site in Self.noReadSites(text) {
                sites += 1
                #expect(Self.besideNoWords(site), "\(name): \(site)")
            }
            let made = text.components(separatedBy: "PageRead(").count - 1
            if name == "RunRecord+PageRead.swift" {
                #expect(made == 1, "the read is made once, in its maker")
            } else {
                #expect(made == 0, "\(name) makes a page read")
            }
        }
        #expect(sites >= 1, "the record's page passes the no-read facts when it has no read")
        // While no region carries its selection a plan with a read equals one
        // without, so the read reaching the plan is pinned in the source.
        let record = try #require(files.first { $0.name == "RunRecord.swift" }).text
        #expect(record.contains("words: read.words, text: read.text, facts: read.facts,"),
                "the record's page hands the plan its read's words, text and facts")
        let planted = "plan = PaintPlan.make(\n regions: r, words: read.words, text: read.text,\n facts: .noPageRead,"
        #expect(Self.noReadSites(planted).count == 1 && !Self.noReadSites(planted).contains(where: Self.besideNoWords),
                "a no-read beside read words is caught")
    }
}
