import Testing
import Foundation
import CoreGraphics
import ImageIO
import PDFKit
@testable import ResectaApp
@testable import RedactionEngine

// The image loader, driven through the router and the loader protocol with
// no state object in scope: the admitted formats become pages drawn from
// their pixels at 300 pixels per inch; every other arm refuses with the
// import-failure taxonomy before any decode it can avoid.

@Suite("Image import loader", .tags(.importFlow))
struct ImageImportLoaderTests {

    // MARK: - Driving the seam

    static func load(_ data: Data, limits: ImportLimits = .standard) async throws -> LoadedDocument {
        let loader = try ImportRouter.route(data: data)
        return try await loader.load(.bytes(data, declaredType: nil, door: .files), password: nil, limits: limits)
    }

    static func loadStream(_ items: [Data], count: Int? = nil, limits: ImportLimits = .standard) async throws -> LoadedDocument {
        let loader = try ImportRouter.route(data: items.first ?? Data())
        let stream = AsyncThrowingStream<Data, any Error> { continuation in
            for item in items { continuation.yield(item) }
            continuation.finish()
        }
        return try await loader.load(.images(stream, count: count ?? items.count, door: .photos), password: nil, limits: limits)
    }

    /// The import-failure class a load refuses with, as the taxonomy names it.
    static func refusal(_ data: Data, limits: ImportLimits = .standard) async -> String {
        do { _ = try await load(data, limits: limits); return "open" }
        catch { return className(error) }
    }

    static func className(_ error: any Error) -> String {
        guard let pipelineError = error as? PipelineError else { return "\(type(of: error))" }
        switch pipelineError {
        case .importError(let failure):
            switch failure {
            case .corrupt: return "corrupt"
            case .passwordProtected: return "passwordProtected"
            case .tooLarge: return "tooLarge"
            case .unsupportedFormat: return "unsupportedFormat"
            case .invalidPageDimensions: return "invalidPageDimensions"
            case .activeContent: return "activeContent"
            }
        default: return "\(pipelineError)"
        }
    }

