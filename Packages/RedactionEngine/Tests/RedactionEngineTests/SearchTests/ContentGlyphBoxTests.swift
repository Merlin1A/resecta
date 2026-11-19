import Testing
import Foundation
import PDFKit
@testable import RedactionEngine

/// A text-layer match's box grows to its own glyphs where the page's drawing
/// places them past PDFKit's box; it never shrinks, and on a page whose
/// boxes PDFKit gets right it does not change.
@Suite("Match boxes grown to their own glyphs")
struct ContentGlyphBoxTests {
    static let visible = ContentGlyphWalkTests.visible

    /// The text-layer search's boxes for `term` (no recognition leg, whole
    /// words off: the plant pages run one word into the next), in points.
    static func boxes(_ content: String, _ term: String, font: String = ContentGlyphWalkTests.helvetica) async throws -> [CGRect] {
        let doc = try ContentGlyphWalkTests.document(content, font: font)
        var options = SearchOptions()
        options.includeOCR = false
        options.wholeWord = false
        var out: [CGRect] = []
        for await result in DocumentSearcher().search(SendablePDFDocument(doc), mode: .text(term, options: options), progress: { _, _ in }) {
            let r = result.normalizedRect
            out.append(CGRect(x: r.minX * 612, y: r.minY * 792, width: r.width * 612, height: r.height * 792))
        }
        return out.sorted { $0.minX < $1.minX }
    }

    /// PDFKit's own box for each line of each occurrence of `term`, in points
    /// (the box before this change, on a page with no image under its text).
    static func pdfKitBoxes(_ content: String, _ term: String, font: String = ContentGlyphWalkTests.helvetica) throws -> [CGRect] {
        let doc = try ContentGlyphWalkTests.document(content, font: font)
        let page = try #require(doc.page(at: 0))
        let text = (try #require(page.string)) as NSString
        var out: [CGRect] = []
        var from = 0
        while true {
            let range = text.range(of: term, options: .caseInsensitive, range: NSRange(location: from, length: text.length - from))
            guard range.location != NSNotFound else { break }
            for line in try #require(page.selection(for: range)).selectionsByLine() { out.append(line.bounds(for: page)) }
            from = NSMaxRange(range)
        }
        return out.sorted { $0.minX < $1.minX }
    }

    /// The same box: equal up to the points-to-normalized round trip of
    /// the test's own reading (well under a thousandth of a point).
    static func close(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat = 0.0001) -> Bool {
        abs(a.minX - b.minX) < tolerance && abs(a.maxX - b.maxX) < tolerance
            && abs(a.minY - b.minY) < tolerance && abs(a.maxY - b.maxY) < tolerance
    }

    // MARK: - Grown

    @Test("A line's last word, cut short where an undrawn word starts at the line's origin, reaches its last letter's end")
    func lineEndSliver() async throws {
        let content = Self.visible + "\nBT /F1 12 Tf 0 0 0 0 72 700 Tm (QUARTZ7) Tj ET"
        let today = try #require(try Self.pdfKitBoxes(content, "account").first)
        #expect(today.maxX < 257, "precondition: PDFKit's box ends at \(today.maxX), short of the t")
        let box = try #require(try await Self.boxes(content, "account").first)
        #expect(box.maxX >= 260.088 - DocumentSearcher.growthSlack, "the box ends at \(box.maxX); the t's advance ends at 260.088")
        #expect(abs(box.minX - today.minX) < 0.001 && abs(box.minY - today.minY) < 0.001 && abs(box.maxY - today.maxY) < 0.001,
                "grown sideways only: \(box) against \(today)")
    }

    @Test("A word a TJ number draws back over the one before it covers its first letter")
    func backwardTJ() async throws {
        let content = "BT /F1 12 Tf 72 700 Td [(Inv) -250 (oice) 1200 (Total) -500 (due)] TJ ET"
        let today = try #require(try Self.pdfKitBoxes(content, "Total").first)
        #expect(today.minX > 105, "precondition: PDFKit's box starts at \(today.minX), past the T")
        let box = try #require(try await Self.boxes(content, "Total").first)
        // 98.616 by the font's own widths; the walk's system-font advances
        // place it within the growth slack of that.
        #expect(box.minX <= 98.616 + DocumentSearcher.growthSlack, "the box starts at \(box.minX); the T starts at 98.616")
    }

    // MARK: - Unchanged

