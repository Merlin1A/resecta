import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import RedactionEngine
import RedactionCore

// A text-layer match keeps the characters it selected on its page's string,
// its region carries them, and the run's maker of the plan's regions selects
// them for a region still anchored to its text, and for no other region.

@Suite("A match's characters reach the plan")
struct MatchCharactersTests {

    /// A one-page Letter document with `lines` in Times 11 pt, 13 pt apart
    /// from y 700.
    static func document(_ lines: [String]) throws -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Times New Roman" as CFString, 11, nil)
        for (i, text) in lines.enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font]))
            context.textPosition = CGPoint(x: 72, y: 700 - CGFloat(i) * 13)
            CTLineDraw(line, context)
        }
        context.endPDFPage()
        context.closePDF()
        return try #require(PDFDocument(data: data as Data))
    }

    static let paragraph = [
        "The statement below was prepared for the holder named in the second line of this notice and for",
        "the office that keeps it: Quentin Ashby opened the account on the date shown and signed every",
        "page of the agreement in the presence of the branch officer, who kept a copy for the records",
        "of the office and sent another to q.ashby@example.com before the end of the following month,",
    ]

    static func results(_ mode: SearchMode, in document: PDFDocument) async throws -> [SearchResult] {
        var found: [SearchResult] = []
        for await result in DocumentSearcher().search(SendablePDFDocument(document), mode: mode, progress: { _, _ in }) {
            found.append(result)
        }
        return found
    }

    static func range(of value: String, in page: PDFPage) throws -> Range<Int> {
        let text = try #require(page.string)
        return try #require(Range((text as NSString).range(of: value)))
    }

    @Test("A typed match keeps its characters on the page's string, and the region placed from it carries them")
    func typedMatchCarriesItsCharacters() async throws {
        let document = try Self.document(Self.paragraph)
        let page = try #require(document.page(at: 0))
        let found = try await Self.results(.text("Quentin Ashby", options: SearchOptions()), in: document)
        #expect(found.count == 1)
        let expected = try Self.range(of: "Quentin Ashby", in: page)
        #expect(found.map(\.pageCharacters) == [expected])
        #expect(found.map { RedactionRegion(placing: $0).pageCharacters } == [expected])
    }

    @Test("A match that wraps keeps each line's own characters")
    func wrappedMatchKeepsEachLinesPart() async throws {
        let document = try Self.document(Self.paragraph)
        let page = try #require(document.page(at: 0))
        let text = try #require(page.string)
        let found = try await Self.results(.text("every page", options: SearchOptions()), in: document)
        #expect(found.count == 2)
        let parts = found.compactMap(\.pageCharacters)
        #expect(parts.count == 2)
        let letters = parts.map { WordSelection.characters([$0], in: text).offsets }
        #expect(letters.map(\.count) == [5, 4])
        let every = try Self.range(of: "signed every", in: page).lowerBound + 7
        #expect(letters.first == Set(every..<(every + 5)))
        #expect(letters.first?.isDisjoint(with: letters.last ?? []) == true)
    }

    @Test("A match Scan reads from the text layer keeps its characters too")
    func scanMatchCarriesItsCharacters() async throws {
        let document = try Self.document(Self.paragraph)
        let page = try #require(document.page(at: 0))
        let found = try await Self.results(.piiScan(categories: [.email], options: SearchOptions()), in: document)
        let expected = try Self.range(of: "q.ashby@example.com", in: page)
        #expect(found.map(\.pageCharacters) == [expected])
    }

    @Test("The part of a widened address its own box does not reach keeps its own characters")
    func scanTailCarriesItsCharacters() async throws {
        let document = try ScanOverlapTailTests.page()
        let page = try #require(document.page(at: 0))
        let hits = await ContentGlyphScanTests.scan(document)
        let tail = try #require(hits.first { $0.matchedText == ScanOverlapTailTests.street },
                                "the earlier line boxed on its own: \(ScanOverlapTailTests.show(hits))")
        #expect(tail.pageCharacters == (try Self.range(of: ScanOverlapTailTests.street, in: page)))
    }

    @Test("The run's maker selects a match's characters for a region still anchored to its text")
    func anchoredRegionSelectsItsCharacters() async throws {
        let document = try Self.document(Self.paragraph)
        let page = try #require(document.page(at: 0))
        let text = try #require(page.string)
        let found = try await Self.results(.text("Quentin Ashby", options: SearchOptions()), in: document)
        let region = RunRecord.DrawnRegion(region: RedactionRegion(placing: try #require(found.first)))
        let expected = try Self.range(of: "Quentin Ashby", in: page)
        #expect(RunRecord.planRegions([region], text: text).map(\.selected)
                == [WordSelection.characters([expected], in: text).offsets])
        #expect(RunRecord.planRegions([region], text: text).first?.selected.count == 12)
        // The run's capture reads no page text today: nothing is selected there.
        #expect(RunRecord.planRegions([region], text: "").map(\.selected) == [[]])
    }

    @Test("A drawn page's plan is the one region maker's plan at no page text, whatever each region's kind and characters")
    func drawnPagePlanReadsTheOneMaker() async throws {
        let document = try Self.document(Self.paragraph)
        let found = try await Self.results(.text("Quentin Ashby", options: SearchOptions()), in: document)
        let anchored = RunRecord.DrawnRegion(region: RedactionRegion(placing: try #require(found.first)))
        #expect(anchored.kind == .placedFromTextAnchored)
        #expect(anchored.pageCharacters != nil)
        let regions = RegionKind.allCases.enumerated().map { i, kind in
            RunRecord.DrawnRegion(id: UUID(), normalizedRect: CGRect(x: 0.1, y: 0.1 + 0.1 * Double(i), width: 0.3, height: 0.05),
                                  kind: kind, pageCharacters: kind == .placedFromTextAnchored ? anchored.pageCharacters : nil)
        } + [anchored]
        for switchOn in [false, true] {
            let choice = RunRecord.planChoice(source: RunRecord.planSource, switchOn: switchOn)
            let direct = PaintPlan.make(
                regions: RunRecord.planRegions(regions, text: ""), words: PageWords(words: []), text: "",
                facts: .noPageRead, widthSixtyFourths: 612 * 64, heightSixtyFourths: 792 * 64,
                policy: .release, source: choice.source, switchOn: choice.switchOn).plan
            let page = RunRecord.Page.makePlan(regions: regions, cropBox: CGSize(width: 612, height: 792), rotation: 0, switchOn: switchOn)
            #expect(page != nil)
            #expect(page == direct)
            #expect(page?.boxes.count == regions.count)
        }
    }

    @Test("A region moved or resized after it was placed selects nothing, and its kind says so")
    func editedRegionSelectsNothing() async throws {
        let document = try Self.document(Self.paragraph)
        let page = try #require(document.page(at: 0))
        let text = try #require(page.string)
        let found = try await Self.results(.text("Quentin Ashby", options: SearchOptions()), in: document)
        var moved = RedactionRegion(placing: try #require(found.first))
        moved.textAnchored = false
        moved.normalizedRect = moved.normalizedRect.offsetBy(dx: 0.01, dy: 0)
        let drawn = RunRecord.DrawnRegion(region: moved)
        #expect(drawn.kind == .placedFromTextThenEdited)
        #expect(RunRecord.planRegions([drawn], text: text).map(\.selected) == [[]])
    }

    @Test("A recognised match carries no characters, and its region reads as placed from the picture")
    func recognisedMatchCarriesNothing() {
        let result = SearchResult(pageIndex: 0, normalizedRect: CGRect(x: 0.1, y: 0.5, width: 0.2, height: 0.02),
                                  matchedText: "Quentin Ashby", contextSnippet: "Quentin Ashby",
                                  source: .ocr(confidence: 0.9), term: "Quentin Ashby").carrying(0..<13)
        let region = RedactionRegion(placing: result)
        #expect(region.pageCharacters == nil)
        let drawn = RunRecord.DrawnRegion(region: region)
        #expect(drawn.kind == .placedFromPicture)
        #expect(RunRecord.planRegions([drawn], text: "Quentin Ashby").map(\.selected) == [[]])
    }

    @Test("A region saved before regions carried characters reads exactly as before")
    func regionSavedWithoutTheKeyReadsAsBefore() throws {
        var region = RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.1, y: 0.5, width: 0.2, height: 0.02),
                                     source: .searchMatch(term: "Quentin Ashby"), textAnchored: true)
        region.pageCharacters = 120..<133
        let encoded = try JSONEncoder().encode(region)
        let kept = try JSONDecoder().decode(RedactionRegion.self, from: encoded)
        #expect(kept == region)
        #expect(kept.pageCharacters == 120..<133)
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object.removeValue(forKey: "pageCharacters") != nil)
        let saved = try JSONDecoder().decode(RedactionRegion.self, from: try JSONSerialization.data(withJSONObject: object))
        #expect(saved.pageCharacters == nil)
        #expect(saved.textAnchored && saved.placedFromPageText)
        #expect(RegionKind(of: saved) == RegionKind(of: region))
        var before = region
        before.pageCharacters = nil
        #expect(saved == before)
        #expect(RunRecord.planRegions([RunRecord.DrawnRegion(region: saved)], text: String(repeating: "x", count: 200))
            .map(\.selected) == [[]])
    }
}
