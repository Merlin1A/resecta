import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import RedactionEngine

/// Exported, measured as the pixels of the match's own ink: dark when the
/// match is drawn alone, white when the page is drawn without it. After a
/// search's box is applied and the page exported, none of those pixels may
/// stay dark outside the paint, in Secure or in Searchable.
@Suite("Exported: a match's own ink under its paint", .serialized)
struct ContentGlyphExportTests {
    static let next = " BT /F1 12 Tf 72 680 Td (Next line) Tj ET"
    static let plant = " BT /F1 12 Tf 0 0 0 0 72 700 Tm (QUARTZ7) Tj ET"

    struct Case: CustomStringConvertible, Sendable {
        let label: String, term: String, full: String, alone: String, without: String
        /// The band the match's ink is read in, in points.
        let x0: CGFloat, x1: CGFloat
        /// Letters of other words the Searchable layer drops beside the
        /// match: as on main, except where a grown box meets a neighbour's
        /// glyph (the TJ case: "ce" on main, "ceio" here, named in what may
        /// move).
        let dropped: [Character]
        var description: String { label }
    }

    static let cases: [Case] = [
        Case(label: "the line's last word, its t past PDFKit's box", term: "account",
             full: ContentGlyphWalkTests.visible + plant,
             alone: "BT /F1 12 Tf 218.064 700 Td (account) Tj ET",
             without: "BT /F1 12 Tf 72 700 Td (Quarterly statement for the ) Tj ET" + plant,
             x0: 150, x1: 280, dropped: Array("Qaeeefhmnorstttt")),
        Case(label: "a TJ that draws Total back over oice", term: "Total",
             full: "BT /F1 12 Tf 72 700 Td [(Inv) -250 (oice) 1200 (Total) -500 (due)] TJ ET" + next,
             alone: "BT /F1 12 Tf 98.616 700 Td (Total) Tj ET",
             without: "BT /F1 12 Tf 72 700 Td [(Inv) -250 (oice)] TJ ET BT /F1 12 Tf 131.292 700 Td (due) Tj ET" + next,
             x0: 60, x1: 200, dropped: Array("ceio")),
        Case(label: "ordinary kerning between words", term: "Total",
             full: "BT /F1 12 Tf 72 700 Td [(Grand) 150 ( Total)] TJ ET" + next,
             alone: "BT /F1 12 Tf 106.884 700 Td (Total) Tj ET",
             without: "BT /F1 12 Tf 72 700 Td (Grand) Tj ET" + next,
             x0: 60, x1: 200, dropped: ["d"]),
        Case(label: "ordinary kerning inside the word", term: "Total",
             full: "BT /F1 12 Tf 72 700 Td [(T) 80 (otal) 120 ( due)] TJ ET" + next,
             alone: "BT /F1 12 Tf 72 700 Td [(T) 80 (otal)] TJ ET",
             without: "BT /F1 12 Tf 96.276 700 Td ( due) Tj ET" + next,
             x0: 60, x1: 200, dropped: ["d"]),
    ]

    static let dpi: CGFloat = 600

    static func render(_ data: Data) throws -> CGContext {
        let provider = try #require(CGDataProvider(data: data as CFData))
        let page = try #require(CGPDFDocument(provider)?.page(at: 1))
        let box = page.getBoxRect(.cropBox)
        let s = dpi / 72, w = Int(box.width * s), h = Int(box.height * s)
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.drawPDFPage(page)
        return ctx
    }

    static func gray(_ ctx: CGContext, _ x: Int, _ y: Int) -> UInt8 {
        guard let data = ctx.data else { return 255 }
        return data.assumingMemoryBound(to: UInt8.self)[(ctx.height - 1 - y) * ctx.bytesPerRow + x]
    }