    @Test("Where PDFKit's boxes are right, no box changes: ordinary kerning, five lines, two columns, a ligature",
          arguments: [
            ("BT /F1 12 Tf 72 700 Td [(Grand) 150 ( Total)] TJ ET", "Total"),
            ("BT /F1 12 Tf 72 700 Td [(T) 80 (otal) 120 ( due)] TJ ET", "Total"),
            ("BT /F1 12 Tf 72 700 Td (Line one alpha) Tj 0 -20 Td (Second line beta) Tj 0 -20 Td (Third gamma) Tj 0 -20 Td (Fourth delta) Tj 0 -20 Td (Last word end) Tj ET", "end"),
            ("BT /F1 12 Tf 72 700 Td (Line one alpha) Tj 0 -20 Td (Second line beta) Tj 0 -20 Td (Third gamma) Tj 0 -20 Td (Fourth delta) Tj 0 -20 Td (Last word end) Tj ET", "gamma"),
            ("BT /F1 12 Tf 72 700 Td (Left column text) Tj ET BT /F1 12 Tf 320 700 Td (Right column text) Tj ET BT /F1 12 Tf 72 680 Td (Left second) Tj ET BT /F1 12 Tf 320 680 Td (Right second) Tj ET", "column"),
            ("BT /F1 12 Tf 72 700 Td (Quarterly statement for the account) Tj ET", "account"),
          ])
    func unchanged(_ content: String, _ term: String) async throws {
        let today = try Self.pdfKitBoxes(content, term)
        let boxes = try await Self.boxes(content, term)
        #expect(boxes.count == today.count && !boxes.isEmpty)
        for (box, before) in zip(boxes, today) {
            #expect(Self.close(box, before), "\(term): \(box) against PDFKit's \(before)")
        }
    }

    @Test("An undrawn word keeps PDFKit's box (no box is taken away here), and adds nothing to its neighbours")
    func undrawnKeepsItsBox() async throws {
        for (x, y) in [(100, 600), (300, 200)] {
            let content = Self.visible + "\nBT /F1 12 Tf 0 0 0 0 \(x) \(y) Tm (QUARTZ7) Tj ET"
            let today = try Self.pdfKitBoxes(content, "QUARTZ7")
            let boxes = try await Self.boxes(content, "QUARTZ7")
            #expect(boxes.count == today.count)
            for (box, before) in zip(boxes, today) { #expect(Self.close(box, before), "at(\(x),\(y)): \(box) against \(before)") }
        }
    }

    @Test("Part drawn, part undrawn: the drawn letter's box is covered, and nothing shrinks")
    func partlyDrawn() async throws {
        let content = Self.visible + "\nBT /F1 12 Tf 72 650 Td (Ref Q) Tj 0 0 0 0 110 650 Tm (Z7) Tj ET"
        let today = try #require(try Self.pdfKitBoxes(content, "QZ7").first)
        let box = try #require(try await Self.boxes(content, "QZ7").first)
        #expect(box.contains(today.insetBy(dx: 0.001, dy: 0.001)), "\(box) holds PDFKit's \(today)")
        // "Ref " advances 22.008 from 72: the drawn Q runs 94.008-103.344.
        let slack = DocumentSearcher.growthSlack
        #expect(box.minX <= 94.008 + slack && box.maxX >= 103.344 - slack, "the drawn Q (94.008-103.344) is inside \(box)")
    }

    // MARK: - Not mapped

    @Test("Two copies of a word drawn right to left on one line: each box stays on its own copy")
    func twinsDrawnOutOfOrder() async throws {
        let content = "BT /F1 12 Tf 300 700 Td (Hartwell) Tj ET BT /F1 12 Tf 72 700 Td (Hartwell) Tj ET"
        let boxes = try await Self.boxes(content, "Hartwell")
        #expect(boxes.count == 2)
        for box in boxes { #expect(box.width < 60, "a box spans \(box.minX)-\(box.maxX): the copies are crossed") }
        let today = try Self.pdfKitBoxes(content, "Hartwell")
        for (box, before) in zip(boxes, today) { #expect(Self.close(box, before), "\(box) against \(before)") }
    }

    @Test("A page the walk cannot read keeps PDFKit's boxes: a /Differences name with no text here")
    func unreadPageUnchanged() async throws {
        let font = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding << /Type /Encoding /BaseEncoding /WinAnsiEncoding /Differences [90 /Zcaron] >> >>"
        let content = Self.visible + "\nBT /F1 12 Tf 0 0 0 0 72 700 Tm (QUARTZ7) Tj ET"
        let today = try #require(try Self.pdfKitBoxes(content, "account", font: font).first)
        let box = try #require(try await Self.boxes(content, "account", font: font).first)
        #expect(Self.close(box, today), "\(box) against \(today)")
    }
}
