import Testing
import Foundation
import PDFKit
import CoreGraphics
@testable import RedactionEngine
#if canImport(UIKit)
import UIKit
#endif

// A joined glyph is one drawn glyph whose text is more than one letter: "fi"
// set as one glyph by a typesetter, a Thai syllable with SARA AM drawn as one
// cluster, a joined emoji. PDFKit gives each offset such a glyph covers a
// selection whose text is the whole glyph's, so the text layer wrote every
// letter of it once per offset ("fifinal", "offiffiffice"). Each entry's text
// is now the page's own text at its offset, with the whole glyph's bounds.
//
// The pages are made here, with invented text. The Latin pages are written by
// hand with named, unembedded fonts and a ToUnicode map, so nothing is
// embedded; each glyph's ink is a painted rectangle. The Thai, emoji and marks
// pages are drawn by the system at test time and are never stored.
//
// The number of entries whose text changes on each page is worked out from how
// the page is made: each joined glyph changes one entry per offset it covers,
// so a two-letter glyph changes two and a three-letter glyph three.

/// One page of the suite: how it is made, and what it must show.
struct JoinedGlyphPage: Sendable, CustomTestStringConvertible {
    let name: String
    let make: @Sendable () -> Data
    /// Entries whose text differs from the shipped walk's.
    let changedEntries: Int
    /// The page's words as a reader reads the source, in order; nil where
    /// the export's words are not compared (a page drawn in a substituted
    /// font, which the font check refuses today, or a page whose export
    /// runs two words together today; each says why).
    let sourceWords: [String]?
    /// Scalars of a joined cluster that the export must read back once each.
    var readBackOnce: [String]? = nil
    /// Word spaces the shipped walk skipped as separator clamps that now
    /// keep an entry (a space whose selection runs on into the next letter).
    var keptSpaces: Int = 0
    var testDescription: String { name }
}

@Suite("Joined glyphs: each letter of the page's text written once", .tags(.sandwich), .serialized)
struct JoinedGlyphExtractionTests {

    // MARK: - The pages

    static let typesetLines = [
        "The \u{FB01}nal o\u{FB03}ce re\u{FB02}ects",   // fi 2 + ffi 3 + fl 2
        "ba\u{FB04}ed sta\u{FB00}",                     // ffl 3 + ff 2; "staff" ends the line
        "sta\u{FB00} of nine",                          // ff 2; "staff of" in mid-line
    ]
    static let typesetWords = ["The", "final", "office", "reflects", "baffled", "staff", "staff", "of", "nine"]

    static let boxLines = [
        "Box \u{FB01}x", "Box \u{FB02}x", "Box \u{FB00}x", "Box \u{FB03}x", "Box \u{FB04}x",
    ]