    /// The pixel size of the first image XObject on a page.
    static func embeddedImageSize(_ page: CGPDFPage) -> (Int, Int)? {
        guard let dict = page.dictionary else { return nil }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let resources else { return nil }
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return nil }
        nonisolated final class Box: @unchecked Sendable { var size: (Int, Int)? }
        let box = Box()
        CGPDFDictionaryApplyBlock(xobjects, { _, value, info in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(value, .stream, &stream), let stream,
                  let sd = CGPDFStreamGetDictionary(stream) else { return true }
            var w: CGPDFInteger = 0, h: CGPDFInteger = 0
            guard CGPDFDictionaryGetInteger(sd, "Width", &w), CGPDFDictionaryGetInteger(sd, "Height", &h) else { return true }
            Unmanaged<Box>.fromOpaque(info!).takeUnretainedValue().size = (Int(w), Int(h))
            return false
        }, Unmanaged.passUnretained(box).toOpaque())
        return box.size
    }

    static func page(_ loaded: LoadedDocument, _ index: Int = 0) throws -> CGPDFPage {
        try #require(loaded.document.document.page(at: index)?.pageRef)
    }

    // MARK: - Pages drawn from pixels

    @Test("A 12 MP and a 24 MP JPEG keep their pixels and get a page of px × 72/300 pt",
          arguments: [(4000, 3000), (6000, 4000)])
    func pageGeometryKeepsThePixels(_ size: (Int, Int)) async throws {
        let (w, h) = size
        let loaded = try await Self.load(ImageFixtures.jpeg(width: w, height: h, marker: false))
        let page = try Self.page(loaded)
        let box = page.getBoxRect(.mediaBox)
        #expect(abs(box.width - CGFloat(w) * 72 / 300) < 0.01)
        #expect(abs(box.height - CGFloat(h) * 72 / 300) < 0.01)
        #expect(page.rotationAngle == 0)
        let embedded = try #require(Self.embeddedImageSize(page))
        #expect(embedded.0 == w && embedded.1 == h, "the pixel count is kept: \(embedded)")
    }

    @Test("A 48 MP image is downsampled at decode to at most 25 MP with a long side under 8,000 px")
    func fortyEightMegapixelsIsDownsampled() async throws {
        let loaded = try await Self.load(ImageFixtures.jpeg(width: 8000, height: 6000, marker: false))
        let embedded = try #require(Self.embeddedImageSize(try Self.page(loaded)))
        #expect(embedded.0 * embedded.1 <= 25_000_000, "\(embedded)")
        #expect(embedded.0 <= 8_000 && embedded.1 <= 8_000)
        #expect(embedded.0 * embedded.1 > 20_000_000, "the downsample keeps most of the budget: \(embedded)")
    }

    @Test("A 9,000 × 1,000 panorama keeps a long side of 8,000 px")
    func panoramaLongSideIsCapped() async throws {
        let loaded = try await Self.load(ImageFixtures.jpeg(width: 9000, height: 1000, marker: false))
        let embedded = try #require(Self.embeddedImageSize(try Self.page(loaded)))
        #expect(embedded.0 <= 8_000 && embedded.0 >= 7_990, "\(embedded)")
    }

    @Test("Three inputs become three pages in order")
    func threeInputsInOrder() async throws {
        let loaded = try await Self.loadStream([
            ImageFixtures.jpeg(width: 400, height: 300), ImageFixtures.png(width: 300, height: 400),
            ImageFixtures.jpeg(width: 500, height: 200)])
        let doc = loaded.document.document
        #expect(doc.pageCount == 3)
        let widths: [CGFloat] = (0..<3).compactMap { doc.page(at: $0)?.bounds(for: .mediaBox).width }
        let expected: [CGFloat] = [96, 72, 120]   // 400 · 300 · 500 px × 72/300
        #expect(widths == expected, "\(widths)")
    }

    @Test("An alpha PNG is flattened on white")
    func alphaIsFlattenedOnWhite() async throws {
        let loaded = try await Self.load(ImageFixtures.alphaPNG())
        let samples = ImageFixtures.samples(of: try Self.page(loaded))
        for corner in ["topLeft", "topRight", "bottomLeft", "bottomRight"] {
            #expect(ImageFixtures.isWhite(samples[corner]!), "\(corner) \(samples[corner]!)")
        }
        let centre = samples["centre"]!
        #expect(centre.0 < 60 && centre.1 < 60 && centre.2 < 60, "the opaque block is drawn: \(centre)")
    }

    @Test("The facts of an image import")
    func factsOfAnImageImport() async throws {
        let loaded = try await Self.loadStream([ImageFixtures.jpeg(), ImageFixtures.jpeg()])
        let facts = loaded.facts
        #expect(facts.origin == .images(count: 2))
        #expect(facts.textLayerStatus == [0: TextLayerStatus.none, 1: TextLayerStatus.none])
        #expect(facts.hasHiddenOCG == false)
        #expect(facts.annotationFindings.isEmpty)
        #expect(facts.filledFormFieldCount == 0)
        #expect(facts.wasEncrypted == false && facts.hadRestrictions == false)
        #expect(facts.summary.origin == .images(count: 2))
    }

    // MARK: - The size arms, before any decode

    // Image I/O reports no pixel size for a declaration above 100 megapixels
    // (10,000 × 10,000 is reported; 10,001 × 10,000 is not — measured on the
    // iOS 26.5 simulator and macOS), so such a file is refused at the size
    // read as damaged, before any decode; the loader's own 100-megapixel
    // arm stands behind it. A hand-built PNG header over a token image
    // stream is not reported either.

    @Test("A declared 30,000 × 30,000 PNG is refused before decode")
    func hugeDeclaredPNGIsRefusedBeforeDecode() async throws {
        _ = await Self.refusal(ImageFixtures.png(width: 40, height: 40))   // warm the decoder
        let start = ContinuousClock.now
        let refusal = await Self.refusal(ImageFixtures.pngDeclaring(width: 30_000, height: 30_000))
        let elapsed = ContinuousClock.now - start
        #expect(["corrupt", "invalidPageDimensions"].contains(refusal), refusal == "" ? "" : "\(refusal)")
        #expect(elapsed < .milliseconds(250), "a header read, not a 900 MP decode: \(elapsed)")
    }

    @Test("A JPEG header declaring 400 MP is refused before decode")
    func fourHundredMegapixelDeclarationIsRefused() async throws {
        let start = ContinuousClock.now
        let refusal = await Self.refusal(ImageFixtures.jpegDeclaring(width: 20_000, height: 20_000))
        let elapsed = ContinuousClock.now - start
        #expect(["corrupt", "invalidPageDimensions"].contains(refusal), "\(refusal)")
        #expect(elapsed < .milliseconds(250), "\(elapsed)")
    }

    @Test("A JPEG header declaring 81 MP is read, and its decode is bounded")
    func eightyOneMegapixelDeclarationIsReadFromTheHeader() async throws {
        // 9,000 × 9,000 is inside the declared cap, so the size read passes;
        // the decode target then falls to the 25-megapixel budget.
        let data = ImageFixtures.jpegDeclaring(width: 9_000, height: 9_000)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 9_000, "the header declaration is read")
        let refusal = await Self.refusal(data)
        #expect(refusal == "open" || refusal == "corrupt", "\(refusal)")
    }

    @Test("A 20 px image is under the shortest-side floor")
    func tinyImageIsRefused() async {
        #expect(await Self.refusal(ImageFixtures.jpeg(width: 20, height: 20)) == "invalidPageDimensions")
        #expect(await Self.refusal(ImageFixtures.jpeg(width: 400, height: 41)) == "invalidPageDimensions")
        #expect(await Self.refusal(ImageFixtures.jpeg(width: 400, height: 42)) == "open")
    }

    @Test("A 51 MB stream item is refused by its byte count before decode")
    func oversizedStreamItemIsRefused() async {
        var item = Data([0xFF, 0xD8, 0xFF, 0xE0])
        item.append(Data(count: 51 * 1024 * 1024))
        do {
            _ = try await Self.loadStream([item])
            Issue.record("a 51 MB item was admitted")
        } catch {
            #expect(Self.className(error) == "tooLarge")
        }
    }

    @Test("A 51 MB image file is refused from its size on disk, unread")
    func oversizedFileIsRefusedUnread() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oversized_\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        var bytes = Data([0xFF, 0xD8, 0xFF, 0xE0])
        bytes.append(Data(count: 51 * 1024 * 1024))
        try bytes.write(to: url)
        do {
            _ = try ImportService.readPayload(from: url)
            Issue.record("a 51 MB file was read")
        } catch {
            #expect(Self.className(error) == "tooLarge")
        }
    }

    @Test("More items than one pick allows are refused")
    func twentyOneItemsAreRefused() async {
        let items = Array(repeating: ImageFixtures.jpeg(width: 60, height: 60), count: 21)
        do {
            _ = try await Self.loadStream(items)
            Issue.record("21 items were admitted")
        } catch {
            #expect(Self.className(error) == "corrupt")
        }
    }

    @Test("Cancellation between inputs surrenders with CancellationError")
    func cancellationBetweenInputs() async throws {
        let first = ImageFixtures.jpeg(width: 200, height: 150)
        let stream = AsyncThrowingStream<Data, any Error> { continuation in
            continuation.yield(first)
            // The second item never comes; the consumer is cancelled while it waits.
        }
        let loader = try ImportRouter.route(data: first)
        let task = Task {
            try await loader.load(.images(stream, count: 2, door: .photos), password: nil, limits: .standard)
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("the load completed")
        } catch {
            #expect(error is CancellationError, "\(error)")
        }
    }

    // MARK: - The format arms

    @Test("Formats outside JPEG, PNG and HEIC are refused as unsupported",
          arguments: ["gif", "webp", "tiff", "bmp", "apng", "heics", "avif"])
    func otherFormatsAreRefused(_ name: String) async {
        let data: Data
        switch name {
        case "gif": data = ImageFixtures.animatedGIF()
        case "webp": data = ImageFixtures.webp()
        case "tiff": data = ImageFixtures.tiff()
        case "bmp": data = ImageFixtures.bmp()
        case "apng": data = ImageFixtures.apng()
        case "heics": data = ImageFixtures.heics()
        default: data = ImageFixtures.avif()
        }
        #expect(await Self.refusal(data) == "unsupportedFormat", "\(name)")
    }

    @Test("A truncated JPEG or PNG is refused as damaged")
    func truncatedFilesAreCorrupt() async {
        #expect(await Self.refusal(ImageFixtures.truncatedJPEG()) == "corrupt")
        #expect(await Self.refusal(ImageFixtures.truncatedPNG()) == "corrupt")
    }

    @Test("JPEG, PNG and HEIC open through the router")
    func acceptedFormatsOpen() async throws {
        #expect(await Self.refusal(ImageFixtures.jpeg()) == "open")
        #expect(await Self.refusal(ImageFixtures.png()) == "open")
        if let heic = ImageFixtures.heic() {
            #expect(await Self.refusal(heic) == "open")
        } else {
            let url = try #require(Bundle(for: ImageFixtureBundleToken.self)
                .url(forResource: "probe-gps-depth", withExtension: "heic"))
            #expect(await Self.refusal(try Data(contentsOf: url)) == "open")
        }
    }

    @Test("The drop door admits the three image formats by their bytes and refuses the rest")
    func dropDoorAdmitsImages() {
        #expect(ImportRouter.admitsDroppedPayload(ImageFixtures.jpeg()))
        #expect(ImportRouter.admitsDroppedPayload(ImageFixtures.png()))
        // A HEIF sequence brand is a HEIC-family file at the door; the loader refuses it.
        #expect(ImportRouter.admitsDroppedPayload(ImageFixtures.heics()))
        #expect(ImportRouter.admitsDroppedPayload(ImageFixtures.webp()) == false)
        #expect(ImportRouter.admitsDroppedPayload(ImageFixtures.gif()) == false)
        #expect(ImportRouter.admitsDroppedPayload(ImageFixtures.avif()) == false)
    }
}

/// Anchors `Bundle(for:)` for the committed image fixtures.
nonisolated final class ImageFixtureBundleToken {}
