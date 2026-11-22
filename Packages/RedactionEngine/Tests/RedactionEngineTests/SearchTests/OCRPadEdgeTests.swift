import CoreGraphics
import PDFKit
import Testing
@testable import RedactionEngine

// The 2-pt pad on an OCR line's rect (`paddedNormalizedRect`), at each edge of
// the page and on a page turned a quarter. The page is 512 by 1024 pt, so every
// pad (1/256 or 1/512 of a side) and every rect here is exact in binary and the
// cases compare exactly. An edge the clamp holds at 0 or 1 leaves the edge
// across from it padded 2 pt, no more; the pad is read on the sides as shown.

@Suite("An OCR line's pad holds each edge of the page as displayed", .tags(.search))
struct OCRPadEdgeTests {

    /// A 512 by 1024 pt page, turned `rotation` degrees.
    static func page(_ rotation: Int) -> PDFPage {
        let page = PDFPage()
        let box = CGRect(x: 0, y: 0, width: 512, height: 1024)
        page.setBounds(box, for: .mediaBox)
        page.setBounds(box, for: .cropBox)
        page.rotation = rotation
        return page
    }

    /// The page's sides as displayed, in points: 512 by 1024 upright, 1024 by 512 turned a quarter.
    static func sides(_ rotation: Int) -> (width: CGFloat, height: CGFloat) {
        rotation % 180 == 0 ? (512, 1024) : (1024, 512)
    }

    @Test("A line at the left edge: held at 0, its right side padded 2 pt", arguments: [0, 90])
    func leftEdge(rotation: Int) {
        let (w, _) = Self.sides(rotation)
        let line = CGRect(x: 1 / w, y: 0.5, width: 0.125, height: 0.03125)
        let padded = DocumentSearcher.paddedNormalizedRect(line, in: Self.page(rotation))
        #expect(padded.minX == 0)
        #expect(padded.maxX == line.maxX + 2 / w, "the far side gets 2 pt, not 2 pt plus what the clamp cut")
    }

    @Test("A line at the right edge: held at 1, its left side padded 2 pt", arguments: [0, 90])
    func rightEdge(rotation: Int) {
        let (w, _) = Self.sides(rotation)
        let line = CGRect(x: 1 - 0.125 - 1 / w, y: 0.5, width: 0.125, height: 0.03125)
        let padded = DocumentSearcher.paddedNormalizedRect(line, in: Self.page(rotation))
        #expect(padded.maxX == 1, "the pad stops at the page's right edge")
        #expect(padded.minX == line.minX - 2 / w)
    }

    @Test("A line at the bottom edge: held at 0, its top padded 2 pt", arguments: [0, 90])
    func bottomEdge(rotation: Int) {
        let (_, h) = Self.sides(rotation)
        let line = CGRect(x: 0.5, y: 1 / h, width: 0.125, height: 0.03125)
        let padded = DocumentSearcher.paddedNormalizedRect(line, in: Self.page(rotation))
        #expect(padded.minY == 0)
        #expect(padded.maxY == line.maxY + 2 / h, "the far side gets 2 pt, not 2 pt plus what the clamp cut")
    }

    @Test("A line at the top edge: held at 1, its bottom padded 2 pt", arguments: [0, 90])
    func topEdge(rotation: Int) {
        let (_, h) = Self.sides(rotation)
        let line = CGRect(x: 0.5, y: 1 - 0.03125 - 1 / h, width: 0.125, height: 0.03125)
        let padded = DocumentSearcher.paddedNormalizedRect(line, in: Self.page(rotation))
        #expect(padded.maxY == 1, "the pad stops at the page's top edge")
        #expect(padded.minY == line.minY - 2 / h)
    }

    @Test("A line clear of the edges is padded 2 pt on every side of the page as displayed", arguments: [0, 90])
    func clearOfTheEdges(rotation: Int) {
        let (w, h) = Self.sides(rotation)
        let line = CGRect(x: 0.25, y: 0.5, width: 0.125, height: 0.03125)
        let padded = DocumentSearcher.paddedNormalizedRect(line, in: Self.page(rotation))
        #expect((line.minX - padded.minX) * w == 2)
        #expect((padded.maxX - line.maxX) * w == 2)
        #expect((line.minY - padded.minY) * h == 2)
        #expect((padded.maxY - line.maxY) * h == 2)
    }
}