    static func letters(_ text: String) -> [Character: Int] {
        text.filter { $0.isLetter }.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    @Test("No pixel of the match's own ink stays dark outside the paint, in Secure or in Searchable", arguments: cases)
    func ownInkCovered(_ c: Case) async throws {
        let s = Self.dpi / 72
        let data = ContentGlyphWalkTests.data(c.full)
        let source = try #require(PDFDocument(data: data))
        var options = SearchOptions()
        options.includeOCR = false
        var hits: [SearchResult] = []
        for await r in DocumentSearcher().search(SendablePDFDocument(source), mode: .text(c.term, options: options), progress: { _, _ in }) {
            hits.append(r)
        }
        try #require(hits.count == 1, "one occurrence of \(c.term)")
        let regions = [0: hits.map { RedactionRegion(id: UUID(), normalizedRect: $0.normalizedRect, source: .manual) }]
        let alone = try Self.render(ContentGlyphWalkTests.data(c.alone))
        let without = try Self.render(ContentGlyphWalkTests.data(c.without))
        let x0 = Int(c.x0 * s), x1 = Int(c.x1 * s), y0 = Int(695 * s), y1 = Int(712 * s)
        var own: [(Int, Int)] = []
        for y in y0..<y1 { for x in x0..<x1 where Self.gray(alone, x, y) < 128 && Self.gray(without, x, y) > 245 { own.append((x, y)) } }
        try #require(own.count > 100, "the match's own ink is read: \(own.count) px")
        for mode in [PipelineMode.secureRasterization, .searchableRedaction] {
            let url = try await TestPipeline.processAndExport(data, mode: mode, regions: regions, fillColor: .black, dpi: 150)
            defer { try? FileManager.default.removeItem(at: url) }
            let out = try Self.render(try Data(contentsOf: url))
            // Paint: columns solid black over a band taller than any glyph on the line.
            let r0 = Int(697.5 * s), r1 = Int(709.0 * s)
            let paint = Set((x0..<x1).filter { x in (r0...r1).allSatisfy { Self.gray(out, x, $0) < 40 } })
            let dark = own.filter { !paint.contains($0.0) && Self.gray(out, $0.0, $0.1) < 200 }
            #expect(dark.isEmpty, "\(c.label), \(mode): \(dark.count) own-ink pixels dark outside the paint, at x \(CGFloat(dark.map(\.0).min() ?? 0) / s)-\(CGFloat((dark.map(\.0).max() ?? 0) + 1) / s) pt")
            if mode == .searchableRedaction {
                let outText = PDFDocument(url: url)?.page(at: 0)?.string ?? ""
                var dropped = Self.letters(source.page(at: 0)?.string ?? "")
                for (letter, n) in Self.letters(c.term) { dropped[letter, default: 0] -= n }
                for (letter, n) in Self.letters(outText) { dropped[letter, default: 0] -= n }
                let lost = dropped.filter { $0.value > 0 }.flatMap { Array(repeating: $0.key, count: $0.value) }.sorted()
                print("content-glyph export \(c.label): the Searchable layer drops \(String(lost)) beside \(c.term)")
                #expect(lost == c.dropped.sorted(), "\(c.label): drops \(String(lost)), expected \(String(c.dropped))")
            }
        }
    }

    @Test("A box whose edge stops the growth slack short of its word's ink still leaves none of that ink outside the paint, in Secure or in Searchable")
    func slackInsideThePaint() async throws {
        let s = Self.dpi / 72
        let content = "BT /F1 12 Tf 72 700 Td (account) Tj ET"
        let data = ContentGlyphWalkTests.data(content)
        let alone = try Self.render(data)
        let blank = try Self.render(ContentGlyphWalkTests.data("BT /F1 12 Tf 72 600 Td (x) Tj ET"))
        let x0 = Int(60 * s), x1 = Int(140 * s), y0 = Int(695 * s), y1 = Int(712 * s)
        var own: [(Int, Int)] = []
        for y in y0..<y1 { for x in x0..<x1 where Self.gray(alone, x, y) < 128 && Self.gray(blank, x, y) > 245 { own.append((x, y)) } }
        try #require(own.count > 100, "the word's ink is read: \(own.count) px")
        // The ink's own extent, in points, and a box that stops exactly the
        // slack short of it on the right and on the left.
        let inkMin = CGFloat(own.map(\.0).min() ?? 0) / s, inkMax = CGFloat((own.map(\.0).max() ?? 0) + 1) / s
        let slack = DocumentSearcher.growthSlack
        let box = CGRect(x: inkMin + slack, y: 696, width: inkMax - inkMin - 2 * slack, height: 13)
        let regions = [0: [RedactionRegion(id: UUID(), normalizedRect: CGRect(x: box.minX / 612, y: box.minY / 792,
                                                                                width: box.width / 612, height: box.height / 792), source: .manual)]]
        for mode in [PipelineMode.secureRasterization, .searchableRedaction] {
            let url = try await TestPipeline.processAndExport(data, mode: mode, regions: regions, fillColor: .black, dpi: 150)
            defer { try? FileManager.default.removeItem(at: url) }
            let out = try Self.render(try Data(contentsOf: url))
            let r0 = Int(697.5 * s), r1 = Int(708.5 * s)
            let paint = Set((x0..<x1).filter { x in (r0...r1).allSatisfy { Self.gray(out, x, $0) < 40 } })
            let dark = own.filter { !paint.contains($0.0) && Self.gray(out, $0.0, $0.1) < 200 }
            #expect(dark.isEmpty, "\(mode): ink x \(inkMin)-\(inkMax) pt, box \(box.minX)-\(box.maxX) pt: \(dark.count) ink pixels still dark")
        }
    }
}
