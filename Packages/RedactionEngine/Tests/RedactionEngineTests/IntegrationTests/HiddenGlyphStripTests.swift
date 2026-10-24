import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import RedactionEngine

// A region over a hidden text layer strips its hidden glyphs' box as well as
// its own (`RedactionRegion.textLayerRect`): on a page whose text is an
// invisible layer over a picture of the page, the box a fill paints is the
// printed ink, and the hidden glyphs may sit beside it. A Searchable export
// removes the text layer under both boxes and paints the region's box alone.
// The page here keeps its layer: its hidden glyphs all sit on a textured band,
// so the hidden-text ink test reads every surviving glyph as inked and does not
// send the page image-only. That is the case the strip exists for: without it
// the hidden word's far glyphs would survive in the export's text layer.

@Suite("Hidden glyph strip")
struct HiddenGlyphStripTests {

    /// One page: a textured band (2 pt squares) behind a line set in an
    /// invisible render mode, "Keep Secret Words". No text on it shows ink.
    static func texturedHiddenLine() -> Data {
        texturedHiddenPage(bandRows: 690..<730, lines: [("Keep Secret Words", 700)])
    }

    /// A page of hidden lines (24 pt, at x 72, each at its baseline) over a
    /// textured band (2 pt squares) spanning `bandRows`, so every hidden glyph
    /// sits on content and the ink test keeps the layer.
    static func texturedHiddenPage(bandRows: Range<Int>, lines: [(text: String, baseline: Int)]) -> Data {
        var band = "0 g"
        for i in 0..<180 {
            for j in 0..<(bandRows.count / 2) where (i + j) % 2 == 0 {
                band += " \(60 + 2 * i) \(bandRows.lowerBound + 2 * j) 2 2 re"
            }
        }
        band += " f 3 Tr"
        let stream = lines.reduce(band) { $0 + " BT /F1 24 Tf 72 \($1.baseline) Td (\($1.text)) Tj ET" }
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
                + "/Resources << /Font << /F1 5 0 R >> >> >>",
            "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ]
        var out = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (i, object) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(i + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { out += String(format: "%010d 00000 n \n", offset) }
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(out.utf8)
    }

    /// The page, the hidden word's selection box (normalized), and a painted
    /// box over its left half: the ink the word names as a drifted layer
    /// leaves it, the word's last glyphs beyond the box and its margin.
    static func fixture() throws -> (doc: PDFDocument, page: PDFPage, strip: CGRect, paint: CGRect) {
        let doc = try #require(PDFDocument(data: texturedHiddenLine()))
        let page = try #require(doc.page(at: 0))
        let range = ((page.string ?? "") as NSString).range(of: "Secret")
        #expect(range.location != NSNotFound)
        let selection = try #require(page.selection(for: range))
        let strip = try #require(DocumentSearcher().normalizedRect(for: selection, page: page))
        let paint = CGRect(x: strip.minX, y: strip.minY, width: strip.width / 2, height: strip.height)
        return (doc, page, strip, paint)
    }

    static func pageData(_ page: PDFPage, _ regions: [RedactionRegion], mode: PipelineMode) -> PDFPageData {
        PDFPageData(
            page: page, pageIndex: 0, regions: regions, fillColor: .black, targetDPI: 300,
            pipelineMode: mode, rotation: page.rotation,
            cropBoxBounds: page.bounds(for: .cropBox), cgPage: page.pageRef,
            hasText: page.string?.isEmpty == false)
    }

    static func region(_ paint: CGRect, strip: CGRect?) -> RedactionRegion {
        RedactionRegion(id: UUID(), normalizedRect: paint, source: .searchMatch(term: "Secret"), textLayerRect: strip)
    }

    /// The surviving glyphs in page points, and the page's box rects in points.
    static func points(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * 612, y: rect.minY * 792, width: rect.width * 612, height: rect.height * 792)
    }

    /// Whether every pixel of a 12 × 12 px window centred on `point` (page
    /// points, bottom-left) is the black fill.
    static func isFilled(_ image: CGImage, at point: CGPoint) throws -> Bool {
        let w = image.width, h = image.height
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let buffer = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
        let cx = Int(point.x / 612 * CGFloat(w)), cy = Int(point.y / 792 * CGFloat(h))
        for y in (cy - 6)..<(cy + 6) {
            for x in (cx - 6)..<(cx + 6) {
                let p = buffer + (h - 1 - y) * w * 4 + x * 4
                if p[0] > 16 || p[1] > 16 || p[2] > 16 { return false }
            }
        }
        return true
    }

