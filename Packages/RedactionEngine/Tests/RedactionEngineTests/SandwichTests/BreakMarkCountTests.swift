import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import RedactionEngine

// Break marks and the two count checks. A source page can give a soft hyphen
// (U+00AD) a box of its own, so the filter keeps it, while the reader of the
// redrawn hidden text does not return it. Character Count and Character
// Lineage counted it on the expected side only and failed a correct file.
// Both now leave the six break marks out on both sides, through one predicate
// that reads the one list of the six. The pages are made here with the
// joined-glyph builder (named fonts, not embedded; drawn rectangles for ink).
// All text is invented.

@Suite("Break marks are outside both sides of Character Count and Character Lineage")
struct BreakMarkCountTests {

    // MARK: - Pages

    static let shy = "\u{00AD}"

    /// A tight page (12 pt on 12) with one soft hyphen; `beforeBreak` is the
    /// character on the second line ("≈" on the case page, "x" on its control).
    static func tightLines(_ beforeBreak: String) -> [String] {
        [
            "Supply ledger SL\(shy)552190 for the east depot",
            "Net \(beforeBreak) 41 units held over to the next count",
            "Order 7731 shipped to the north yard on time",
        ]
    }

    /// A loosely set page with two soft hyphens three lines below the word a
    /// search boxes. `mark` stands where the soft hyphens stand.
    static func looseLines(_ mark: String = shy) -> [String] {
        [
            "Supply count 88 cartons in bay four",
            "Pallets were checked by the night crew",
            "Seals were intact on every crate",
            "Batch BX\(mark)20417 and BX\(mark)20418 are ready",
        ]
    }

    /// A browser's page: two joined "fi" glyphs, in "Specific" and "office",
    /// and three soft hyphens, each with a box.
    static let browserLines = [
        "Supply terms are Speci\u{FB01}c to each order",
        "Ask the of\u{FB01}ce for form RQ\(shy)7 or RQ\(shy)8",
        "Item MX\(shy)4410 ships next week",
    ]

    /// A page whose kept text holds a printed hyphen, U+002D, and a soft hyphen.
    static let hyphenLines = [
        "Supply ref AB-3301 filed with SL\(shy)552190",
        "Order 7731 shipped to the north yard",
    ]

    static func page(_ lines: [String], leading: Int) -> Data {
        TestFixtures.joinedGlyphPDF(lines: lines, wordGaps: true, fontSize: 12, leading: leading)
    }

    // MARK: - Helpers

