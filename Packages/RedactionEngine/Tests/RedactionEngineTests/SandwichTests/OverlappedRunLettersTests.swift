import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// Where two words' letters interleave on the page (the W-2 page of the loan
// packet, page index 9, draws two runs over one another), the hidden text may
// hold pieces that are no source word: each piece is a change of source word.
// It holds no letter the source lacks. The text written before whole source
// words ran the two runs together, which was no source word either.
//
// Two cells of the corpus runner, rebuilt here from the packet's ground truth
// with the runner's own region sets, seed and box floor:
// - the seeded subset, which draws no box on this page: each overlapped line
//   holds the earlier text's letters, counted with their repeats, white space
//   aside, no more and no fewer;
// - every must-fire box, five of which fall on this page and take whole words
//   there: the lines between the two lines that bound the overlap hold no
//   letter the earlier text lacked, counted with their repeats.
// The earlier text is pinned as written by the host. The lines are host
// extractions: on a simulator the page may extract one entry more, so read a
// red there as an extraction difference first.

@Suite("Overlapped runs keep their letters")
struct OverlappedRunLettersTests {

    typealias Runner = VerificationCorpusRunnerTests

    struct Line: Sendable {
        let index: Int
        let before: String
    }

    /// The seeded subset's page: line index and the earlier text.
    static let lines: [Line] = [
        Line(index: 5, before: "Tca Emnploneyersr'sw noarmteh,  aFderdereigssh, ta nSdy ZsIPte cmods, Inc."),
        Line(index: 7, before: "Dee Emlpilao yHeea'sr tfiwrste nlalmee and initial / Last nam"),
        Line(index: 8, before: "4f E1mp2lo7y eWe'rse anddfrieeeslds a Pndla ZcIPe cod"),
        Line(index: 10, before: "I15 DSetat                                                       15 Employer's state ID no.: 099-2241-7"),
    ]

    /// Every must-fire box's page: the earlier text's lines between the two
    /// bounding lines.
    static let boxedBefore: [String] = [
        "Tca Emnploneyersr'sw noarmteh,  aFderdereigssh, ta nSdy ZsIPte cmods, Inc.",
        "ee and initial / Last nam",
        "od",
        "I15 DSetat                                                       15 Employer's state ID no.: 099-2241-7",
    ]
    static let boundAbove = "XXX-XX-7438"
    static let boundBelow = "Notice to Employee"

    static func letters(_ text: String) -> [Character: Int] {
        var count: [Character: Int] = [:]
        for c in text where !c.isWhitespace { count[c, default: 0] += 1 }
        return count
    }

    /// The boxes the runner's region set `name` draws on the W-2 page (index
    /// 9), and the hidden-text lines the export writes for that page in
    /// Searchable mode under them.
    static func pageNine(_ name: String) async throws -> (boxes: [RedactionRegion], lines: [String]) {
        let doc = try #require(PDFDocument(data: try TestFixtures.loanPacketPDF()))
        let url = try #require(Bundle.module.url(
            forResource: "packet-ground-truth", withExtension: "json", subdirectory: "TestResources"))
        let gt = try JSONDecoder().decode(Runner.GTFile.self, from: Data(contentsOf: url))
        let set = try #require(Runner.regionSets(for: Runner.regionSeeds(from: gt)).first { $0.name == name })
        let boxes = set.seeds.filter { $0.page == 9 }.compactMap { Runner.region(from: $0, polygon: false) }
        let pages = Runner.buildPages(
            doc: doc, effectiveMode: .searchableRedaction, regionsByPage: [9: boxes],
            textLayerStatus: [9: .rich], hasHiddenOCG: false)
        let page = try #require(pages.first { $0.pageIndex == 9 })
        #expect(page.pipelineMode == .searchableRedaction)
        let result = try await PageRasterizer().rasterize(page)
        return (boxes, try #require(result.pageOutput.hiddenTextLines).lines.map(\.line.text))
    }

    @Test("With no box on the page, each overlapped line holds the earlier text's letters, no more and no fewer",
          .timeLimit(.minutes(2)))
    func sameLetters() async throws {
        let (boxes, written) = try await Self.pageNine("seeded-subset")
        #expect(boxes.isEmpty, "the seeded subset draws no box on this page")
        #expect(written.count == 34)
        for line in Self.lines {
            let now = try #require(written.indices.contains(line.index) ? written[line.index] : nil)
            #expect(Self.letters(now) == Self.letters(line.before), "line \(line.index): \(now)")
            #expect(now != line.before, "line \(line.index) is written as before")
        }
    }

    @Test("Under every must-fire box, the overlapped lines hold no letter the earlier text lacked",
          .timeLimit(.minutes(2)))
    func boxedLettersWithin() async throws {
        let (boxes, written) = try await Self.pageNine("all-must-fire")
        #expect(boxes.count == 5, "the must-fire set draws five boxes on this page")
        #expect(written.count == 31)
        let above = try #require(written.firstIndex(of: Self.boundAbove))
        let below = try #require(written.firstIndex(of: Self.boundBelow))
        #expect(above < below)
        let now = Self.letters(written[(above + 1)..<below].joined())
        let before = Self.letters(Self.boxedBefore.joined())
        let arrived = now.filter { $0.value > (before[$0.key] ?? 0) }
        #expect(arrived.isEmpty, "letters the earlier text lacked: \(arrived)")
        #expect(now.values.reduce(0, +) < before.values.reduce(0, +), "the boxes take whole words here")
    }
}
