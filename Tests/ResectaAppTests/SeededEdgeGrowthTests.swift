import Testing
import Foundation
import PDFKit
import UIKit
@testable import ResectaApp

// The facts a screen test that compares the editor with the file it makes
// stands on, held where they can be computed. The reader of a written
// page's picture size is the one the canvas read-out uses
// (`FitFlooredPDFView.pictureSize(of:)`): the run writes each page as one
// picture drawn into the page, so the picture's size in pixels says the
// quality the page was painted at.

@Suite("Seeded edge growth")
@MainActor
struct SeededEdgeGrowthTests {

    /// One page of `pageSize` points, with an opaque picture of `pixels`
    /// drawn over the whole page when given, as a PDF document.
    static func writtenPage(pixels: (width: Int, height: Int)?, pageSize: CGSize) throws -> PDFPage {
        var picture: CGImage?
        if let pixels {
            let bitmap = try #require(CGContext(
                data: nil, width: pixels.width, height: pixels.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            bitmap.setFillColor(gray: 0.5, alpha: 1)
            bitmap.fill(CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
            picture = try #require(bitmap.makeImage())
        }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))
        let data = renderer.pdfData { context in
            context.beginPage()
            if let picture { UIImage(cgImage: picture).draw(in: CGRect(origin: .zero, size: pageSize)) }
        }
        return try #require(PDFDocument(data: data)?.page(at: 0))
    }

    @Test("The picture size is read from a written page, and a page with no picture reads as none")
    func thePictureSizeIsReadFromAWrittenPage() throws {
        let letter = CGSize(width: 612, height: 792)
        let painted = try Self.writtenPage(pixels: (1275, 1650), pageSize: letter)
        let size = try #require(FitFlooredPDFView.pictureSize(of: painted), "the page's one picture was not read")
        #expect(size.width == 1275 && size.height == 1650, "read \(size.width) x \(size.height)")
        let blank = try Self.writtenPage(pixels: nil, pageSize: letter)
        #expect(FitFlooredPDFView.pictureSize(of: blank) == nil)
    }
}