    /// A box over the first place `word` is found on the page, as a search
    /// would place it.
    static func box(around word: String, in data: Data) throws -> RedactionRegion {
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        let hit = try #require(doc.findString(word, withOptions: []).first, "\(word) is on the page")
        let rect = hit.bounds(for: page)
        let size = page.bounds(for: .cropBox).size
        return RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: rect.minX / size.width, y: rect.minY / size.height,
                                   width: rect.width / size.width, height: rect.height / size.height),
            source: .manual)
    }

    struct Export {
        let url: URL
        let document: PDFDocument
        let page: PDFPage
        let digest: PageFilterDigest
        var text: String { page.string ?? "" }
        func remove() { try? FileManager.default.removeItem(at: url) }
    }

    /// The Searchable export of a one-page file, with a box on `word` or none.
    static func export(_ data: Data, boxOn word: String?) async throws -> Export {
        let regions = try word.map { [try box(around: $0, in: data)] } ?? []
        let run = try await TestPipeline.productionRun(data, mode: .searchableRedaction, regions: [0: regions])
        #expect(run.outcome.perPageModes == [.searchableRedaction], "the page stays Searchable")
        let digest = try #require(run.outcome.filterDigests.first ?? nil, "a Searchable page has its digest")
        let document = try #require(PDFDocument(url: run.url))
        let page = try #require(document.page(at: 0))
        return Export(url: run.url, document: document, page: page, digest: digest)
    }

    static func rows(_ page: PDFPage, _ digest: PageFilterDigest) async throws
        -> (count: VerificationStatus, lineage: VerificationStatus) {
        let verifier = SandwichVerification()
        let count = try await verifier.verifyCharacterCount(outputPage: page, digest: digest)
        let lineage = try await verifier.verifyCharacterLineage(outputPage: page, digest: digest)
        return (count, lineage)
    }

    /// The count check's own count of a page, read from its deficit line
    /// against an expectation no page reaches.
    static func outputCount(_ page: PDFPage) async throws -> Int {
        let unreachable = PageFilterDigest(
            pageIndex: 0, extractedCount: 0, excludedCount: 0,
            survivingCount: 1_000_000, boundaryCharacters: [])
        let status = try await SandwichVerification().verifyCharacterCount(outputPage: page, digest: unreachable)
        guard case .fail(let line) = status,
              let after = line.components(separatedBy: "output has ").last,
              let count = Int(after.prefix(while: \.isNumber)) else {
            Issue.record("no deficit line: \(status)")
            return -1
        }
        return count
    }

    static func deficitLine(output: Int, expected: Int) -> VerificationStatus {
        .fail("Character count deficit on page 1: output has \(output), expected \(expected)")
    }

    // MARK: - The pages that failed (D-1 to D-4)

    @Test("A tight page with a box and a kept soft hyphen: both rows pass, on the case and its control",
          arguments: ["\u{2248}", "x"])
    func tightPageWithASoftHyphen(_ beforeBreak: String) async throws {
        let data = Self.page(Self.tightLines(beforeBreak), leading: 12)
        // The shape the fix is for: the source's reader gives the soft hyphen a box.
        let source = try #require(PDFDocument(data: data)?.page(at: 0))
        let entries = try await TextLayerExtractor().extractCharacters(from: source)
        try #require(entries.contains { $0.character == Self.shy && $0.bounds.width > 0 },
                     "the source's reader returns the soft hyphen with a box")
        let export = try await Self.export(data, boxOn: "Supply")
        defer { export.remove() }
        #expect(!export.text.contains("Supply"), "the box takes the word")
        let rows = try await Self.rows(export.page, export.digest)
        #expect(rows.count == .pass, "\(beforeBreak): Character Count \(rows.count)")
        #expect(rows.lineage == .pass, "\(beforeBreak): Character Lineage \(rows.lineage)")
    }

    @Test("A loose page with two soft hyphens three lines below the box: both rows pass")
    func loosePageWithTwoSoftHyphens() async throws {
        let export = try await Self.export(Self.page(Self.looseLines(), leading: 20), boxOn: "Supply")
        defer { export.remove() }
        let rows = try await Self.rows(export.page, export.digest)
        #expect(rows.count == .pass, "Character Count \(rows.count)")
        #expect(rows.lineage == .pass, "Character Lineage \(rows.lineage)")
    }

    @Test("The loose page with no box at all: both rows pass")
    func loosePageWithNoBox() async throws {
        let export = try await Self.export(Self.page(Self.looseLines(), leading: 20), boxOn: nil)
        defer { export.remove() }
        let rows = try await Self.rows(export.page, export.digest)
        #expect(rows.count == .pass, "Character Count \(rows.count)")
        #expect(rows.lineage == .pass, "Character Lineage \(rows.lineage)")
    }

    @Test("The loose page with \"/\" where the soft hyphens stand: both rows pass")
    func loosePageWithSlashes() async throws {
        let export = try await Self.export(Self.page(Self.looseLines("/"), leading: 20), boxOn: "Supply")
        defer { export.remove() }
        let rows = try await Self.rows(export.page, export.digest)
        #expect(rows.count == .pass, "Character Count \(rows.count)")
        #expect(rows.lineage == .pass, "Character Lineage \(rows.lineage)")
    }

    // MARK: - What still fails (D-5, D-9)

    @Test("A kept letter missing from the hidden text still fails both rows, a deficit of one")
    func aMissingLetterStillFails() async throws {
        let kept = try await Self.export(Self.page(Self.tightLines("x"), leading: 12), boxOn: "Supply")
        defer { kept.remove() }
        let short = Self.tightLines("x").map { $0.replacingOccurrences(of: "Order", with: "Ordr") }
        let drawn = try await Self.export(Self.page(short, leading: 12), boxOn: "Supply")
        defer { drawn.remove() }
        let expected = kept.digest.survivingNonWhitespaceCount
        let rows = try await Self.rows(drawn.page, kept.digest)
        #expect(rows.count == Self.deficitLine(output: expected - 1, expected: expected), "Character Count \(rows.count)")
        #expect(rows.lineage.isFail, "Character Lineage \(rows.lineage)")
    }

    @Test("A printed hyphen missing from the hidden text still fails both rows, a deficit of one")
    func aMissingPrintedHyphenStillFails() async throws {
        let kept = try await Self.export(Self.page(Self.hyphenLines, leading: 12), boxOn: "Supply")
        defer { kept.remove() }
        let short = Self.hyphenLines.map { $0.replacingOccurrences(of: "AB-3301", with: "AB3301") }
        let drawn = try await Self.export(Self.page(short, leading: 12), boxOn: "Supply")
        defer { drawn.remove() }
        let expected = kept.digest.survivingNonWhitespaceCount
        let rows = try await Self.rows(drawn.page, kept.digest)
        #expect(rows.count == Self.deficitLine(output: expected - 1, expected: expected), "Character Count \(rows.count)")
        #expect(rows.lineage.isFail, "Character Lineage \(rows.lineage)")
    }

    // MARK: - The predicate and the one list (D-6 to D-8)

    static let sixMarks: [String] = ["\u{00AD}", "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}"]

    @Test("The predicate: each of the six marks alone is outside the count; hyphens, letters and digits are inside")
    func predicateTable() {
        for mark in Self.sixMarks {
            #expect(SandwichMetrics.isOutsideCharacterCount(mark), "U+\(String(format: "%04X", mark.unicodeScalars.first!.value)) is outside")
        }
        for kept in ["-", "\u{2010}", "\u{2011}", "a", "7"] {
            #expect(!SandwichMetrics.isOutsideCharacterCount(kept), "\(kept.debugDescription) is inside")
        }
        #expect(SandwichMetrics.isOutsideCharacterCount(" "), "white space stays outside")
        #expect(!SandwichMetrics.isOutsideCharacterCount("a\u{00AD}"), "a letter with a mark is inside")
    }

    @Test("A soft hyphen with a box, read as an output page is read, counts and hashes as the page without it")
    func outputWalksSkipASoftHyphen() async throws {
        let with = try #require(PDFDocument(data: Self.page(["Supply ledger SL\(Self.shy)552190 for the depot"], leading: 12))?.page(at: 0))
        let without = try #require(PDFDocument(data: Self.page(["Supply ledger SL552190 for the depot"], leading: 12))?.page(at: 0))
        try #require(with.string?.contains(Self.shy) == true, "the reader returns the soft hyphen")
        #expect(try await Self.outputCount(with) == (try await Self.outputCount(without)), "Character Count's output count")
        #expect(try SandwichVerification.computeOutputLineageHash(with) == (try SandwichVerification.computeOutputLineageHash(without)),
                "Character Lineage's output hash")
    }

    @Test("The six marks are written once in the engine, and each reader of them answers as before")
    func oneDefinitionOfTheSix() throws {
        // Each of the six, as a literal in the sources.
        let spellings = ["00AD", "200B", "200C", "200D", "2060", "FEFF"].map { ["u{\($0)}", "0x\($0)"] }
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/RedactionEngine")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        try #require(files.count > 100, "the engine's sources are read")
        var lists: [String] = []
        for file in files {
            for line in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n") {
                let upper = line.uppercased()
                let held = spellings.filter { $0.contains { upper.contains($0.uppercased()) } }.count
                if held >= 2 { lists.append("\(file.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))") }
            }
        }
        #expect(lists.count == 1 && lists.first?.hasPrefix("TextNormalizer.swift") == true,
                "one line in the engine lists the marks, in TextNormalizer.swift: \(lists)")
        #expect(Set(TextNormalizer.breakMarks.map { String(Character($0)) }) == Set(Self.sixMarks))
        // The three readers, each as before for the six and for "-".
        for mark in Self.sixMarks {
            #expect(TextNormalizer.isRunCharacter(Character(mark)))
            #expect(VerificationEngine.fragmentSeparators.contains(Character(mark)))
            #expect(SandwichMetrics.isOutsideCharacterCount(mark))
        }
        #expect(!TextNormalizer.isRunCharacter("-"))
        #expect(VerificationEngine.fragmentSeparators.contains("-"))
        #expect(!SandwichMetrics.isOutsideCharacterCount("-"))
        let separatorsBefore: Set<Character> = [
            " ", "\u{00A0}", "-", "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2212}",
            "\u{00AD}", "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}",
        ]
        #expect(VerificationEngine.fragmentSeparators == separatorsBefore, "the OCR check's separators are the fifteen they were")
    }

    // MARK: - Joined glyphs and the count's unit (D-10, D-11)

    @Test("A browser's page with two joined glyphs and three soft hyphens: both rows pass, each letter once")
    func browserPage() async throws {
        let export = try await Self.export(Self.page(Self.browserLines, leading: 14), boxOn: "Supply")
        defer { export.remove() }
        let rows = try await Self.rows(export.page, export.digest)
        #expect(rows.count == .pass, "Character Count \(rows.count)")
        #expect(rows.lineage == .pass, "Character Lineage \(rows.lineage)")
        #expect(try await Self.outputCount(export.page) == export.digest.survivingNonWhitespaceCount,
                "the output count equals the expected count")
        #expect(export.text.contains("Specific") && export.text.contains("office"), "the hidden text: \(export.text.debugDescription)")
        #expect(!export.text.contains("Specifific") && !export.text.contains("offifice"), "a joined glyph is written once")
    }

    @Test("The expected count is one per kept entry: four entries each reading \"fi\", drawn as eight letters, warn")
    func theCountsUnitIsTheEntry() async throws {
        let entries = (0..<4).map { i in
            CharacterInfo(character: "fi", bounds: CGRect(x: 72 + 14 * CGFloat(i), y: 700, width: 10, height: 12), stringIndex: i)
        }
        let digest = FilterResult(surviving: entries, totalCharacters: entries.count, excludedCount: 0)
            .toDigest(pageIndex: 0, redactionRects: [], safetyMargin: 2)
        #expect(digest.survivingNonWhitespaceCount == 4)
        let drawn = SearchableMergeProbe.renderInvisibleLayer(entries, pageSize: CGSize(width: 612, height: 792))
        let page = try #require(PDFDocument(data: drawn)?.page(at: 0))
        #expect(try await Self.outputCount(page) == 8, "the hidden text reads eight letters")
        let count = try await SandwichVerification().verifyCharacterCount(outputPage: page, digest: digest)
        #expect(count == .warn("Character count excess on page 1: output has 8, expected 4"), "Character Count \(count)")
    }
}
