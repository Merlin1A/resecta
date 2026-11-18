import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import RedactionEngine

// The hidden text's alphabet on real exports: each alphabet page is exported
// through the production page loop and read back. A page that stays
// Searchable has only accepted fonts, holds exactly its written runs (folded,
// with nothing the hidden text never holds), carries its count of runs left
// out, and passes Character Count and Character Lineage. A page the alphabet
// rule leaves with no word is a picture with its reason and its count; a page
// whose every word is under a box stays Searchable with an empty hidden text,
// as before; the right-to-left control is a picture, as before. All text is
// invented.

@Suite("The hidden text's alphabet on exports", .serialized)
struct HiddenTextAlphabetExportTests {

    static let pages = TestFixtures.hiddenTextAlphabetPages

    @Test("The alphabet pages are thirteen")
    func pageCount() {
        #expect(Self.pages.count == 13)
    }

    // MARK: - Helpers

    /// A source run as the hidden text writes it: each joined-letter code
    /// point as its letters.
    static func folded(_ run: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in run.unicodeScalars {
            if let letters = TestFixtures.joinedGlyphLetters[scalar] {
                scalars.append(contentsOf: letters.unicodeScalars)
            } else {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// A page's runs as its lines are authored: text between spaces, the
    /// object mark a break between runs and never a run of its own.
    static func runs(of page: HiddenTextAlphabetPage) -> [String] {
        page.lines.flatMap { $0.split(separator: " ") }
            .flatMap { $0.split(separator: Character(Unicode.Scalar(NeverWrittenCharacters.objectMark))) }
            .map(String.init)
    }

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
    }

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

    /// The page's one result from the rasterizer, as the production loop
    /// takes it: its output carries the count of runs left out.
    static func rasterized(_ data: Data, regions: [RedactionRegion]) async throws -> RasterizeResult {
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        let pageData = PDFPageData(
            page: page, pageIndex: 0, regions: regions,
            fillColor: .black, targetDPI: 150, pipelineMode: .searchableRedaction,
            rotation: page.rotation, hasHiddenOCG: false,
            cropBoxBounds: page.bounds(for: .cropBox), cgPage: page.pageRef,
            hasText: true)
        return try await PageRasterizer().rasterize(pageData, dpiCap: 300)
    }

    // MARK: - Every page, exported

    @Test("Each alphabet page exports as its hand list says", arguments: pages)
    func exportsAsListed(_ page: HiddenTextAlphabetPage) async throws {
        let data = page.data
        let regions = try page.boxed.map { try Self.box(around: $0, in: data) }
        let run = try await TestPipeline.productionRun(data, mode: .searchableRedaction, regions: [0: regions])
        defer { try? FileManager.default.removeItem(at: run.url) }
        let result = try await Self.rasterized(data, regions: regions)
        guard let leftOut = page.leftOut else {
            // The right-to-left control: a picture before and after.
            #expect(run.outcome.perPageModes == [.secureRasterization], "\(page.name)")
            #expect(run.outcome.perPageFallbackReasons == [.rtlText], "\(page.name): \(run.outcome.perPageFallbackReasons)")
            return
        }
        let written = Self.runs(of: page).filter { !leftOut.contains($0) && !page.boxed.contains($0) }.map(Self.folded)
        #expect(result.pageOutput.runsLeftOut == leftOut.count, "\(page.name): runs left out \(result.pageOutput.runsLeftOut)")
        if written.isEmpty && !leftOut.isEmpty {
            #expect(run.outcome.perPageModes == [.secureRasterization], "\(page.name): a picture")
            #expect(run.outcome.perPageFallbackReasons == [.noWritableText], "\(page.name): \(run.outcome.perPageFallbackReasons)")
            return
        }
        #expect(run.outcome.perPageModes == [.searchableRedaction], "\(page.name): the page stays Searchable")
        #expect(run.outcome.perPageFallbackReasons == [nil], "\(page.name): \(run.outcome.perPageFallbackReasons)")
        let document = try #require(PDFDocument(url: run.url))
        let output = try #require(document.page(at: 0))
        let text = output.string ?? ""
        #expect(Self.words(text).sorted() == written.sorted(), "\(page.name): the hidden text reads \(text.debugDescription)")
        let held = text.unicodeScalars.filter { scalar in
            !Character(scalar).isWhitespace && NeverWrittenCharacters.contains(scalar)
        }
        #expect(held.isEmpty, "\(page.name): never-written characters in the hidden text: \(held.map { String(format: "U+%04X", $0.value) })")
        guard !written.isEmpty else {
            #expect(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(page.name): an empty hidden text")
            return
        }
        let verifier = SandwichVerification()
        let digest = try #require(run.outcome.filterDigests.first ?? nil)
        #expect(try await verifier.verifyFontsAreMonospace(outputPage: output, pageIndex: 0) == .pass, "\(page.name): fonts")
        #expect(try await verifier.verifyCharacterCount(outputPage: output, digest: digest) == .pass, "\(page.name): Character Count")
        #expect(try await verifier.verifyCharacterLineage(outputPage: output, digest: digest) == .pass, "\(page.name): Character Lineage")
    }

    // MARK: - Break marks, gone from the hidden text itself

    static let markLines: [(name: String, lines: [String], mark: String)] = [
        ("a soft hyphen inside a word", ["Pay\u{00AD}ment due today"], "00AD"),
        ("a zero-width joiner inside a word", ["Co\u{200D}op fund report"], "200D"),
    ]

    /// Every code a font of the page maps to text, as its ToUnicode map
    /// writes it: what any reader that returns such marks reads.
    static func mappedText(_ page: PDFPage) throws -> String {
        let pageRef = try #require(page.pageRef)
        var resources: CGPDFDictionaryRef?
        var fonts: CGPDFDictionaryRef?
        guard let dictionary = pageRef.dictionary,
              CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources,
              CGPDFDictionaryGetDictionary(resources, "Font", &fonts), let fonts else { return "" }
        final class Box: @unchecked Sendable { var maps: [String] = [] }
        let box = Box()
        CGPDFDictionaryApplyBlock(fonts, { _, object, _ in
            var font: CGPDFDictionaryRef?
            var stream: CGPDFStreamRef?
            if CGPDFObjectGetValue(object, .dictionary, &font), let font,
               CGPDFDictionaryGetStream(font, "ToUnicode", &stream), let stream {
                var format = CGPDFDataFormat.raw
                if let data = CGPDFStreamCopyData(stream, &format) {
                    box.maps.append(String(decoding: data as Data, as: UTF8.self))
                }
            }
            return true
        }, nil)
        return box.maps.joined(separator: "\n")
    }

    @Test("A soft hyphen or a joiner inside a word is not in the export's hidden text, and both rows pass",
          arguments: [0, 1])
    func marksAreNotWritten(_ index: Int) async throws {
        let row = Self.markLines[index]
        let data = TestFixtures.joinedGlyphPDF(lines: row.lines, wordGaps: true)
        let run = try await TestPipeline.productionRun(data, mode: .searchableRedaction, regions: [0: []])
        defer { try? FileManager.default.removeItem(at: run.url) }
        #expect(run.outcome.perPageModes == [.searchableRedaction], "\(row.name)")
        let document = try #require(PDFDocument(url: run.url))
        let output = try #require(document.page(at: 0))
        let maps = try Self.mappedText(output)
        try #require(maps.contains("beginbfchar") || maps.contains("beginbfrange"), "\(row.name): the export's fonts carry text maps")
        #expect(!maps.uppercased().contains("<\(row.mark)>"), "\(row.name): U+\(row.mark) is mapped in the export")
        let digest = try #require(run.outcome.filterDigests.first ?? nil)
        let verifier = SandwichVerification()
        #expect(try await verifier.verifyCharacterCount(outputPage: output, digest: digest) == .pass, "\(row.name)")
        #expect(try await verifier.verifyCharacterLineage(outputPage: output, digest: digest) == .pass, "\(row.name)")
    }

    // MARK: - An emoji draws no image in the hidden text

    /// The image objects of a file that are not another image's soft mask.
    static func imageCount(_ url: URL) throws -> Int {
        let bytes = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        let images = bytes.components(separatedBy: "/Subtype /Image").count - 1
        let masks = bytes.components(separatedBy: "/SMask ").count - 1
        return images - masks
    }

    @Test("A page with emoji draws as many images Searchable as Secure")
    func emojiDrawsNoImage() async throws {
        let page = try #require(Self.pages.first { $0.name.hasPrefix("emoji") })
        let searchable = try await TestPipeline.productionRun(page.data, mode: .searchableRedaction, regions: [0: []])
        defer { try? FileManager.default.removeItem(at: searchable.url) }
        let secure = try await TestPipeline.productionRun(page.data, mode: .secureRasterization, regions: [0: []])
        defer { try? FileManager.default.removeItem(at: secure.url) }
        #expect(searchable.outcome.perPageModes == [.searchableRedaction])
        let counts = (try Self.imageCount(searchable.url), try Self.imageCount(secure.url))
        #expect(counts.1 >= 1, "the Secure page is one image")
        #expect(counts.0 == counts.1, "Searchable \(counts.0) images, Secure \(counts.1)")
    }
}
