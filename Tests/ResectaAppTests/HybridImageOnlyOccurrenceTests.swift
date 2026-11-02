import Testing
import Foundation
import CoreText
import PDFKit
import UIKit
@testable import ResectaApp
@testable import RedactionEngine

// A hybrid page: a picture of the line "Pay Delia Hartwell and Delia
// Hartwell" with a hidden text layer that holds only "Pay Delia Hartwell".
// The second occurrence is in the picture only. Search reads the text layer
// and the picture's recognised text; after Apply, each occurrence's whole
// ink lies inside a region. On iOS 27 the picture is read twice (accurate and fast): when
// the accurate read misses the second occurrence and the fast read holds
// both, the fast read's box for the second one must survive the text-layer
// dedup.

@Suite("Hybrid page: an occurrence only the picture holds is redacted", .tags(.search))
@MainActor
struct HybridImageOnlyOccurrenceTests {

    static let line = "Pay Delia Hartwell and Delia Hartwell"
    static let layerText = "Pay Delia Hartwell"
    static let origin = CGPoint(x: 54, y: 740)
    static let pageSize = CGSize(width: 612, height: 792)
    static let font = CTFontCreateWithName("Courier" as CFString, 10, nil)

    static func ctLine(_ text: String) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)]))
    }

    /// The glyph box of `line`'s characters `range`, in normalized page
    /// coordinates (bottom-left origin).
    static func box(_ range: NSRange) -> CGRect {
        let l = ctLine(line)
        let x0 = CTLineGetOffsetForStringIndex(l, range.location, nil)
        let x1 = CTLineGetOffsetForStringIndex(l, range.location + range.length, nil)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        CTLineGetTypographicBounds(l, &ascent, &descent, nil)
        let r = CGRect(x: origin.x + x0, y: origin.y - descent, width: x1 - x0, height: ascent + descent)
        return CGRect(x: r.minX / pageSize.width, y: r.minY / pageSize.height,
                      width: r.width / pageSize.width, height: r.height / pageSize.height)
    }

    static var occurrenceRanges: [NSRange] {
        let ns = line as NSString
        let first = ns.range(of: "Delia Hartwell")
        let second = ns.range(of: "Delia Hartwell", range: NSRange(location: NSMaxRange(first), length: ns.length - NSMaxRange(first)))
        return [first, second]
    }

    static var occurrences: [CGRect] { occurrenceRanges.map(box) }

    /// The ink of `line`'s characters `range` (the glyphs' drawn bounds), in
    /// normalized page coordinates (bottom-left origin).
    static func inkBox(_ range: NSRange) -> CGRect {
        let x0 = CTLineGetOffsetForStringIndex(ctLine(line), range.location, nil)
        let ink = CTLineGetImageBounds(ctLine((line as NSString).substring(with: range)), nil)
        let r = CGRect(x: origin.x + x0 + ink.minX, y: origin.y + ink.minY, width: ink.width, height: ink.height)
        return CGRect(x: r.minX / pageSize.width, y: r.minY / pageSize.height,
                      width: r.width / pageSize.width, height: r.height / pageSize.height)
    }

    /// Each occurrence's whole ink lies inside one applied region.
    static func expectEveryOccurrenceCovered(_ regions: [CGRect], _ results: [SearchResult]) {
        for (index, range) in occurrenceRanges.enumerated() {
            let ink = inkBox(range)
            #expect(!ink.isEmpty)
            #expect(regions.contains { $0.insetBy(dx: -1e-6, dy: -1e-6).contains(ink) },
                    "occurrence \(index + 1)'s ink \(ink) lies inside one region; regions \(regions); results \(describe(results))")
        }
    }

    /// The page: the line drawn as a 300 dpi picture, and the text layer's
    /// part of it drawn invisibly at the same place.
    static func hybridPage() throws -> PDFDocument {
        let scale: CGFloat = 300 / 72
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let picture = UIGraphicsImageRenderer(size: CGSize(width: pageSize.width * scale, height: pageSize.height * scale), format: format)
            .image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: pageSize.width * scale, height: pageSize.height * scale))
                let cg = ctx.cgContext
                cg.translateBy(x: 0, y: pageSize.height * scale)
                cg.scaleBy(x: scale, y: -scale)
                cg.textPosition = origin
                CTLineDraw(ctLine(line), cg)
            }
        let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize)).pdfData { pdf in
            pdf.beginPage()
            picture.draw(in: CGRect(origin: .zero, size: pageSize))
            let cg = pdf.cgContext
            cg.saveGState()
            cg.translateBy(x: 0, y: pageSize.height)
            cg.scaleBy(x: 1, y: -1)
            cg.setTextDrawingMode(.invisible)
            cg.textPosition = origin
            CTLineDraw(ctLine(layerText), cg)
            cg.restoreGState()
        }
        return try #require(PDFDocument(data: data))
    }

    /// Search, select every result, Apply; the applied regions on page 1.
    static func searchAndApply(_ doc: PDFDocument, searcher: DocumentSearcher) async throws -> (results: [SearchResult], regions: [CGRect]) {
        var results: [SearchResult] = []
        for await r in searcher.search(SendablePDFDocument(doc), mode: .text("Delia Hartwell", options: SearchOptions()),
                                       progress: { _, _ in }) {
            var selected = r
            selected.isSelected = true
            results.append(selected)
        }
        let state = RedactionState()
        let search = SearchState()
        search.results = results
        state.activeSearch = search
        _ = await state.applyFindings(.selectedSearchResults, undoManager: nil)
        return (results, (state.regions[0] ?? []).map(\.normalizedRect))
    }

    static func describe(_ results: [SearchResult]) -> String {
        results.map { "\($0.source) \($0.normalizedRect)" }.joined(separator: "; ")
    }

    @Test("Text recognition as it runs: both occurrences are redacted")
    func bothOccurrencesRedacted() async throws {
        let doc = try Self.hybridPage()
        let pageText = doc.page(at: 0)?.string ?? ""
        #expect(pageText.contains("Pay Delia Hartwell"), "the text layer: \(pageText.debugDescription)")
        let pictureOnly = pageText.range(of: "and Delia") == nil
        #expect(pictureOnly, "the second occurrence is in the picture only: \(pageText.debugDescription)")
        let (results, regions) = try await Self.searchAndApply(doc, searcher: DocumentSearcher())
        Self.expectEveryOccurrenceCovered(regions, results)
    }

    @Test("iOS 27 reads: the accurate read misses the second occurrence, the fast read holds both; both are redacted",
          .enabled(if: DocumentSearcher.readsFastOCRBeside))
    func fastReadBoxesTheImageOnlyOccurrence() async throws {
        let doc = try Self.hybridPage()
        let occurrences = Self.occurrences
        let lineBox = occurrences[0].union(occurrences[1]).insetBy(dx: -0.08, dy: -0.004)
        let left = CGRect(x: lineBox.minX, y: lineBox.minY, width: occurrences[0].maxX + 0.005 - lineBox.minX, height: lineBox.height)
        let right = CGRect(x: occurrences[1].minX - 0.04, y: lineBox.minY,
                           width: lineBox.maxX - (occurrences[1].minX - 0.04), height: lineBox.height)
        for fastOrder in [[("Pay Delia Hartwell", left), ("and Delia Hartwell", right)],
                          [("and Delia Hartwell", right), ("Pay Delia Hartwell", left)]] {
            let searcher = DocumentSearcher()
            await searcher._testSeedOCRLines(
                [OCREngine.TextLine(text: "Pay Delia Hartwell and Dclia Hartwcll", normalizedRect: lineBox, confidence: 0.6)],
                forPageIndex: 0)
            await searcher._testSeedOCRFastLines(
                fastOrder.map { OCREngine.TextLine(text: $0.0, normalizedRect: $0.1, confidence: 0.5) }, forPageIndex: 0)
            let (results, regions) = try await Self.searchAndApply(doc, searcher: searcher)
            Self.expectEveryOccurrenceCovered(regions, results)
        }
    }
}