    @Test("a Searchable export strips the hidden glyphs' box and paints the region's box alone")
    func stripsHiddenGlyphsPaintsBoxAlone() async throws {
        let f = try Self.fixture()
        defer { withExtendedLifetime(f.doc) {} }
        let result = try await PageRasterizer().rasterize(
            Self.pageData(f.page, [Self.region(f.paint, strip: f.strip)], mode: .searchableRedaction))
        // The page keeps its text layer: the ink test does not mask the strip.
        #expect(result.fallbackReason == nil)
        let survivors = try #require(result.pageOutput.textLayerEntries)
        let text = survivors.map(\.character).joined()
        #expect(text.contains("Keep"))
        #expect(text.contains("Words"))
        let stripPoints = Self.points(f.strip)
        #expect(!survivors.contains { $0.bounds.intersects(stripPoints) },
                "a hidden glyph of the stripped word survived: \(text)")
        // The fill paints the region's box; the hidden glyphs' box beyond the
        // box and its growth keeps the page's own content.
        let paintPoints = Self.points(f.paint)
        #expect(try Self.isFilled(result.pageOutput.image, at: CGPoint(x: paintPoints.midX, y: paintPoints.midY)))
        #expect(try !Self.isFilled(result.pageOutput.image, at: CGPoint(x: paintPoints.maxX + 20, y: paintPoints.midY)))
    }

    @Test("without the hidden glyphs' box the drifted word's far glyphs survive in the text layer")
    func withoutStripFarGlyphsSurvive() async throws {
        let f = try Self.fixture()
        defer { withExtendedLifetime(f.doc) {} }
        let result = try await PageRasterizer().rasterize(
            Self.pageData(f.page, [Self.region(f.paint, strip: nil)], mode: .searchableRedaction))
        #expect(result.fallbackReason == nil)
        let survivors = try #require(result.pageOutput.textLayerEntries)
        let beyond = Self.points(f.paint).maxX + safetyMarginPoints
        let stripPoints = Self.points(f.strip)
        #expect(survivors.contains { $0.bounds.minX > beyond && $0.bounds.intersects(stripPoints) },
                "the fixture no longer leaves a glyph past the painted box; the strip test above proves nothing")
    }

    /// A two-line address over the band with a line after it: the hidden
    /// address lines' boxes united (the address's hidden glyphs' box), and a
    /// painted box over the left half of each line's box, united.
    static func addressFixture() throws -> (doc: PDFDocument, page: PDFPage, strip: CGRect, paint: CGRect) {
        let data = texturedHiddenPage(bandRows: 610..<740, lines: [
            ("4127 N. Wrenfield Pl", 700), ("Boise, ID 83702", 668), ("Account Summary", 620)])
        let doc = try #require(PDFDocument(data: data))
        let page = try #require(doc.page(at: 0))
        let text = (page.string ?? "") as NSString
        var strips: [CGRect] = [], paints: [CGRect] = []
        for line in ["4127 N. Wrenfield Pl", "Boise, ID 83702"] {
            let range = text.range(of: line)
            try #require(range.location != NSNotFound, "\(line) is on the page")
            let selection = try #require(page.selection(for: range))
            let box = try #require(DocumentSearcher().normalizedRect(for: selection, page: page))
            strips.append(box)
            paints.append(CGRect(x: box.minX, y: box.minY, width: box.width / 2, height: box.height))
        }
        return (doc, page, strips[0].union(strips[1]), paints[0].union(paints[1]))
    }

    @Test("an address's hidden glyphs' box strips both of its lines in a Searchable export; the line after it keeps its text")
    func addressStripRemovesBothLines() async throws {
        let f = try Self.addressFixture()
        defer { withExtendedLifetime(f.doc) {} }
        let region = RedactionRegion(id: UUID(), normalizedRect: f.paint, source: .detectedPII(kind: .address),
                                     textLayerRect: f.strip)
        let result = try await PageRasterizer().rasterize(Self.pageData(f.page, [region], mode: .searchableRedaction))
        #expect(result.fallbackReason == nil)
        let survivors = try #require(result.pageOutput.textLayerEntries)
        let text = survivors.map(\.character).joined()
        #expect(text.contains("Account"), "the line after the address keeps its text: \(text)")
        #expect(!survivors.contains { $0.bounds.intersects(Self.points(f.strip)) }, "an address glyph survived: \(text)")
    }

    @Test("without the address's hidden glyphs' box its lines' far glyphs survive in the text layer")
    func addressWithoutStripFarGlyphsSurvive() async throws {
        let f = try Self.addressFixture()
        defer { withExtendedLifetime(f.doc) {} }
        let region = RedactionRegion(id: UUID(), normalizedRect: f.paint, source: .detectedPII(kind: .address))
        let result = try await PageRasterizer().rasterize(Self.pageData(f.page, [region], mode: .searchableRedaction))
        #expect(result.fallbackReason == nil)
        let survivors = try #require(result.pageOutput.textLayerEntries)
        let beyond = Self.points(f.paint).maxX + safetyMarginPoints
        #expect(survivors.contains { $0.bounds.minX > beyond && $0.bounds.intersects(Self.points(f.strip)) },
                "the fixture no longer leaves an address glyph past the painted box; the test above proves nothing")
    }

    @Test("on a re-imported export the address hit carries its hidden glyphs' box and is painted clear of the next line")
    func addressHitOnReimportedExport() async throws {
        let (export, _) = try await PageImageInkFitTests.reimportedExport()
        let page = try #require(export.page(at: 0))
        var options = SearchOptions()
        options.includeOCR = false
        var hits: [SearchResult] = []
        for await result in DocumentSearcher().search(SendablePDFDocument(export),
                                                      mode: .piiScan(categories: [.address], options: options),
                                                      progress: { _, _ in }) where result.pageIndex == 0 {
            hits.append(result)
        }
        // The holder's address line the scan reports on the re-imported page.
        let hit = try #require(hits.first { $0.matchedText.contains("83702") }, "the address on page 1: \(hits.map(\.matchedText))")
        let strip = try #require(hit.textLayerRect, "the address carries its hidden glyphs' box")
        // Every hidden glyph of the address lies inside it.
        let text = (page.string ?? "") as NSString
        let searcher = DocumentSearcher()
        for word in ["Boise, ID 83702", "83702"] {
            let range = text.range(of: word)
            try #require(range.location != NSNotFound, "\(word) is in the hidden layer")
            let selection = try #require(page.selection(for: range))
            let box = try #require(searcher.normalizedRect(for: selection, page: page))
            #expect(strip.insetBy(dx: -0.0005, dy: -0.0005).contains(box), "\(word): \(box) outside \(strip)")
        }
        // The paint is the address's ink: it reaches no glyph of the line after it.
        let next = try #require(await PageImageInkFitTests.hits(export, "Account Summary", includeOCR: false)
            .first { $0.pageIndex == 0 })
        let overlap = hit.normalizedRect.intersection(next.normalizedRect)
        #expect(overlap.isNull || overlap.height * page.bounds(for: .cropBox).height < 0.5,
                "the address paint \(hit.normalizedRect) reaches the next line \(next.normalizedRect)")
    }

    @Test("a search over a stalled page read marks its results degraded with the drift envelope, and keeps none of it")
    func stalledFitMarksResultsDegraded() async throws {
        // An export of this test's own (two words redacted), so its page
        // content key is no other test's.
        let data = try TestFixtures.sampleStatementPDF()
        let source = try #require(PDFDocument(data: data))
        var regions: [Int: [RedactionRegion]] = [:]
        for hit in await PageImageInkFitTests.hits(source, "Sample", includeOCR: false)
            + (await PageImageInkFitTests.hits(source, "Summary", includeOCR: false)) {
            regions[hit.pageIndex, default: []].append(
                RedactionRegion(id: UUID(), normalizedRect: hit.normalizedRect, source: .manual))
        }
        let url = try await TestPipeline.processAndExport(data, mode: .searchableRedaction, regions: regions, dpi: 300)
        defer { try? FileManager.default.removeItem(at: url) }
        let export = try #require(PDFDocument(data: try Data(contentsOf: url)))
        let page = try #require(export.page(at: 0))
        let key = InkTokenCache.key(page: page, cgPage: try #require(page.pageRef), visual: page.bounds(for: .cropBox).size)
        DocumentSearcher.inkFitInjectedStalls.set((3.0, 0.5), for: key)
        let stalled = await PageImageInkFitTests.hits(export, "Hartwell", includeOCR: false).filter { $0.pageIndex == 0 }
        DocumentSearcher.inkFitInjectedStalls.set(nil, for: key)
        try #require(!stalled.isEmpty)
        let size = page.bounds(for: .cropBox).size
        for result in stalled {
            #expect(result.inkFitDegraded, "the result says its box is the drift envelope")
            let strip = try #require(result.textLayerRect)
            // The drift envelope at its smallest (the line's start, no wide
            // characters before it): the hidden glyphs' box grown by the drift
            // bound along the line and across it, on the page.
            let box = CGRect(x: strip.minX * size.width, y: strip.minY * size.height,
                             width: strip.width * size.width, height: strip.height * size.height)
            let grown = DocumentSearcher.driftBound(around: box)
                .intersection(CGRect(origin: .zero, size: size))
            let envelope = CGRect(x: grown.minX / size.width, y: grown.minY / size.height,
                                  width: grown.width / size.width, height: grown.height / size.height)
            #expect(result.normalizedRect.insetBy(dx: -1e-6, dy: -1e-6).contains(envelope),
                    "the degraded paint \(result.normalizedRect) covers the envelope \(envelope)")
        }
        // Nothing degraded was kept: once the stalled read is done, the same
        // search fits every box. The read's end is waited on, not timed.
        var fitted: [SearchResult] = []
        let deadline = Date().addingTimeInterval(30)
        repeat {
            try await Task.sleep(for: .milliseconds(500))
            fitted = await PageImageInkFitTests.hits(export, "Hartwell", includeOCR: false).filter { $0.pageIndex == 0 }
        } while fitted.contains(where: \.inkFitDegraded) && Date() < deadline
        #expect(fitted.count == stalled.count)
        #expect(fitted.allSatisfy { !$0.inkFitDegraded }, "a degraded box was served from a cache")
    }

    @Test("Secure output is the same with or without the hidden glyphs' box")
    func secureUnchanged() async throws {
        let f = try Self.fixture()
        defer { withExtendedLifetime(f.doc) {} }
        let with = try await PageRasterizer().rasterize(
            Self.pageData(f.page, [Self.region(f.paint, strip: f.strip)], mode: .secureRasterization))
        let without = try await PageRasterizer().rasterize(
            Self.pageData(f.page, [Self.region(f.paint, strip: nil)], mode: .secureRasterization))
        let a = try #require(with.pageOutput.image.dataProvider?.data) as Data
        let b = try #require(without.pageOutput.image.dataProvider?.data) as Data
        #expect(a == b)
        #expect(with.pageOutput.textLayerEntries == nil)
    }

    @Test("a region with no hidden glyphs' box strips under its own box alone")
    func nilStripIsTheBoxAlone() async throws {
        let f = try Self.fixture()
        defer { withExtendedLifetime(f.doc) {} }
        let region = Self.region(f.paint, strip: nil)
        #expect(region.textRemovalRects == [f.paint])
        #expect(Self.region(f.paint, strip: f.strip).textRemovalRects == [f.paint, f.strip])
        let result = try await PageRasterizer().rasterize(Self.pageData(f.page, [region], mode: .searchableRedaction))
        let bounds = CGRect(origin: .zero, size: f.page.bounds(for: .cropBox).size)
        #expect(result.pageOutput.redactionRectsInPoints == [normalizedToPDFPageCoordinates(f.paint, pageRect: bounds)])
    }

    @Test("an encoded region without the hidden glyphs' box has no key for it and decodes as nil")
    func codable() throws {
        let plain = RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.04), source: .manual)
        let encoded = try JSONEncoder().encode(plain)
        #expect(!(String(data: encoded, encoding: .utf8) ?? "").contains("textLayerRect"))
        #expect(try JSONDecoder().decode(RedactionRegion.self, from: encoded) == plain)
        let stripped = RedactionRegion(id: UUID(), normalizedRect: plain.normalizedRect, source: .searchMatch(term: "x"),
                                       textLayerRect: CGRect(x: 0.12, y: 0.19, width: 0.3, height: 0.04))
        #expect(try JSONDecoder().decode(RedactionRegion.self, from: JSONEncoder().encode(stripped)) == stripped)
    }

    @Test("an earlier Searchable export re-imported goes image-only in a Searchable export (the ink test)")
    func reimportedExportFallsBack() async throws {
        let (export, _) = try await PageImageInkFitTests.reimportedExport()
        let page = try #require(export.page(at: 0))
        let result = try await PageRasterizer().rasterize(Self.pageData(page, [], mode: .searchableRedaction))
        #expect(result.fallbackReason == .hiddenText)
        #expect(result.pageOutput.textLayerEntries == nil)
    }
}
