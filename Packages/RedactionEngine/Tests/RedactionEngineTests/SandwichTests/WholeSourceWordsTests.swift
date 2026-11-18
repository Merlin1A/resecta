import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import RedactionEngine

// The hidden text holds whole source words only, with the page's word
// breaks. A word leaves whole when the filter (a box and its 3 pt margin) or
// the drawn-cell rule takes any letter of it; the record is taken after. All
// text is invented.

@Suite("The hidden text holds whole source words only", .serialized)
struct WholeSourceWordsTests {

    struct Page: Sendable, CustomTestStringConvertible {
        let name: String
        let lines: [String]
        /// Text on the page to box, each as the reader selects it.
        let boxed: [String]
        /// Source words that must not be in the hidden text.
        let gone: [String]
        /// Source words that must be in it.
        let kept: [String]
        var testDescription: String { name }
        var data: Data { TestFixtures.joinedGlyphPDF(lines: lines, wordGaps: true) }
    }

    static let pages: [Page] = [
        Page(name: "a date with its day boxed", lines: ["Paid on January 14 in full"],
             boxed: ["14"], gone: ["14"], kept: ["Paid", "on", "in", "full"]),
        Page(name: "part of a number boxed", lines: ["Total 125400 due"],
             boxed: ["125"], gone: ["125400"], kept: ["Total", "due"]),
        Page(name: "a boxed name and its full stop", lines: ["Signed by Smith. Thanks again"],
             boxed: ["Smith"], gone: ["Smith."], kept: ["Signed", "by", "again"]),
        Page(name: "a number on the line above a box", lines: ["Account 5507", "Holder Avery Quinn"],
             boxed: ["Avery"], gone: ["Avery"], kept: ["Account", "5507", "Holder"]),
        Page(name: "no box", lines: ["The most you could"],
             boxed: [], gone: [], kept: ["The", "most", "you", "could"]),
    ]

    @Test("The pages are five")
    func pageCount() {
        #expect(Self.pages.count == 5)
    }

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// The source words, by the page's one partition, that have a letter
    /// within the margin of a box.
    static func wordsNearABox(_ entries: [CharacterInfo], boxes: [CGRect]) -> Set<String> {
        let margin = boxes.map { $0.insetBy(dx: -safetyMarginPoints, dy: -safetyMarginPoints) }
        var text: [Int: String] = [:]
        var near: Set<Int> = []
        for entry in entries where !SandwichMetrics.isLineageWhitespace(entry.character) {
            text[entry.wordIndex, default: ""] += entry.character
            if margin.contains(where: { $0.intersects(entry.bounds) }) { near.insert(entry.wordIndex) }
        }
        return Set(near.compactMap { text[$0] })
    }

    @Test("Each page's hidden text holds only whole source words, and a word missing had a letter by a box", arguments: pages)
    func wholeWords(_ page: Page) async throws {
        let data = page.data
        let source = try #require(PDFDocument(data: data))
        let sourcePage = try #require(source.page(at: 0))
        let size = sourcePage.bounds(for: .cropBox).size
        let hits = try page.boxed.map { word in
            try #require(source.findString(word, withOptions: []).first, "\(word) is on the page").bounds(for: sourcePage)
        }
        let regions = hits.map { rect in
            RedactionRegion(id: UUID(), normalizedRect: CGRect(
                x: rect.minX / size.width, y: rect.minY / size.height,
                width: rect.width / size.width, height: rect.height / size.height), source: .manual)
        }
        let run = try await TestPipeline.productionRun(data, mode: .searchableRedaction, regions: [0: regions])
        defer { try? FileManager.default.removeItem(at: run.url) }
        #expect(run.outcome.perPageModes == [.searchableRedaction], "\(page.name): \(run.outcome.perPageFallbackReasons)")
        let output = try #require(PDFDocument(url: run.url)?.page(at: 0))
        let written = Self.words(output.string ?? "")
        let sourceWords = page.lines.flatMap(Self.words)

        for word in written {
            #expect(sourceWords.contains(word), "\(page.name): \(word.debugDescription) is no source word; the hidden text reads \(written)")
        }
        let entries = try await TextLayerExtractor().extractCharacters(from: sourcePage)
        let near = Self.wordsNearABox(entries, boxes: hits)
        for word in sourceWords where !written.contains(word) {
            #expect(near.contains(word), "\(page.name): \(word.debugDescription) is missing but had no letter by a box")
        }
        for word in page.gone { #expect(!written.contains(word), "\(page.name): \(word) is written") }
        for word in page.kept { #expect(written.contains(word), "\(page.name): \(word) is missing from \(written)") }

        let digest = try #require(run.outcome.filterDigests.first ?? nil)
        let verifier = SandwichVerification()
        #expect(try await verifier.verifyCharacterCount(outputPage: output, digest: digest) == .pass, "\(page.name): Character Count")
        #expect(try await verifier.verifyCharacterLineage(outputPage: output, digest: digest) == .pass, "\(page.name): Character Lineage")
    }

    @Test("The writer breaks between two words the page's text has no space between")
    func breakWithoutASpaceEntry() {
        // "The most" as two words with no space entry between them, the
        // letters set edge to edge, as a page may store a word break.
        var entries: [CharacterInfo] = []
        var x: CGFloat = 72
        for (word, text) in ["The", "most", "you", "could"].enumerated() {
            for letter in text {
                entries.append(CharacterInfo(
                    character: String(letter), bounds: CGRect(x: x, y: 700, width: 7.2, height: 12),
                    stringIndex: entries.count, lineIndex: 0, wordIndex: word))
                x += 7.2
            }
        }
        let lines = TextLayerReconstructor.layoutLinesWithSources(entries, pageWidth: 612, redactionRects: [])
        #expect(lines.map(\.line.text) == ["The most you could"], "\(lines.map(\.line.text))")
        // Each letter's recorded place in the line is the letter itself.
        for line in lines {
            let text = line.line.text as NSString
            for source in line.sources {
                #expect(text.substring(with: NSRange(location: source.utf16Offset, length: 1)) == entries[source.entry].character)
            }
        }
    }

    @Test("A word the filter takes a letter of leaves whole; a space that leaves takes no word")
    func wordsLosingALetter() {
        func entry(_ c: String, _ word: Int) -> CharacterInfo {
            CharacterInfo(character: c, bounds: .zero, stringIndex: 0, lineIndex: 0, wordIndex: word)
        }
        let before = [entry("a", 0), entry("b", 0), entry(" ", 1), entry("c", 1), entry("d", 2)]
        #expect(PageTextPath.wordsLosingALetter(before: before, after: [before[0], before[3], before[4]]) == [0])
        #expect(PageTextPath.wordsLosingALetter(before: before, after: [before[0], before[1], before[3], before[4]]).isEmpty)
        #expect(PageTextPath.wordsLosingALetter(before: before, after: []) == [0, 1, 2])
    }
}