    static let pages: [JoinedGlyphPage] = [
        JoinedGlyphPage(
            name: "joined Latin letters, one-byte codes, spaces as gaps",
            make: { TestFixtures.joinedGlyphPDF(lines: JoinedGlyphExtractionTests.typesetLines, encoding: .oneByte, wordGaps: true) },
            changedEntries: 14,   // 2 + 3 + 2, then 3 + 2, then 2
            sourceWords: JoinedGlyphExtractionTests.typesetWords),
        JoinedGlyphPage(
            name: "joined Latin letters, two-byte codes, spaces as glyphs",
            make: { TestFixtures.joinedGlyphPDF(lines: JoinedGlyphExtractionTests.typesetLines, encoding: .twoByte) },
            changedEntries: 14,
            sourceWords: JoinedGlyphExtractionTests.typesetWords),
        JoinedGlyphPage(
            name: "one joined glyph per line, each kind",
            make: { TestFixtures.joinedGlyphPDF(lines: JoinedGlyphExtractionTests.boxLines, wordGaps: true) },
            changedEntries: 12,   // fi 2 + fl 2 + ff 2 + ffi 3 + ffl 3
            sourceWords: ["Box", "fix", "Box", "flx", "Box", "ffx", "Box", "ffix", "Box", "fflx"]),
        JoinedGlyphPage(
            name: "joined glyphs whose text is one presentation-form code point",
            make: { TestFixtures.joinedGlyphPDF(
                lines: ["The o\u{FB03}ce was ba\u{FB04}ed"], text: .presentationForm, wordGaps: true) },
            changedEntries: 0,    // one code point, one offset: nothing to write twice
            sourceWords: ["The", "o\u{FB03}ce", "was", "ba\u{FB04}ed"]),
        JoinedGlyphPage(
            // A gap two spaces wide after a joined glyph: the reader writes
            // one space there, and the selections of that space and of the
            // letter after it both read " x". The shipped walk skipped the
            // space; it now keeps its entry, and the letter's entry reads its
            // own "x".
            name: "a wide gap after a joined glyph",
            make: { TestFixtures.joinedGlyphPDF(lines: ["sta\u{FB00}      of", "o\u{FB03}  x"], wordGaps: true) },
            changedEntries: 6,    // ff 2, then ffi 3, then the "x" whose selection reads " x"
            sourceWords: ["staff", "of", "offi", "x"],
            keptSpaces: 1),       // the space before "x"
        JoinedGlyphPage(
            name: "no joined glyph",
            make: { TestFixtures.joinedGlyphPDF(lines: ["The office reflects baffled staff"], wordGaps: true) },
            changedEntries: 0,
            sourceWords: ["The", "office", "reflects", "baffled", "staff"]),
        JoinedGlyphPage(
            name: "a Thai syllable with SARA AM drawn as one cluster",
            make: { JoinedGlyphExtractionTests.drawnPage("การชำระเงิน", font: "Thonburi") },
            changedEntries: 2,    // the cluster of CHO CHANG and SARA AM: two offsets
            sourceWords: nil,
            readBackOnce: ["\u{0E0A}", "\u{0E33}"]),
        JoinedGlyphPage(
            name: "a joined emoji",
            make: { JoinedGlyphExtractionTests.drawnPage("Team \u{1F469}\u{200D}\u{1F4BB} here", font: "Helvetica") },
            changedEntries: 2,    // the woman and the laptop: two offsets of one glyph
            sourceWords: nil,
            readBackOnce: ["\u{1F469}", "\u{1F4BB}"]),
        JoinedGlyphPage(
            name: "a combining mark and a surrogate pair",
            make: { JoinedGlyphExtractionTests.drawnPage("Cafe\u{0301} \u{1D400}x", font: "Helvetica") },
            changedEntries: 0,
            sourceWords: nil),
    ]

    static var latinPages: [JoinedGlyphPage] { pages.filter { $0.sourceWords != nil } }
    static var clusterPages: [JoinedGlyphPage] { pages.filter { $0.readBackOnce != nil } }

