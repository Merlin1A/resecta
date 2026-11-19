import Testing
import Foundation
import PDFKit
import UIKit
import RedactionEngine
@testable import ResectaApp

// What the covered-pages read (`ConcealingAnnotations.pages`) names for each
// kind of annotation it meets, written down before the read's drawing was
// changed and kept after: a change to how the read draws an annotation must
// name the same pages for every row.

@Suite("Covered-pages read: the pages named for each kind of annotation")
@MainActor
struct CoveredPagesDecisionsTests {

    private static let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
    private static let font = UIFont.systemFont(ofSize: 12)
    private static let lineTops: [CGFloat] = [72, 112, 152]

    /// The text of line `line` on any page: nine words after a tag that
    /// tells the lines apart.
    private static func text(line: Int) -> String {
        "L\(line) the quarterly statement lists every transfer between accounts"
    }

    /// One annotation of a code-built document: a highlight of `color` over
    /// line `line` of page `page`, or over its first word only.
    private struct Mark {
        let page: Int
        let line: Int
        let color: UIColor
        var firstWordOnly = false
    }

    /// A document of `pages` pages, three lines of text a page, with `marks`
    /// added and the whole read back from its data the way a file is read.
    private func markedDocument(pages: Int, marks: [Mark]) throws -> PDFDocument {
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font]
        let data = UIGraphicsPDFRenderer(bounds: Self.pageRect).pdfData { ctx in
            for _ in 0..<pages {
                ctx.beginPage()
                for (line, top) in Self.lineTops.enumerated() {
                    (Self.text(line: line) as NSString).draw(at: CGPoint(x: 72, y: top), withAttributes: attributes)
                }
            }
        }
        let built = try #require(PDFDocument(data: data))
        for mark in marks {
            let page = try #require(built.page(at: mark.page))
            let pageText = (page.string ?? "") as NSString
            let tag = Self.text(line: mark.line)
            var range = pageText.range(of: tag)
            try #require(range.location != NSNotFound, "line \(mark.line) of page \(mark.page) must read")
            if mark.firstWordOnly { range.length = "L\(mark.line)".count }
            let bounds = try #require(page.selection(for: range)).bounds(for: page)
            let highlight = PDFAnnotation(bounds: bounds.insetBy(dx: -2, dy: -1), forType: .highlight, withProperties: nil)
            highlight.color = mark.color
            page.addAnnotation(highlight)
        }
        let written = try #require(built.dataRepresentation())
        let document = try #require(PDFDocument(data: written))
        for index in 0..<pages {
            let page = try #require(document.page(at: index))
            try #require((page.string ?? "").contains(Self.text(line: 0)), "page \(index) must carry its text")
            try #require(page.annotations.filter { $0.type == "Highlight" }.count
                         == marks.filter { $0.page == index }.count, "page \(index) must carry its highlights")
        }
        return document
    }

    private func fixture(_ data: Data) throws -> PDFDocument {
        let document = try #require(PDFDocument(data: data))
        let page = try #require(document.page(at: 0))
        try #require((page.string ?? "").contains("123-45-6789"), "the fixture's text layer")
        try #require(page.annotations.count == 1, "the fixture's annotation")
        return document
    }

    private static let seeThrough = UIColor.yellow.withAlphaComponent(0.35)

    @Test("One-page covers over a printed SSN: each names its page or not, as written down")
    func onePageCovers() throws {
        let rows: [(String, Data, [Int])] = [
            ("a field with a black background", CoverWidgetsTests.blackBackgroundField, [0]),
            ("a field whose appearance paints black", CoverWidgetsTests.blackAppearanceField, [0]),
            ("an empty field", CoverWidgetsTests.transparentField, []),
            ("a black watermark", CoverWidgetsTests.blackWatermark, [0]),
            ("a black highlight", CoverWidgetsTests.blackHighlight, [0]),
            ("a yellow highlight painted over the text", CoverWidgetsTests.opaqueHighlight, [0]),
            ("a yellow highlight multiplied with the text", CoverWidgetsTests.multipliedHighlight, []),
            ("a wide highlight painting the line at its edge", CoverWidgetsTests.wideHighlightOverLine, [0]),
            ("a wide field painting the line at its edge", CoverWidgetsTests.wideFieldOverLine, [0]),
            ("a wide highlight painting blank page only", CoverWidgetsTests.wideHighlightOverBlank, []),
        ]
        for (name, data, named) in rows {
            let document = try fixture(data)
            #expect(ConcealingAnnotations.pages(in: document, regions: [:]) == named, "\(name)")
        }
    }

    @Test("See-through highlights over every line name no page")
    func seeThroughHighlightsNameNothing() throws {
        let marks = (0..<2).flatMap { page in (0..<3).map { Mark(page: page, line: $0, color: Self.seeThrough) } }
        let document = try markedDocument(pages: 2, marks: marks)
        #expect(ConcealingAnnotations.pages(in: document, regions: [:]).isEmpty)
    }

    @Test("A black highlight among see-through ones names its page only")
    func blackAmongSeeThrough() throws {
        let document = try markedDocument(pages: 2, marks: [
            Mark(page: 0, line: 0, color: Self.seeThrough),
            Mark(page: 0, line: 1, color: .black),
            Mark(page: 0, line: 2, color: Self.seeThrough),
            Mark(page: 1, line: 0, color: Self.seeThrough),
            Mark(page: 1, line: 1, color: Self.seeThrough),
        ])
        #expect(ConcealingAnnotations.pages(in: document, regions: [:]) == [0])
    }

    @Test("A see-through one-word highlight read right after a black one stays unnamed")
    func seeThroughAfterBlack() throws {
        let document = try markedDocument(pages: 2, marks: [
            Mark(page: 0, line: 0, color: .black),
            Mark(page: 1, line: 2, color: Self.seeThrough, firstWordOnly: true),
        ])
        #expect(ConcealingAnnotations.pages(in: document, regions: [:]) == [0])
    }

    @Test("A black highlight read right after see-through ones is named")
    func blackAfterSeeThrough() throws {
        let document = try markedDocument(pages: 2, marks: [
            Mark(page: 0, line: 0, color: Self.seeThrough),
            Mark(page: 0, line: 1, color: Self.seeThrough, firstWordOnly: true),
            Mark(page: 1, line: 2, color: .black, firstWordOnly: true),
        ])
        #expect(ConcealingAnnotations.pages(in: document, regions: [:]) == [1])
    }

    @Test("A black highlight under a redaction box names nothing; over blank page, nothing")
    func boxAndBlank() throws {
        let document = try markedDocument(pages: 1, marks: [Mark(page: 0, line: 1, color: .black)])
        let page = try #require(document.page(at: 0))
        let bounds = try #require(page.annotations.first).bounds
        let crop = page.bounds(for: .cropBox)
        let box = RedactionRegion(
            id: UUID(),
            normalizedRect: CGRect(x: (bounds.minX - 6) / crop.width, y: (bounds.minY - 6) / crop.height,
                                   width: (bounds.width + 12) / crop.width, height: (bounds.height + 12) / crop.height),
            source: .manual)
        #expect(ConcealingAnnotations.pages(in: document, regions: [0: [box]]).isEmpty, "the box covers it")
        #expect(ConcealingAnnotations.pages(in: document, regions: [:]) == [0], "no box: named")

        let blank = try markedDocument(pages: 1, marks: [])
        let blankPage = try #require(blank.page(at: 0))
        let cover = PDFAnnotation(bounds: CGRect(x: 300, y: 300, width: 120, height: 40), forType: .highlight, withProperties: nil)
        cover.color = .black
        blankPage.addAnnotation(cover)
        #expect(ConcealingAnnotations.pages(in: blank, regions: [:]).isEmpty, "no text under it")
    }
}
