import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// Where two words' letters interleave on the page (the W-2 page of the loan
// packet, page index 9, draws two runs over one another), the hidden text may hold
// pieces that are no source word: each piece is a change of source word. It
// holds no letter the source lacks, and loses none. The text written before
// whole source words ran the two runs together, which was no source word
// either. Each line below is that earlier text; the line the page writes now
// holds the same letters, counted with their repeats, white space aside.

@Suite("Overlapped runs keep their letters")
struct OverlappedRunLettersTests {

    struct Line: Sendable, CustomTestStringConvertible {
        let index: Int
        let before: String
        var testDescription: String { "line \(index)" }
    }

    static let lines: [Line] = [
        Line(index: 5, before: "Tca Emnploneyersr'sw noarmteh,  aFderdereigssh, ta nSdy ZsIPte cmods, Inc."),
        Line(index: 7, before: "Dee Emlpilao yHeea'sr tfiwrste nlalmee and initial / Last nam"),
        Line(index: 8, before: "4f E1mp2lo7y eWe'rse anddfrieeeslds a Pndla ZcIPe cod"),
        Line(index: 10, before: "I15 DSetat                                                       15 Employer's state ID no.: 099-2241-7"),
    ]

    static func letters(_ text: String) -> [Character: Int] {
        var count: [Character: Int] = [:]
        for c in text where !c.isWhitespace { count[c, default: 0] += 1 }
        return count
    }

    typealias Runner = VerificationCorpusRunnerTests

    /// The hidden-text lines the export writes for the W-2 page (index 9) in
    /// Searchable mode, under the boxes of the corpus runner's seeded subset
    /// on that page (the packet's ground truth, the runner's own seed, size
    /// and box floor): the cell the earlier text was read from.
    static func pageNineLines() async throws -> [String] {
        let doc = try #require(PDFDocument(data: try TestFixtures.loanPacketPDF()))
        let url = try #require(Bundle.module.url(
            forResource: "packet-ground-truth", withExtension: "json", subdirectory: "TestResources"))
        let gt = try JSONDecoder().decode(Runner.GTFile.self, from: Data(contentsOf: url))
        let subset = try #require(Runner.regionSets(for: Runner.regionSeeds(from: gt)).first { $0.name == "seeded-subset" })
        let boxes = subset.seeds.filter { $0.page == 9 }.compactMap { Runner.region(from: $0, polygon: false) }
        let pages = Runner.buildPages(
            doc: doc, effectiveMode: .searchableRedaction, regionsByPage: [9: boxes],
            textLayerStatus: [9: .rich], hasHiddenOCG: false)
        let page = try #require(pages.first { $0.pageIndex == 9 })
        #expect(page.pipelineMode == .searchableRedaction)
        let result = try await PageRasterizer().rasterize(page)
        return try #require(result.pageOutput.hiddenTextLines).lines.map(\.line.text)
    }

    @Test("Four lines of earlier text, each a run drawn over another")
    func lineCount() {
        #expect(Self.lines.count == 4)
    }

    @Test("Each overlapped line holds the earlier text's letters, no more and no fewer",
          .timeLimit(.minutes(2)))
    func sameLetters() async throws {
        let written = try await Self.pageNineLines()
        #expect(written.count == 34)
        for line in Self.lines {
            let now = try #require(written.indices.contains(line.index) ? written[line.index] : nil)
            #expect(Self.letters(now) == Self.letters(line.before), "line \(line.index): \(now)")
            #expect(now != line.before, "line \(line.index) is written as before")
        }
    }
}
