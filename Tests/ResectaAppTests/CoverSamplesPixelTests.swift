import Testing
import Foundation
import PDFKit
import UIKit
@testable import ResectaApp

// The read's drawing test draws each word of an annotation into one pair of
// bitmaps (`ConcealingAnnotations.CoverSamples`). Its fractions must be the
// ones a new pair of bitmaps for each drawing gives, exactly: that is how the
// read drew before, and it is copied below as the reference.

@Suite("Covered-pages read: one bitmap pair an annotation draws what a new pair a drawing draws")
@MainActor
struct CoverSamplesPixelTests {

    // MARK: - The reference: a new bitmap for every drawing (the read's earlier code)

    private static func referenceFraction(of annotation: PDFAnnotation, over rect: CGRect) -> Double {
        let width = 48, height = 16
        guard let overWhite = referenceRendered(annotation, in: rect, over: 1, width: width, height: height),
              let overBlack = referenceRendered(annotation, in: rect, over: 0, width: width, height: height) else { return 0 }
        var hidden = 0
        for pixel in 0..<(width * height) {
            var difference = 0
            for channel in 0..<3 {
                difference += abs(Int(overWhite[pixel * 4 + channel]) - Int(overBlack[pixel * 4 + channel]))
            }
            if difference / 3 < 64 { hidden += 1 }
        }
        return Double(hidden) / Double(width * height)
    }

    private static func referenceRendered(
        _ annotation: PDFAnnotation, in bounds: CGRect, over gray: CGFloat, width: Int, height: Int
    ) -> [UInt8]? {
        guard bounds.width > 0, bounds.height > 0,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(gray: gray, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: CGFloat(width) / bounds.width, y: CGFloat(height) / bounds.height)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        annotation.draw(with: .mediaBox, in: context)
        guard let data = context.data else { return nil }
        return Array(UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: width * height * 4),
                                         count: width * height * 4))
    }

    // MARK: - The annotations and the rects drawn

    /// The one annotation of a one-page fixture, with the page.
    private func annotation(_ data: Data) throws -> PDFAnnotation {
        let document = try #require(PDFDocument(data: data))
        let page = try #require(document.page(at: 0))
        return try #require(page.annotations.first)
    }

    /// A highlight of `color` over a printed line, read back from data.
    private func highlight(_ color: UIColor) throws -> PDFAnnotation {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let data = UIGraphicsPDFRenderer(bounds: pageRect).pdfData { ctx in
            ctx.beginPage()
            ("Account 4417 1234 5678 9113 on file" as NSString).draw(
                at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
        let built = try #require(PDFDocument(data: data))
        let page = try #require(built.page(at: 0))
        let range = ((page.string ?? "") as NSString).range(of: "Account 4417 1234 5678 9113")
        try #require(range.location != NSNotFound)
        let bounds = try #require(page.selection(for: range)).bounds(for: page)
        let mark = PDFAnnotation(bounds: bounds.insetBy(dx: -2, dy: -1), forType: .highlight, withProperties: nil)
        mark.color = color
        page.addAnnotation(mark)
        let written = try #require(built.dataRepresentation())
        let document = try #require(PDFDocument(data: written))
        return try #require(document.page(at: 0)?.annotations.first)
    }

    /// The annotation's whole rect, its four quarters left to right, and a
    /// word-sized piece at its left edge: the kinds of rect the read draws.
    private static func rects(for annotation: PDFAnnotation) -> [CGRect] {
        let whole = annotation.bounds
        let quarter = whole.width / 4
        let quarters = (0..<4).map { CGRect(x: whole.minX + CGFloat($0) * quarter, y: whole.minY, width: quarter, height: whole.height) }
        return [whole] + quarters + [CGRect(x: whole.minX, y: whole.minY, width: min(whole.width, 30), height: whole.height)]
    }

    @Test("For every kind of annotation, in turn, each rect's fraction equals the reference's exactly")
    func fractionsEqualTheReference() throws {
        let kinds: [(String, PDFAnnotation)] = [
            ("black highlight", try highlight(.black)),
            ("see-through highlight", try highlight(UIColor.yellow.withAlphaComponent(0.35))),
            ("field with a black background", try annotation(CoverWidgetsTests.blackBackgroundField)),
            ("field painting black", try annotation(CoverWidgetsTests.blackAppearanceField)),
            ("empty field", try annotation(CoverWidgetsTests.transparentField)),
            ("black watermark", try annotation(CoverWidgetsTests.blackWatermark)),
            ("yellow highlight painted over", try annotation(CoverWidgetsTests.opaqueHighlight)),
            ("yellow highlight multiplied", try annotation(CoverWidgetsTests.multipliedHighlight)),
            ("wide highlight at the line's edge", try annotation(CoverWidgetsTests.wideHighlightOverLine)),
            ("wide highlight over blank page", try annotation(CoverWidgetsTests.wideHighlightOverBlank)),
            ("black highlight, again after the others", try highlight(.black)),
            ("see-through highlight, right after a black one", try highlight(UIColor.yellow.withAlphaComponent(0.35))),
        ]
        for (name, annotation) in kinds {
            let rects = Self.rects(for: annotation)
            let drawn = ConcealingAnnotations.hiddenFractions(of: annotation, over: rects)
            let reference = rects.map { Self.referenceFraction(of: annotation, over: $0) }
            #expect(drawn == reference, "\(name): \(drawn) against \(reference)")
        }
    }

    @Test("The comparison is not empty: a black highlight hides its rect, a see-through one does not")
    func theFixturesDraw() throws {
        let black = try highlight(.black)
        let seeThrough = try highlight(UIColor.yellow.withAlphaComponent(0.35))
        #expect(Self.referenceFraction(of: black, over: black.bounds) >= 0.6)
        #expect(Self.referenceFraction(of: seeThrough, over: seeThrough.bounds) < 0.6)
        #expect(ConcealingAnnotations.hiddenFractions(of: black, over: []).isEmpty)
        #expect(ConcealingAnnotations.hiddenFractions(of: black, over: [.zero]) == [0], "an empty rect is zero")
    }
}
