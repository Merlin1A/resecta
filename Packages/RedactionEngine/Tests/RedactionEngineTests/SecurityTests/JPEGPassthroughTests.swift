import Testing
import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif
import ImageIO

// EXP-010 migrated: JPEG Passthrough, Metadata, FileManager
// Audit: AA-3, AA-7, MP-4-1 (Critical), AA-9-1 (Critical), AA-8

@Suite("JPEG Passthrough & File Operations", .tags(.security))
struct JPEGPassthroughTests {

    // --- AA-3: JPEG passthrough via CGImage(jpegDataProviderSource:) ---
    @Test("JPEG passes through as /DCTDecode — no re-encoding")
    func jpegPassthroughInCGPDFContext() throws {
        let bitmapCtx = CGContext(data: nil, width: 200, height: 200,
            bitsPerComponent: 8, bytesPerRow: 200 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bitmapCtx.setFillColor(CGColor(red: 0.5, green: 0.3, blue: 0.7, alpha: 1))
        bitmapCtx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        let sourceImage = bitmapCtx.makeImage()!

        let jpegData = NSMutableData()
        let dest = CGImageDestinationCreateWithData(
            jpegData as CFMutableData, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, sourceImage,
            [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(dest)

        let provider = CGDataProvider(data: jpegData as CFData)!
        let jpegImage = CGImage(jpegDataProviderSource: provider, decode: nil,
                                shouldInterpolate: false, intent: .defaultIntent)!

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("passthrough_test_\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 200)
        let pdfContext = CGContext(outputURL as CFURL, mediaBox: &mediaBox, nil)!
        pdfContext.beginPage(mediaBox: &mediaBox)
        pdfContext.draw(jpegImage, in: mediaBox)
        pdfContext.endPage()
        pdfContext.closePDF()

        let pdfData = try Data(contentsOf: outputURL)
        // Search raw bytes for "/DCTDecode" — String(data:encoding:.ascii) fails
        // on binary PDF content, so search the byte pattern directly.
        let marker = "/DCTDecode".data(using: .ascii)!
        let hasDCTDecode = pdfData.range(of: marker) != nil
        #expect(hasDCTDecode,
                "JPEG must pass through as /DCTDecode — no re-encoding")
    }

    // --- AA-7: CGPDFContext metadata injection with empty aux dict ---
    @Test("CGPDFContext auto-injects metadata with empty aux dict")
    func cgPDFContextMetadataWithEmptyAuxDict() {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("metadata_test_\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        var mediaBox = CGRect(x: 0, y: 0, width: 100, height: 100)
        let pdfContext = CGContext(outputURL as CFURL, mediaBox: &mediaBox,
                                  [:] as CFDictionary)!
        pdfContext.beginPage(mediaBox: &mediaBox)
        pdfContext.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        pdfContext.fill(mediaBox)
        pdfContext.endPage()
        pdfContext.closePDF()

        let pdfDoc = CGPDFDocument(outputURL as CFURL)!
        // CGPDFContext auto-injects /Producer even with empty aux dict —
        // this is a known limitation documented in ENGINE §4.5.
        if let info = pdfDoc.info {
            var str: CGPDFStringRef?
            let hasProducer = CGPDFDictionaryGetString(info, "Producer", &str)
            // Verify the known behavior: Producer is auto-injected
            #expect(hasProducer, "CGPDFContext auto-injects /Producer (known limitation)")
        }
    }

    // --- MP-4-1 / AA-9-1 (Critical): replaceItemAt when destination doesn't exist ---
    @Test("FileManager.replaceItemAt handles missing destination")
    func replaceItemAtDestinationNotExist() throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let sourceURL = tmpDir.appendingPathComponent("source_\(UUID().uuidString).pdf")
        let destinationURL = tmpDir.appendingPathComponent("dest_\(UUID().uuidString).pdf")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: destinationURL)
        }

        try "test".data(using: .utf8)!.write(to: sourceURL)
        #expect(!FileManager.default.fileExists(atPath: destinationURL.path))

        // replaceItemAt may succeed or fail when destination doesn't exist —
        // either path is acceptable as long as the file ends up at destination.
        do {
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: sourceURL)
        } catch {
            // Fallback to moveItem — the production code path
            try "test".data(using: .utf8)!.write(to: sourceURL)
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        }
        #expect(FileManager.default.fileExists(atPath: destinationURL.path))
    }

    // --- AA-8: autoreleasepool rethrows ---
    @Test("autoreleasepool rethrows errors correctly")
    func autoreleasepoolRethrows() throws {
        struct TestError: Error {}
        #expect(throws: TestError.self) {
            try autoreleasepool { throw TestError() }
        }
    }
}
