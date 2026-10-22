import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import RedactionEngine

/// The image loader: JPEG, PNG and HEIC/HEIF bytes become one page each,
/// drawn from their decoded pixels at 300 pixels per inch. Every stage
/// runs in order, off the main actor, against the bytes alone; nothing in
/// the image's property dictionary is read beyond its two pixel sizes, and
/// nothing is written.
nonisolated struct ImageImportLoader: DocumentLoader {

    /// The Image I/O types a page may come from. The type a door declared
    /// is never consulted; the bytes name their own type here.
    static let acceptedSourceTypes: Set<String> = ["public.jpeg", "public.png", "public.heic", "public.heif"]
    /// The page's declared resolution: one pixel is 72/300 of a point.
    static let pointsPerPixel: CGFloat = 72.0 / 300.0
    /// The page image is a fresh JPEG at this quality, encoded from the
    /// redrawn pixels (the bitmap released after the encode); measured
    /// against lossless pages, a 24-megapixel photo-like page was 16 MB
    /// under Flate and 9.5 MB as a JPEG at this setting.
    static let pageImageQuality: Double = 0.92

    func load(_ payload: ImportPayload, password: String?, limits: ImportLimits) async throws -> LoadedDocument {
        let inputs: AsyncThrowingStream<Data, any Error>
        let count: Int
        switch payload {
        case .bytes(let data, _, _):
            inputs = AsyncThrowingStream { continuation in
                continuation.yield(data)
                continuation.finish()
            }
            count = 1
        case .images(let stream, let declared, _):
            inputs = stream
            count = declared
        }
        guard count >= 1, count <= limits.maxImagesPerImport else {
            throw PipelineError.importError(.corrupt)
        }

        // The PDF context opens on the first page's box (the document's
        // default box); every page then declares its own.
        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData) else {
            throw PipelineError.importError(.corrupt)
        }
        var context: CGContext?
        var pages = 0
        for try await data in inputs {
            try Task.checkCancellation()
            guard pages < count else { throw PipelineError.importError(.corrupt) }
            try autoreleasepool {
                let page = try Self.pageImage(from: data, index: pages, limits: limits)
                var box = page.mediaBox
                if context == nil {
                    context = CGContext(consumer: consumer, mediaBox: &box, [:] as CFDictionary)
                }
                guard let context else { throw PipelineError.importError(.corrupt) }
                let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
                context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
                context.draw(page.image, in: page.mediaBox)
                context.endPDFPage()
            }
            pages += 1
        }
        try Task.checkCancellation()
        context?.closePDF()
        guard pages == count, let document = PDFDocument(data: pdfData as Data),
              document.pageCount == count else {
            throw PipelineError.importError(.corrupt)
        }

        var textLayerStatus: [Int: TextLayerStatus] = [:]
        for i in 0..<count { textLayerStatus[i] = TextLayerStatus.none }
        let facts = ImportFacts(
            origin: .images(count: count),
            textLayerStatus: textLayerStatus,
            hasHiddenOCG: false,
            annotationFindings: [],
            filledFormFieldCount: 0,
            wasEncrypted: false,
            hadRestrictions: false
        )
        return LoadedDocument(document: SendablePDFDocument(document), facts: facts)
    }

    // MARK: - One image, one page

    /// A page image and the box it fills.
    struct PageImage {
        let image: CGImage
        let mediaBox: CGRect
    }

    /// The stages for one input, in order; each refusal names its class
    /// from the import-failure taxonomy. The result is the page image (a
    /// DCT stream) and its box at 300 pixels per inch.
    static func pageImage(from data: Data, index: Int, limits: ImportLimits) throws -> PageImage {
        // The byte cap, before any decode.
        guard data.count <= limits.maxBytes else {
            throw PipelineError.importError(.tooLarge(bytesRead: data.count))
        }
        // 1. An Image I/O source over the bytes, with no decode cache.
        guard let source = CGImageSourceCreateWithData(
            data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw PipelineError.importError(.unsupportedFormat)
        }
        // 2. The type the bytes carry, against the accepted set.
        guard let type = CGImageSourceGetType(source) as String?, acceptedSourceTypes.contains(type) else {
            throw PipelineError.importError(.unsupportedFormat)
        }
        // 3. A complete file; a truncated one is damaged. The source's
        //    status alone reads complete for in-memory bytes however short,
        //    so the container's end marker is required too: a JPEG's EOI
        //    after its scan, a PNG's IEND chunk last.
        guard CGImageSourceGetStatus(source) == .statusComplete, hasEndMarker(data, type: type) else {
            throw PipelineError.importError(.corrupt)
        }
        // 4. One still image: the primary image of a HEIC/HEIF; a single
        //    frame for JPEG and PNG (an animation or a multi-picture file
        //    is not a still).
        let primary: Int
        if type == "public.heic" || type == "public.heif" {
            primary = CGImageSourceGetPrimaryImageIndex(source)
        } else {
            guard CGImageSourceGetCount(source) == 1 else {
                throw PipelineError.importError(.unsupportedFormat)
            }
            primary = 0
        }
        // 5. The declared pixel size — the only two properties read — and
        //    the size arms, before any pixel is decoded.
        guard let properties = CGImageSourceCopyPropertiesAtIndex(
                source, primary, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw PipelineError.importError(.corrupt)
        }
        guard width > 0, height > 0,
              width * height <= limits.maxDeclaredImagePixels,
              min(width, height) >= limits.minImageSide else {
            throw PipelineError.importError(.invalidPageDimensions(pageIndex: index))
        }
        // 6. The decode target: the long side after the pixel budget and
        //    the side cap.
        let longSide = max(width, height)
        let budgeted = Int((Double(longSide)
            * (Double(limits.maxDecodedImagePixels) / Double(width * height)).squareRoot()).rounded(.down))
        let target = min(longSide, limits.maxImageSide, budgeted)
        // 7. The decode: a thumbnail generated from the image itself (never
        //    an embedded one), bounded at the target, with the EXIF
        //    orientation applied here, once.
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: target,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, primary, thumbnailOptions as CFDictionary) else {
            throw PipelineError.importError(.corrupt)
        }
        // 8. The pixels-only boundary: the decoded image is drawn into an
        //    app-owned sRGB 8-bit context, filled white first, so no data
        //    provider, profile, alpha channel or metadata of the source
        //    survives into the page.
        let pixels = try redraw(decoded)
        // 9. The page image: a fresh JPEG from those pixels, carried into
        //    the PDF as a DCT stream.
        let pageImage = try encodePageImage(pixels)
        // 10. The page box: the pixel size at 300 pixels per inch; the page
        //     carries no rotation entry (the orientation is in the pixels)
        //     and no auxiliary information.
        let mediaBox = CGRect(x: 0, y: 0,
                              width: CGFloat(pixels.width) * pointsPerPixel,
                              height: CGFloat(pixels.height) * pointsPerPixel)
        return PageImage(image: pageImage, mediaBox: mediaBox)
    }

    /// Whether the container ends: a JPEG carries an end-of-image marker
    /// after its first scan (FF D9 cannot occur inside entropy-coded data),
    /// a PNG ends with its IEND chunk; a HEIC's box structure is read by
    /// Image I/O, which reports no image for a cut file.
    static func hasEndMarker(_ data: Data, type: String) -> Bool {
        switch type {
        case "public.jpeg":
            guard let scan = data.range(of: Data([0xFF, 0xDA])) else { return false }
            return data.range(of: Data([0xFF, 0xD9]), in: scan.upperBound..<data.endIndex) != nil
        case "public.png":
            let iend = Data([0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])
            return data.count >= iend.count && data.suffix(iend.count) == iend
        default:
            return true
        }
    }

    /// The decoded image redrawn from its pixels into a fresh sRGB bitmap.
    static func redraw(_ image: CGImage) throws -> CGImage {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let redraw = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw PipelineError.importError(.corrupt)
        }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        redraw.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        redraw.fill(bounds)
        redraw.interpolationQuality = .high
        redraw.draw(image, in: bounds)
        guard let pixels = redraw.makeImage() else {
            throw PipelineError.importError(.corrupt)
        }
        return pixels
    }

    /// A fresh JPEG of the redrawn pixels, wrapped so the PDF context
    /// passes the DCT stream through.
    static func encodePageImage(_ pixels: CGImage) throws -> CGImage {
        let jpeg = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil) else {
            throw PipelineError.importError(.corrupt)
        }
        CGImageDestinationAddImage(destination, pixels,
                                   [kCGImageDestinationLossyCompressionQuality: pageImageQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination),
              let provider = CGDataProvider(data: jpeg as CFData),
              let pageImage = CGImage(jpegDataProviderSource: provider, decode: nil,
                                      shouldInterpolate: true, intent: .defaultIntent) else {
            throw PipelineError.importError(.corrupt)
        }
        return pageImage
    }
}
