import Testing
import Foundation
import PDFKit
import CoreGraphics
@testable import RedactionEngine

// TEST §3.7 — Coordinate conversion edge cases.
// Validates normalizedToPDFPageCoordinates and normalizedToFillPixels
// with non-zero origins, cropBox offsets, and full-page spans.

@Suite("Coordinate Conversion", .tags(.critical))
struct CoordinateConversionTests {

    @Test("normalizedToPDFPageCoordinates with zero-origin page")
    func zeroOriginConversion() {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let normalized = CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1)
        let result = normalizedToPDFPageCoordinates(normalized, pageRect: pageRect)

        #expect(abs(result.minX - 306) < 0.01)
        #expect(abs(result.minY - 396) < 0.01)
        #expect(abs(result.width - 61.2) < 0.01)
        #expect(abs(result.height - 79.2) < 0.01)
    }

    @Test("normalizedToPDFPageCoordinates with non-zero-origin page")
    func nonZeroOriginConversion() {
        // Source page with cropBox origin at (50, 50)
        let pageRect = CGRect(x: 50, y: 50, width: 612, height: 792)
        let normalized = CGRect(x: 0.0, y: 0.0, width: 0.1, height: 0.1)
        let result = normalizedToPDFPageCoordinates(normalized, pageRect: pageRect)

        // Origin offset must be included
        #expect(abs(result.minX - 50) < 0.01)
        #expect(abs(result.minY - 50) < 0.01)
    }

    @Test("normalizedToFillPixels at 300 DPI US Letter fills entire bitmap")
    func fillPixelConversionFullPage() {
        let normalized = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0)
        let result = normalizedToFillPixels(
            normalized, bitmapWidth: 2550, bitmapHeight: 3300
        )
        #expect(Int(result.width) == 2550)
        #expect(Int(result.height) == 3300)
    }

    @Test("normalizedToFillPixels partial region at 150 DPI")
    func fillPixelConversionPartial() {
        let normalized = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let result = normalizedToFillPixels(
            normalized, bitmapWidth: 1275, bitmapHeight: 1650
        )
        // 0.25 * 1275 = 318.75, pixelAligned → floor(318.75) = 318
        // 0.25 * 1650 = 412.5, pixelAligned → floor(412.5) = 412
        #expect(abs(result.minX - 318) < 1)
        #expect(abs(result.minY - 412) < 1)
        // Width/height should cover at least the requested 50%
        #expect(result.width >= CGFloat(1275) * 0.5)
        #expect(result.height >= CGFloat(1650) * 0.5)
    }

    @Test("Output page always has zero-origin bounds", .tags(.critical))
    func outputPageZeroOrigin() async throws {
        // Source PDF with non-zero origin
        let fixture = TestFixtures.nonZeroOriginPDF()
        let output = try await TestPipeline.processAndExport(fixture)
        defer { try? FileManager.default.removeItem(at: output) }

        let outputDoc = try #require(PDFDocument(url: output))
        let outputPage = try #require(outputDoc.page(at: 0))
        let bounds = outputPage.bounds(for: .cropBox)

        // Output pages from CGPDFContext always have zero origin (EXP-011)
        #expect(bounds.origin.x == 0)
        #expect(bounds.origin.y == 0)
    }

    @Test("normalizedToPDFPageCoordinates full page maps to full page rect")
    func fullPageMapping() {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let normalized = CGRect(x: 0, y: 0, width: 1, height: 1)
        let result = normalizedToPDFPageCoordinates(normalized, pageRect: pageRect)

        #expect(abs(result.minX) < 0.01)
        #expect(abs(result.minY) < 0.01)
        #expect(abs(result.width - 612) < 0.01)
        #expect(abs(result.height - 792) < 0.01)
    }

    @Test("normalizedToFillPixels zero-area region produces zero-area pixel rect")
    func zeroAreaRegion() {
        let normalized = CGRect(x: 0.5, y: 0.5, width: 0, height: 0)
        let result = normalizedToFillPixels(
            normalized, bitmapWidth: 2550, bitmapHeight: 3300
        )
        #expect(result.width == 0 || result.height == 0)
    }
}
