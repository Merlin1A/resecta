import Testing
import Foundation
import CoreGraphics
import CoreText
import PDFKit
@testable import ResectaApp
@testable import RedactionEngine

// On a scanned page whose text is an invisible layer drifted along the line
// from its print, a box strips the hidden copies of the words whose printed
// ink it covers, wherever they sit, and the page keeps its text layer: a box
// drawn by hand over a name, and one on a first word narrower than the drift.
// The hand-box capture names the boxed words, not the words whose hidden
// copies drifted under the box. A box on a line where some word's print could
// not be placed with confidence ("Signed by Lee on the date below." on this
// page) sends the page to the image-only floor instead, with its reason and no
// hidden text: a box on a short word, a Search box widened by hand, and a box
// on the line's first word. Driven through the run's own entry
// (`PipelineRunner.captureRunEntry`) and the rasterizer.

@Suite("Strip by ink at run entry", .serialized, .tags(.coordination))
@MainActor
struct InkStripRunEntryTests {

    static let lines: [String] = [
        "The review below covers the second quarter of the year.",
        "Each section lists the work done and the work still open.",
        "Items marked done were checked against the original plan.",
        "Items still open carry a short note on what they wait for.",
        "Questions about this review go to the office named here.",
        "Contact Marisol Vance-Oduya about the file today.",
        "The file holds the plan, the notes and the final summary.",
        "Copies of the summary were sent to each team last week.",
        "Each team read the summary and answered within five days.",
        "The answers are kept with the file for the next review.",
        "Nothing in this review changes the plan for next quarter.",
        "Signed by Lee on the date below.",
        "The next review is planned for the start of next quarter.",
        "It will follow the same order as this one and the last.",
        "Each team will be asked for its notes two weeks before.",
        "The office will send a short reminder one week before.",
        "Late notes are added to the file when they arrive.",
        "The summary is shared once all notes are in the file.",
        "Teams may ask for a short meeting after the summary.",
        "Meetings are held in the main room unless noted.",
        "A record of each meeting is added to the same file.",
        "The file is kept for three years after the review.",
        "After three years the file moves to the long store.",
        "This page ends the review for the second quarter.",
    ]
    static let fontSize: CGFloat = 14
    static let left: CGFloat = 72
    static func baseline(_ i: Int) -> CGFloat { 730 - 22 * CGFloat(i) }

