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

    static func lineEntries(_ text: String) -> [CharacterInfo] {
        var entries: [CharacterInfo] = []
        var word = 0
        for (i, character) in text.enumerated() {
            if character.isWhitespace { word += 1 }
            entries.append(CharacterInfo(
                character: String(character), bounds: CGRect(x: 72 + CGFloat(i) * 7.2, y: 700, width: 7.2, height: 12),
                stringIndex: i, lineIndex: 0, wordIndex: word))
        }
        return entries
    }

    static let frame = PageFrame(rotation: 0, displayedSize: CGSize(width: 612, height: 792))

    /// A word none of the three faces draws, then white space; and a lone
    /// object mark, which the fold reads as a space.
    static let noLetterLeft = ["\u{6F22}\u{5B57} ", "\u{FFFC}"]

    @Test("A page left with white space alone is a picture with no searchable text left", arguments: noLetterLeft)
    func whiteSpaceAloneIsAPicture(_ text: String) async throws {
        let path = try await PageTextPath.run(
            entries: Self.lineEntries(text), frame: Self.frame,
            textPathRectangles: [], paintedRectangles: [], pageIndex: 0)
        guard case .picture(let reason) = path.outcome else {
            Issue.record("\(text.unicodeScalars.map { String($0.value, radix: 16) }): \(path.outcome)"); return
        }
        #expect(reason == .noWritableText)
    }

    @Test("A page whose box takes every word, a space left after it, is written empty")
    func boxesTakeEveryWordWrittenEmpty() async throws {
        let entries = Self.lineEntries("Alpha ")
        let box = entries.prefix(5).map(\.bounds).reduce(entries[0].bounds) { $0.union($1) }
        let path = try await PageTextPath.run(
            entries: entries, frame: Self.frame,
            textPathRectangles: [TextPathRectangle(rect: box, kind: .ordinary)], paintedRectangles: [], pageIndex: 0)
        guard case .written(let written, _, _) = path.outcome else { Issue.record("\(path.outcome)"); return }
        #expect(!written.contains { !$0.character.allSatisfy(\.isWhitespace) })
    }

    /// Two spaces the hidden text writes in Courier: on this system each one
    /// is laid out in Courier if Courier has it, and otherwise the line cannot
    /// be laid out and the page is a picture with no searchable text left.
    static let widerSpaces = ["\u{3000}", "\u{2003}"]

    @Test("A space Courier lacks makes its line unlaid and the page a picture; one it has is written", arguments: widerSpaces)
    func spaceCourierLacks(_ space: String) async throws {
        let courier = try #require(HiddenTextFonts.faces.first { $0.name == "Courier" }?.font)
        let has = HiddenTextFonts.hasGlyphs(for: Character(space), in: courier)
        let text = "Alpha\(space)beta"
        let path = try await PageTextPath.run(
            entries: Self.lineEntries(text), frame: Self.frame,
            textPathRectangles: [], paintedRectangles: [], pageIndex: 0)
        if has {
            #expect(HiddenTextLine.layout(text, size: 12) != nil)
            guard case .written = path.outcome else { Issue.record("Courier has it: \(path.outcome)"); return }
        } else {
            #expect(HiddenTextLine.layout(text, size: 12) == nil)
            guard case .picture(let reason) = path.outcome else { Issue.record("Courier lacks it: \(path.outcome)"); return }
            #expect(reason == .noWritableText)
        }
    }

    /// A tightly set line: four words in one TJ array with 0.48 pt between
    /// them and no space character, which PDFKit reads as one run; and a
    /// loose line, 4.8 pt between its words, which it reads as four.
    static func tightLinePage() -> Data {
        let tight = "[(Signed) -40 (by) -40 (Morgan) -40 (Reyes)] TJ"
        let loose = "[(Paid) -400 (in) -400 (full) -400 (today)] TJ"
        let stream = "BT /F1 12 Tf 72 700 Td \(tight) ET BT /F1 12 Tf 72 680 Td \(loose) ET"
        return buildRawPDF(objects: [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>"),
            PDFObject(id: 4, content: "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream"),
            PDFObject(id: 5, content: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"),
        ], rootId: 1)
    }

    @Test("Words PDFKit joins on a tightly set line stay joined, and a box on one takes the joined run")
    func pdfKitJoinedWords() async throws {
        let page = try #require(PDFDocument(data: Self.tightLinePage())?.page(at: 0))
        let read = page.string ?? ""
        try #require(read.contains("SignedbyMorganReyes"), "precondition: PDFKit joins the tight line; it reads \(read.debugDescription)")
        try #require(read.contains("Paid in full today"), "precondition: PDFKit keeps the loose line's words; it reads \(read.debugDescription)")
        let entries = try await TextLayerExtractor().extractCharacters(from: page)
        let frame = PageFrame(rotation: 0, displayedSize: CGSize(width: 612, height: 792))
        // No box: the joined run is written joined.
        let open = try await PageTextPath.run(entries: entries, frame: frame, textPathRectangles: [],
                                              paintedRectangles: [], pageIndex: 0)
        let openText = try #require(try WholeWordAssertion.write(open, frame: frame)).text
        #expect(WholeWordAssertion.words(openText).contains("SignedbyMorganReyes"), "\(openText.debugDescription)")
        // A box on "Morgan" alone: the whole joined run leaves; the loose line stays.
        let text = entries.map(\.character).joined() as NSString
        let range = text.range(of: "Morgan")
        let morgan = entries.filter { (range.location..<(range.location + range.length)).contains($0.stringIndex) }
        try #require(morgan.count == 6, "the six letters of Morgan")
        let box = morgan.map(\.bounds).reduce(morgan[0].bounds) { $0.union($1) }
        let rectangles = [TextPathRectangle(rect: box, kind: .ordinary)]
        let boxed = try await PageTextPath.run(entries: entries, frame: frame, textPathRectangles: rectangles,
                                               paintedRectangles: [], pageIndex: 0)
        let written = try #require(try WholeWordAssertion.write(boxed, frame: frame))
        WholeWordAssertion.holds(written, boxedWords: ["SignedbyMorganReyes", "Morgan"], rectangles: rectangles,
                                 painted: [], frame: frame, "the box on Morgan")
        let words = WholeWordAssertion.words(written.text)
        for part in ["Signed", "Morgan", "Reyes"] {
            #expect(!written.text.contains(part), "no part of the joined run is written: \(written.text.debugDescription)")
        }
        #expect(words == ["Paid", "in", "full", "today"], "\(words)")
    }

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