    /// A page of `text` drawn by the system in `font`.
    static func drawnPage(_ text: String, font: String) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        return renderer.pdfData { context in
            context.beginPage()
            let drawn = UIFont(name: font, size: 24) ?? UIFont.systemFont(ofSize: 24)
            (text as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: [
                .font: drawn, .foregroundColor: UIColor.black,
            ])
        }
    }

    @Test("The suite's pages: nine, six of them Latin, two of them clusters")
    func pageCounts() {
        #expect(Self.pages.count == 9)
        #expect(Self.latinPages.count == 6)
        #expect(Self.clusterPages.count == 2)
        #expect(Set(Self.pages.map(\.name)).count == Self.pages.count)
    }

    // MARK: - Against the shipped walk, entry for entry

    @Test("Each entry is the shipped walk's but for a joined glyph's letters", arguments: pages)
    func entryForEntry(_ fixture: JoinedGlyphPage) async throws {
        let doc = try #require(PDFDocument(data: fixture.make()))
        let page = try #require(doc.page(at: 0))
        let own = try #require(page.string) as NSString
        let entries = try await TextLayerExtractor().extractCharacters(from: page)
        let shipped = try await WalkBeforeJoinedGlyphFix.extractCharacters(from: page)

        try #require(entries.count == shipped.count + fixture.keptSpaces,
                     "\(fixture.name): one entry per shipped entry, and one per kept space")
        #expect(!entries.isEmpty, "\(fixture.name): the page has entries")
        // A kept space is an entry at an offset the shipped walk skipped: a
        // space whose text is the page's own and whose selection begins
        // with it. Every other entry pairs with the shipped entry at its
        // offset.
        let shippedOffsets = Set(shipped.map(\.stringIndex))
        let kept = entries.filter { !shippedOffsets.contains($0.stringIndex) }
        #expect(kept.count == fixture.keptSpaces, "\(fixture.name): kept spaces")
        for entry in kept {
            let range = own.rangeOfComposedCharacterSequence(at: entry.stringIndex)
            #expect(entry.character == " " && own.substring(with: range) == " ",
                    "\(fixture.name): offset \(entry.stringIndex) is a kept word space")
        }
        var changed: [String] = []
        for (entry, before) in zip(entries.filter { shippedOffsets.contains($0.stringIndex) }, shipped) {
            #expect(entry.stringIndex == before.stringIndex)
            #expect(entry.bounds == before.bounds, "\(fixture.name): offset \(entry.stringIndex) keeps its bounds")
            #expect(entry.lineIndex == before.lineIndex)
            let range = own.rangeOfComposedCharacterSequence(at: before.stringIndex)
            let pageText = own.substring(with: range)
            if (before.character as NSString).length > range.length {
                changed.append("\(before.stringIndex): \(before.character.debugDescription)")
                #expect(entry.character == pageText,
                        "\(fixture.name): offset \(entry.stringIndex) reads \(entry.character.debugDescription), the page's text is \(pageText.debugDescription)")
            } else {
                #expect(entry.character == before.character,
                        "\(fixture.name): offset \(entry.stringIndex) is unchanged")
            }
        }
        #expect(changed.count == fixture.changedEntries, "\(fixture.name): entries whose text changed, at \(changed)")
    }

    // MARK: - The export

    private func exportWithoutBoxes(_ data: Data) async throws -> (url: URL, outcome: ProductionPageLoop.RedactionOutcome) {
        try await TestPipeline.productionRun(data, mode: .searchableRedaction, regions: [0: []])
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
    }

    /// A source word as the hidden text writes it: each joined-letter code
    /// point as its letters (the fold before the filter).
    static func folded(_ word: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in word.unicodeScalars {
            if let letters = TestFixtures.joinedGlyphLetters[scalar] {
                scalars.append(contentsOf: letters.unicodeScalars)
            } else {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    @Test("An export with no box holds the source's words, folded, no more and no fewer", arguments: latinPages)
    func bothDirections(_ fixture: JoinedGlyphPage) async throws {
        let source = try #require(fixture.sourceWords).map(Self.folded)
        let run = try await exportWithoutBoxes(fixture.make())
        defer { try? FileManager.default.removeItem(at: run.url) }
        #expect(run.outcome.perPageModes == [.searchableRedaction], "\(fixture.name): the page stays Searchable")
        let out = try #require(PDFDocument(url: run.url)?.page(at: 0)?.string)
        let written = Self.words(out)
        #expect(written.filter { !source.contains($0) }.isEmpty,
                "\(fixture.name): a hidden-text word the source lacks, in \(out.debugDescription)")
        #expect(source.filter { !written.contains($0) }.isEmpty,
                "\(fixture.name): a source word missing from \(out.debugDescription)")
        #expect(written.sorted() == source.sorted(), "\(fixture.name): each word as often as in the source")
    }

    @Test("Character Count and Character Lineage read passed", arguments: latinPages)
    func countAndLineagePass(_ fixture: JoinedGlyphPage) async throws {
        let run = try await exportWithoutBoxes(fixture.make())
        defer { try? FileManager.default.removeItem(at: run.url) }
        let digest = try #require(run.outcome.filterDigests.first ?? nil, "\(fixture.name): a Searchable page has its digest")
        let page = try #require(PDFDocument(url: run.url)?.page(at: 0))
        let verifier = SandwichVerification()
        let count = try await verifier.verifyCharacterCount(outputPage: page, digest: digest)
        let lineage = try await verifier.verifyCharacterLineage(outputPage: page, digest: digest)
        #expect(count == .pass, "\(fixture.name): Character Count \(count)")
        #expect(lineage == .pass, "\(fixture.name): Character Lineage \(lineage)")
    }

    // None of the hidden text's three faces draws Thai or an emoji, so the
    // alphabet rule leaves such a run out whole and counts it: a page of Thai
    // alone is left with no word and is a picture page with its reason; the
    // emoji's page keeps its other words.
    @Test("A joined Thai syllable's page is a picture page; a joined emoji is left out and counted", arguments: clusterPages)
    func clustersAfterTheAlphabetRule(_ fixture: JoinedGlyphPage) async throws {
        let scalars = try #require(fixture.readBackOnce)
        let data = fixture.make()
        let run = try await exportWithoutBoxes(data)
        defer { try? FileManager.default.removeItem(at: run.url) }
        if fixture.name.contains("Thai") {
            #expect(run.outcome.perPageModes == [.secureRasterization], "\(fixture.name): the page is a picture")
            #expect(run.outcome.perPageFallbackReasons == [.noWritableText], "\(fixture.name): \(run.outcome.perPageFallbackReasons)")
            #expect(PDFDocument(url: run.url)?.page(at: 0)?.string?.isEmpty ?? true, "\(fixture.name): no text layer")
            return
        }
        #expect(run.outcome.perPageModes == [.searchableRedaction], "\(fixture.name): the page stays Searchable")
        let out = try #require(PDFDocument(url: run.url)?.page(at: 0)?.string)
        for scalar in scalars {
            let times = out.unicodeScalars.filter { String($0) == scalar }.count
            #expect(times == 0, "\(fixture.name): \(scalar.debugDescription) read back \(times) times in \(out.debugDescription)")
        }
        #expect(Self.words(out) == ["Team", "here"], "\(fixture.name): the other words are written: \(out.debugDescription)")
        let source = try #require(PDFDocument(data: data)?.page(at: 0))
        let entries = TextPathFold.fold(try await TextLayerExtractor().extractCharacters(from: source))
        #expect(TextPathAlphabetMarks.marks(entries).runsLeftOut == 1, "\(fixture.name): one run left out and counted")
    }

    // MARK: - A word space after a joined glyph

    struct GapPage: Sendable, CustomTestStringConvertible {
        let lines: [String]
        let encoding: TestFixtures.JoinedGlyphEncoding
        let wordGaps: Bool
        let exported: String
        var testDescription: String {
            "\(lines.joined(separator: " / ").debugDescription), \(encoding), spaces as \(wordGaps ? "gaps" : "glyphs")"
        }
    }

    /// A gap two and three spaces wide after a joined glyph, in each of the
    /// four forms the builder writes. The reader writes one space for the
    /// gap.
    static let gapPages: [GapPage] = [
        (["sta\u{FB00}      of", "o\u{FB03}  x"], "staff of\noffi x"),
        (["o\u{FB03}   x"], "offi x"),
    ].flatMap { lines, exported in
        [(TestFixtures.JoinedGlyphEncoding.oneByte, true), (.twoByte, true), (.oneByte, false), (.twoByte, false)].map {
            GapPage(lines: lines, encoding: $0.0, wordGaps: $0.1, exported: exported)
        }
    }

    @Test("A word space after a joined glyph is kept in the export, and its letters read once", arguments: gapPages)
    func wordSpaceAfterAJoinedGlyph(_ gap: GapPage) async throws {
        #expect(Self.gapPages.count == 8)
        let data = TestFixtures.joinedGlyphPDF(lines: gap.lines, encoding: gap.encoding, wordGaps: gap.wordGaps)
        let run = try await exportWithoutBoxes(data)
        defer { try? FileManager.default.removeItem(at: run.url) }
        #expect(run.outcome.perPageModes == [.searchableRedaction])
        let out = try #require(PDFDocument(url: run.url)?.page(at: 0)?.string)
        #expect(out == gap.exported, "\(gap): the export reads \(out.debugDescription)")
    }

    // MARK: - Boxes on part of a joined glyph

    enum Half: String, CaseIterable, Sendable { case left, right }

    @Test("A box on either half of a joined glyph takes every letter of it", arguments: Half.allCases)
    func boxOnHalfTakesTheGlyph(_ half: Half) async throws {
        let data = TestFixtures.joinedGlyphPDF(lines: Self.boxLines, wordGaps: true)
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        let size = page.bounds(for: .cropBox).size
        // Where each joined glyph is drawn, read by the walk as it shipped,
        // so the boxes do not depend on the walk under test. The joined
        // glyphs hold the page's only f, i and l.
        let shipped = try await WalkBeforeJoinedGlyphFix.extractCharacters(from: page)
        var glyphs: [CGRect] = []
        for entry in shipped where entry.character.contains(where: { "fil".contains($0) }) && !glyphs.contains(entry.bounds) {
            glyphs.append(entry.bounds)
        }
        try #require(glyphs.count == 5, "one glyph of each kind")
        let regions = glyphs.map { glyph in
            let x = half == .left ? glyph.minX + glyph.width * 0.1 : glyph.minX + glyph.width * 0.55
            let box = CGRect(x: x, y: glyph.minY + glyph.height * 0.3, width: glyph.width * 0.35, height: glyph.height * 0.4)
            return RedactionRegion(
                id: UUID(),
                normalizedRect: CGRect(x: box.minX / size.width, y: box.minY / size.height,
                                       width: box.width / size.width, height: box.height / size.height),
                source: .manual)
        }
        let run = try await TestPipeline.productionRun(data, mode: .searchableRedaction, regions: [0: regions])
        defer { try? FileManager.default.removeItem(at: run.url) }
        #expect(run.outcome.perPageModes == [.searchableRedaction])
        let out = try #require(PDFDocument(url: run.url)?.page(at: 0)?.string)
        #expect(!out.contains(where: { "fil".contains($0) }), "\(half) half: a letter of a boxed glyph remains in \(out.debugDescription)")
        #expect(Self.words(out).filter { $0 == "Box" }.count == 5, "\(half) half: the unboxed words remain")
    }
}
