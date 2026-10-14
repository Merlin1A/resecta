import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import RedactionEngine

// The first-render bitmap. Each render body draws the page into a fresh
// bitmap context, hands back the image made from it and releases the
// context; the context's bytes must read zero at that release, while the
// image handed back keeps its pixels (`makeImage()` copies, pinned by
// `PixelBufferZeroizeTests`).

@Suite("First-render bitmap wipe", .tags(.security))
struct FirstRenderBitmapWipeTests {

    /// Collects what the release probe sees.
    private final class Observation: @unchecked Sendable {
        var probed = 0
        var nonZeroSamples = 0
    }

    /// Sample every 97th byte of the context's backing store.
    private static func observe(_ observation: Observation) -> @Sendable (CGContext) -> Void {
        { context in
            observation.probed += 1
            guard let data = context.data else { return }
            let count = context.bytesPerRow * context.height
            let bytes = data.assumingMemoryBound(to: UInt8.self)
            for offset in stride(from: 0, to: count, by: 97) where bytes[offset] != 0 {
                observation.nonZeroSamples += 1
            }
        }
    }

    /// The centre pixel of `image` drawn into a fresh probe context.
    private func centrePixel(of image: CGImage) throws -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
        let probe = try #require(createBitmapContext(width: image.width, height: image.height))
        probe.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = probe.data!.assumingMemoryBound(to: UInt8.self)
        let offset = (image.height / 2) * probe.bytesPerRow + (image.width / 2) * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
    }

    @Test("renderPage releases its bitmap context zeroed and hands back an image that keeps its pixels")
    func renderPageWipesItsContext() async throws {
        let doc = try #require(PDFDocument(data: TestFixtures.blankPage()))
        let page = try #require(doc.page(at: 0))
        let observation = Observation()

        let image = try await PageRasterizer.$renderContextWipeProbe.withValue(Self.observe(observation)) {
            try await PageRasterizer().renderPage(page, pageIndex: 0, dpi: 36)
        }

        #expect(observation.probed == 1)
        #expect(observation.nonZeroSamples == 0, "the render context must read zero at its release")
        let pixel = try centrePixel(of: image)
        #expect(pixel == (255, 255, 255, 255), "the white page survives in the image handed back")
    }

    @Test("renderPageFromCGPage releases its bitmap context zeroed and hands back an image that keeps its pixels")
    func renderPageFromCGPageWipesItsContext() async throws {
        let doc = try #require(PDFDocument(data: TestFixtures.blankPage()))
        let page = try #require(doc.page(at: 0))
        let cgPage = try #require(page.pageRef)
        let observation = Observation()

        let image = try await PageRasterizer.$renderContextWipeProbe.withValue(Self.observe(observation)) {
            try await PageRasterizer().renderPageFromCGPage(
                cgPage, bounds: page.bounds(for: .cropBox), rotation: page.rotation,
                pageIndex: 0, dpi: 36)
        }

        #expect(observation.probed == 1)
        #expect(observation.nonZeroSamples == 0, "the render context must read zero at its release")
        let pixel = try centrePixel(of: image)
        #expect(pixel == (255, 255, 255, 255), "the white page survives in the image handed back")
    }
}