    static func ctLine(_ text: String) -> CTLine {
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributes = [kCTFontAttributeName as String: font] as CFDictionary
        return CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attributes)!)
    }

    static func inkRect(line i: Int, phrase: String, through last: String? = nil) -> CGRect {
        let text = lines[i], line = ctLine(text), ns = text as NSString
        let start = ns.range(of: phrase), end = last.map { ns.range(of: $0) } ?? start
        let x0 = CTLineGetOffsetForStringIndex(line, start.location, nil)
        let x1 = CTLineGetOffsetForStringIndex(line, end.location + end.length, nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let r = CGRect(x: left + x0, y: baseline(i) - descent, width: x1 - x0, height: ascent + descent)
        return CGRect(x: r.minX / 612, y: r.minY / 792, width: r.width / 612, height: r.height / 792)
    }

    static func seededPage(drift: CGFloat) -> Data {
        let w = 1275, h = 1650
        var pixels = [UInt8](repeating: 0, count: w * h)
        var state: UInt64 = 20_261_105
        for k in 0..<(w * h) {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z ^= z >> 31
            pixels[k] = UInt8(150 + Int(z % 81))
        }
        pixels.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.scaleBy(x: CGFloat(w) / 612, y: CGFloat(h) / 792)
            ctx.setFillColor(gray: 0.05, alpha: 1)
            ctx.textMatrix = .identity
            for (i, text) in lines.enumerated() {
                ctx.textPosition = CGPoint(x: left, y: baseline(i))
                CTLineDraw(ctLine(text), ctx)
            }
        }
        let hex = Array("0123456789ABCDEF".utf8)
        var body = Data(capacity: w * h * 2 + 2)
        for p in pixels { body.append(hex[Int(p >> 4)]); body.append(hex[Int(p & 0xF)]) }
        body.append(contentsOf: Array(">".utf8))
        var stream = "q 612 0 0 792 0 0 cm /Im1 Do Q\n"
        for (i, text) in lines.enumerated() {
            stream += "BT 3 Tr /F1 \(Int(fontSize)) Tf \(left + drift) \(baseline(i)) Td (\(text)) Tj ET\n"
        }
        var objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data(("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
                  + "/Resources << /Font << /F1 5 0 R >> /XObject << /Im1 6 0 R >> >> >>").utf8),
            Data("<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream".utf8),
            Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>".utf8),
        ]
        var image = Data(("<< /Type /XObject /Subtype /Image /Width \(w) /Height \(h) /ColorSpace /DeviceGray "
                          + "/BitsPerComponent 8 /Filter /ASCIIHexDecode /Length \(body.count) >>\nstream\n").utf8)
        image.append(body); image.append(Data("\nendstream".utf8))
        objects.append(image)
        var pdf = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        for (i, object) in objects.enumerated() {
            offsets.append(pdf.count)
            pdf.append(Data("\(i + 1) 0 obj\n".utf8)); pdf.append(object); pdf.append(Data("\nendobj\n".utf8))
        }
        let xref = pdf.count
        var tail = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { tail += String(format: "%010d 00000 n \n", offset) }
        tail += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        pdf.append(Data(tail.utf8))
        return pdf
    }


    static let seeded = seededPage(drift: 30)

    static func coordinator() throws -> PipelineCoordinator {
        let coord = makeCoordinator()
        coord.documentState.sourceDocument = try #require(PDFDocument(data: seeded))
        coord.documentState.textLayerStatus = [0: .rich]
        coord.documentState.phase = .editing
        return coord
    }

    static func hiddenBox(_ page: PDFPage, _ word: String) -> CGRect? {
        let range = ((page.string ?? "") as NSString).range(of: word)
        guard range.location != NSNotFound, let sel = page.selection(for: range),
              let n = DocumentSearcher().normalizedRect(for: sel, page: page) else { return nil }
        return CGRect(x: n.minX * 612, y: n.minY * 792, width: n.width * 612, height: n.height * 792)
    }

    /// The run entry in a Searchable run, the page's rasterization, the
    /// surviving glyphs inside `covered`'s hidden box, and every glyph the
    /// output page still carries.
    static func run(_ coord: PipelineCoordinator, covered: String) async throws
        -> (page: PDFPageData, survivors: String, terms: [String], glyphs: Int) {
        let entry = try await PipelineRunner.captureRunEntry(
            coordinator: coord, effectiveMode: .searchableRedaction,
            runSettings: .snapshot(from: coord.settingsState)
        ) { await coord.collectSensitiveTermSet() }
        let page = try #require(entry.pages.first)
        let source = try #require(coord.documentState.sourceDocument?.page(at: 0))
        let box = try #require(hiddenBox(source, covered))
        let raster = try await PageRasterizer().rasterize(page)
        let left = (raster.pageOutput.textLayerEntries ?? []).filter {
            $0.bounds.intersects(box) && !$0.character.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return (page, left.map(\.character).joined(), entry.sensitiveTerms.terms.map(\.text),
                raster.pageOutput.textLayerEntries?.count ?? 0)
    }

    static func expectKeptAndStripped(_ r: (page: PDFPageData, survivors: String, terms: [String], glyphs: Int),
                                      _ comment: Comment) {
        #expect(r.page.pipelineMode == .searchableRedaction, comment)
        #expect(r.page.fallbackReason == nil, comment)
        #expect(r.glyphs > 0, "\(comment): the page keeps its text layer")
        #expect(r.survivors.isEmpty, "\(comment): the boxed word's hidden copy survived: \(r.survivors)")
    }

    static func expectFloor(_ r: (page: PDFPageData, survivors: String, terms: [String], glyphs: Int),
                            _ comment: Comment) {
        #expect(r.page.pipelineMode == .secureRasterization, comment)
        #expect(r.page.fallbackReason == .unanchoredRegion, "\(comment): \(String(describing: r.page.fallbackReason))")
        #expect(r.glyphs == 0, "\(comment): an image-only page carries no hidden text")
    }

    static func hand(_ rect: CGRect) -> RedactionRegion { RedactionRegion(id: UUID(), normalizedRect: rect, source: .manual) }

    @Test("a hand-drawn box over a name keeps the page and strips the name's hidden copy beside it")
    func handBoxOnName() async throws {
        let coord = try Self.coordinator()
        coord.redactionState.addRegion(Self.hand(Self.inkRect(line: 5, phrase: "Marisol", through: "Vance-Oduya")),
                                       page: 0, undoManager: nil)
        let r = try await Self.run(coord, covered: "Marisol Vance-Oduya")
        Self.expectKeptAndStripped(r, "hand box on the name")
        #expect(r.terms.contains("Marisol") || r.terms.contains("Marisol Vance-Oduya"), "the capture names the boxed name: \(r.terms)")
        #expect(!r.terms.contains("Contact"), "the capture does not name the neighbour whose hidden copy drifted under the box: \(r.terms)")
    }

    @Test("a hand-drawn box over a short word on a line with an uncertain word sends the page to the floor")
    func handBoxOnShortWord() async throws {
        let coord = try Self.coordinator()
        coord.redactionState.addRegion(Self.hand(Self.inkRect(line: 11, phrase: "Lee")), page: 0, undoManager: nil)
        Self.expectFloor(try await Self.run(coord, covered: "Lee"), "hand box on a short word")
    }

    @Test("a Search box widened by hand on a line with an uncertain word sends the page to the floor")
    func widenedSearchBox() async throws {
        let coord = try Self.coordinator()
        let page = try #require(coord.documentState.sourceDocument?.page(at: 0))
        let range = ((page.string ?? "") as NSString).range(of: "Signed")
        let selection = try #require(page.selection(for: range))
        let strip = try #require(DocumentSearcher().normalizedRect(for: selection, page: page))
        let result = SearchResult(pageIndex: 0, normalizedRect: Self.inkRect(line: 11, phrase: "Signed"), matchedText: "Signed",
                                  contextSnippet: "… Signed …", source: .textLayer, term: "signed", isSelected: true,
                                  piiCategory: nil, textLayerRect: strip)
        let prepared = prepareApply(selected: [result], existingRectsByPage: [:], existingStripRectsByPage: [:],
                                    appliedAt: Date(), searchRecord: nil)
        for region in prepared.createdRegions[0] ?? [] { coord.redactionState.addRegion(region, page: 0, undoManager: nil) }
        let id = try #require(coord.redactionState.regions[0]?.first?.id)
        _ = coord.redactionState.resizeRegion(id, page: 0, newRect: Self.inkRect(line: 11, phrase: "Signed", through: "Lee"),
                                              undoManager: nil)
        Self.expectFloor(try await Self.run(coord, covered: "Lee"), "widened Search box")
    }

    @Test("a hand-drawn box on the first word of a line with an uncertain word sends the page to the floor")
    func handBoxOnFirstWord() async throws {
        let coord = try Self.coordinator()
        coord.redactionState.addRegion(Self.hand(Self.inkRect(line: 11, phrase: "Signed")), page: 0, undoManager: nil)
        Self.expectFloor(try await Self.run(coord, covered: "Signed"), "hand box on the first word")
    }

    @Test("a hand-drawn box on a first word narrower than the drift strips its hidden copy")
    func handBoxOnNarrowFirstWord() async throws {
        let coord = try Self.coordinator()
        coord.redactionState.addRegion(Self.hand(Self.inkRect(line: 0, phrase: "The")), page: 0, undoManager: nil)
        Self.expectKeptAndStripped(try await Self.run(coord, covered: "The"), "hand box on a narrow first word")
    }
}
