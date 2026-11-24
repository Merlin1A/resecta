import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

// The hybrid leg's dedup: an OCR line result that repeats a text-layer result
// is dropped, whatever the text-layer box's size. A page read too slowly gets
// the drift envelope (taller than its line, centred where the word should be);
// judged on overlap alone, the envelope missed the line's OCR result, which
// then came back as an extra whole-line hit, so a search reported more under load.

@Suite("Hybrid leg dedup", .tags(.search))
struct HybridDedupTests {

    /// A recognised line and an OCR result on it.
    static let line = CGRect(x: 0.0569, y: 0.9437, width: 0.6062, height: 0.0167)
    static func ocr(_ rect: CGRect = line) -> SearchResult {
        SearchResult(pageIndex: 0, normalizedRect: rect, matchedText: "Delia", contextSnippet: "Delia",
                     source: .ocr(confidence: 1), term: "delia")
    }
    /// The drift envelope of a word on that line: taller than the line, centred on it,
    /// with under half of itself on the line.
    static let envelope = CGRect(x: 0.0, y: 0.9304, width: 0.1636, height: 0.0379)
    /// A word's ink on that line, further along.
    static let word = CGRect(x: 0.40, y: 0.9460, width: 0.04, height: 0.0120)

    @Test("an envelope centred on the line repeats the line's OCR result, though under half of it overlaps")
    func envelopeRepeatsItsLine() {
        let overlap = Self.envelope.intersection(Self.line)
        #expect(overlap.width * overlap.height < 0.5 * Self.envelope.width * Self.envelope.height,
                "the fixture is the case the overlap rule alone missed")
        #expect(DocumentSearcher.mergeHybridResults(textLayerRects: [Self.envelope], ocr: [Self.ocr()]).isEmpty)
    }

    @Test("each text-layer box accounts for one OCR result: a second occurrence the text layer lacks keeps its own")
    func oneToOne() {
        let two = [Self.ocr(), Self.ocr()]
        #expect(DocumentSearcher.mergeHybridResults(textLayerRects: [Self.envelope], ocr: two).count == 1,
                "one occurrence on the line in the text layer, two read: the second keeps its OCR result")
        #expect(DocumentSearcher.mergeHybridResults(textLayerRects: [Self.envelope, Self.word], ocr: two).isEmpty,
                "both occurrences in the text layer: both OCR results repeat them")
    }

    @Test("an OCR result no text-layer box sits on is kept; a page with no text layer keeps every one")
    func unrelatedAndScanned() {
        let elsewhere = CGRect(x: 0.10, y: 0.50, width: 0.05, height: 0.012)
        #expect(DocumentSearcher.mergeHybridResults(textLayerRects: [elsewhere], ocr: [Self.ocr()]).count == 1)
        #expect(DocumentSearcher.mergeHybridResults(textLayerRects: [], ocr: [Self.ocr(), Self.ocr()]).count == 2)
    }

    @Test("a search with recognition on reports the same results when every page read stalls as when none does")
    func sameResultsUnderAStall() async throws {
        // An export of this test's own: two words redacted and a small mark in
        // a blank corner of every page. The page content key is the page's text
        // and image, so without the mark a page with neither word carries the
        // shared re-imported export's key, and this test's stalls reach its readers.
        let data = try TestFixtures.sampleStatementPDF()
        let source = try #require(PDFDocument(data: data))
        var regions: [Int: [RedactionRegion]] = [:]
        for index in 0..<source.pageCount {
            regions[index] = [RedactionRegion(id: UUID(), normalizedRect: Self.mark, source: .manual)]
        }
        for hit in await PageImageInkFitTests.hits(source, "Sample", includeOCR: false)
            + (await PageImageInkFitTests.hits(source, "Balance", includeOCR: false)) {
            regions[hit.pageIndex, default: []].append(
                RedactionRegion(id: UUID(), normalizedRect: hit.normalizedRect, source: .manual))
        }
        let url = try await TestPipeline.processAndExport(data, mode: .searchableRedaction, regions: regions, dpi: 300)
        defer { try? FileManager.default.removeItem(at: url) }
        let export = try #require(PDFDocument(data: try Data(contentsOf: url)))
        let keys = try Self.pageKeys(export)
        let shared = try Self.pageKeys(try await PageImageInkFitTests.reimportedExport().export)
        try #require(Set(keys).isDisjoint(with: shared), "a stalled page shares its key with the shared re-imported export")
        // Stalled first, before anything on these pages is read or cached.
        for key in keys { DocumentSearcher.inkFitInjectedStalls.set((6.0, 0.2), for: key) }
        let stalled = await PageImageInkFitTests.hits(export, "delia", includeOCR: true)
        for key in keys { DocumentSearcher.inkFitInjectedStalls.set(nil, for: key) }
        #expect(stalled.contains { $0.inkFitDegraded }, "the stall degraded the fits")
        #expect(stalled.count == 9 && stalled.allSatisfy { $0.source == .textLayer },
                "stalled: \(stalled.map { "\($0.source) p\($0.pageIndex + 1)" })")
        try await Task.sleep(for: .seconds(8))   // the stalled reads finish
        let normal = await PageImageInkFitTests.hits(export, "delia", includeOCR: true)
        #expect(normal.count == 9 && normal.allSatisfy { $0.source == .textLayer })
    }

    /// The corner mark, clear of the corner the stall pins mark.
    static let mark = CGRect(x: 0.012, y: 0.030, width: 0.020, height: 0.010)

    /// Each page's ink-fit content key.
    static func pageKeys(_ doc: PDFDocument) throws -> [Int] {
        try (0..<doc.pageCount).map { index in
            let page = try #require(doc.page(at: index))
            return InkTokenCache.key(page: page, cgPage: try #require(page.pageRef), visual: page.bounds(for: .cropBox).size)
        }
    }

    /// The places a hybrid page's text-layer results reach the merge, by file:
    /// the hybrid leg's callers, each passing the box a match is told by
    /// (`mergeIdentity`: the identity box where the paint grew past it, else
    /// the paint), or a list built only of it. A new caller fails this pin
    /// until it is named here.
    static let hybridLegCallers = ["DocumentSearcher+TextModes.swift": 4, "DocumentSearcher+PIIScan.swift": 1]
    /// The text-layer results made from a fitted box, by file: each carries
    /// the box's identity (`identified(by:)`).
    static let identifiedResults = ["DocumentSearcher+TextMatches.swift": 1, "DocumentSearcher+TextModes.swift": 1,
                                    "DocumentSearcher+PIIScan.swift": 3, "DocumentSearcher+PageSeam.swift": 1]

    /// Each call that starts with `head` in `text`, to its matching closing parenthesis.
    static func calls(of head: String, in text: String) -> [String] {
        var found: [String] = [], rest = text[...]
        while let start = rest.range(of: head) {
            var depth = 0, end = start.lowerBound
            for index in rest[start.lowerBound...].indices {
                let character = rest[index]
                if character == "(" { depth += 1 } else if character == ")" { depth -= 1; if depth == 0 { end = index; break } }
            }
            guard end > start.lowerBound else { break }
            found.append(String(rest[start.lowerBound...end]))
            rest = rest[rest.index(after: end)...]
        }
        return found
    }

    @Test("Every hybrid merge tells a text-layer match by its identity, never by a paint grown past it: each caller and each result named")
    func identityAtEveryMergeInput() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/RedactionEngine")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        try #require(files.count > 100, "the engine's sources are read")
        var callers: [String: Int] = [:], made: [String: Int] = [:], identified: [String: Int] = [:]
        var mergeCalls = 0, texts: [String: String] = [:], fitted: [String: Int] = [:]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let name = file.lastPathComponent
            texts[name] = text
            for line in text.components(separatedBy: "\n") {
                if line.contains("mergeHybridResults(textLayerRects:"), !line.contains("func ") {
                    mergeCalls += 1
                    #expect(name == "DocumentSearcher+HybridRoute.swift" && line.contains("textLayerRects: textLayerRects"),
                            "\(name): a merge outside the hybrid leg: \(line)")
                }
                if line.contains("hybridOCRLeg("), !line.contains("func ") {
                    callers[name, default: 0] += 1
                    let passes = line.contains("textLayerRects: results.map(\\.mergeIdentity)")
                        || line.contains("textLayerRects: hits.map(\\.mergeIdentity)")
                        || line.contains("textLayerRects: pageRects")
                    #expect(passes, "\(name): a hybrid caller that does not pass mergeIdentity: \(line)")
                }
                if line.contains("pageRects.append") {
                    #expect(line.contains("pageRects.append(box.mergeIdentity)")
                                || line.contains("pageRects.append(contentsOf: rects.map(\\.mergeIdentity))"),
                            "\(name): the merge's list takes another box: \(line)")
                }
                // A result made from a fitted text-layer box (its hidden glyphs' box rides on it).
                if line.contains("textLayerRect: line.textLayerRect") || line.contains("textLayerRect: box.textLayerRect") {
                    made[name, default: 0] += 1
                }
                if line.contains(".identified(by: line.identity)") || line.contains(".identified(by: box.identity)") {
                    identified[name, default: 0] += 1
                }
            }
            // A text-layer box from a fit names its identity; one with no hidden
            // glyphs' box had no fit. Each made whole, to its closing parenthesis.
            for call in Self.calls(of: "TextLayerBox(rect:", in: text) where !call.contains("textLayerRect: nil") {
                fitted[name, default: 0] += 1
                #expect(call.contains("identity:"), "\(name): a fitted text-layer box without its identity: \(call)")
            }
        }
        #expect(mergeCalls == 1, "the merge is called once, from the hybrid leg: \(mergeCalls)")
        #expect(callers == Self.hybridLegCallers, "hybrid leg callers \(callers)")
        #expect(made == Self.identifiedResults, "text-layer results from a fitted box \(made)")
        #expect(identified == Self.identifiedResults, "results that carry their identity \(identified)")
        #expect(fitted == ["DocumentSearcher+TextLayerStrip.swift": 2, "DocumentSearcher+ScanGate.swift": 1],
                "text-layer boxes made from a fit \(fitted)")
        // The address lines, fitted whole: their identity rides into the assembled union and its box.
        #expect(texts["EmbeddedTextSource.swift"]?.contains("identityRect: fit.identity") == true, "an address line carries its identity")
        // An address line grown to its own glyphs keeps the identity it had: Scan grows it
        // through the line's own copy, which carries the box before the growth as identity.
        #expect(texts["DocumentSearcher+ScanGate.swift"]?.contains("return line.grown(to: rect)") == true,
                "Scan grows an address line through its identity-keeping copy")
        #expect(texts["OCREngine.swift"]?.contains("identityRect: identityRect ?? normalizedRect") == true,
                "a grown line keeps its identity")
        #expect(texts["DocumentSearcher+ScanGate.swift"]?.contains("identity: address.identityUnionRect)") == true,
                "an assembled address's box carries its lines' identities")
    }
}
