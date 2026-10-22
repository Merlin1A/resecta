import Testing
import Foundation
import CoreGraphics
import PDFKit
@testable import ResectaApp
@testable import RedactionEngine

// EXIF orientation is applied once, at decode, into the page's pixels: for
// every orientation value the imported page shows the upright image (the
// marker at the top-left), the page carries no rotation, and a region
// drawn over that corner is filled by the Secure pipeline — display and
// render read the same pixels.

@Suite("Image import: orientation", .tags(.importFlow))
struct ImageImportOrientationTests {

    @Test("The fixture stores the marker away from the upright top-left for every rotated orientation")
    func fixtureHonesty() throws {
        for k in 2...8 {
            let data = ImageFixtures.orientedJPEG(k)
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            #expect(props[kCGImagePropertyOrientation] as? Int == k)
            // Read the stored pixels with no transform.
            let stored = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let ctx = CGContext(data: nil, width: stored.width, height: stored.height, bitsPerComponent: 8,
                                bytesPerRow: stored.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.draw(stored, in: CGRect(x: 0, y: 0, width: stored.width, height: stored.height))
            let samples = ImageFixtures.samples(in: ctx)
            if k == 5 {
                // A transpose keeps the top-left corner in place: the stored
                // image is the portrait transpose, told apart by its shape.
                #expect(stored.height > stored.width, "orientation 5: the stored image is transposed")
            } else {
                #expect(!ImageFixtures.isRed(samples["topLeft"]!), "orientation \(k): the stored top-left is not the marker")
            }
        }
    }

    @Test("Every EXIF orientation imports upright, with no page rotation", arguments: Array(1...8))
    func importsUpright(_ k: Int) async throws {
        let loaded = try await ImageImportLoaderTests.load(ImageFixtures.orientedJPEG(k))
        let page = try ImageImportLoaderTests.page(loaded)
        #expect(page.rotationAngle == 0)
        let box = page.getBoxRect(.mediaBox)
        #expect(box.width > box.height, "orientation \(k): the upright image is landscape")
        let samples = ImageFixtures.samples(of: page)
        #expect(ImageFixtures.isRed(samples["topLeft"]!), "orientation \(k): top-left \(samples["topLeft"]!)")
        for corner in ["topRight", "bottomLeft", "bottomRight"] {
            #expect(ImageFixtures.isWhite(samples[corner]!), "orientation \(k): \(corner) \(samples[corner]!)")
        }
    }

    @Test("A region over the upright top-left is filled and no marker pixel survives the Secure pipeline",
          arguments: Array(1...8))
    func regionOverTheMarkerIsFilled(_ k: Int) async throws {
        let loaded = try await ImageImportLoaderTests.load(ImageFixtures.orientedJPEG(k))
        let page = try #require(loaded.document.document.page(at: 0))
        // Normalized rects have a bottom-left origin: the left 30 % of the page, full height.
        let region = RedactionRegion(id: UUID(), normalizedRect: CGRect(x: 0, y: 0, width: 0.3, height: 1), source: .manual)
        let pageData = PDFPageData(
            page: page, pageIndex: 0, regions: [region], fillColor: .black, targetDPI: 150,
            pipelineMode: .secureRasterization, rotation: page.rotation,
            cropBoxBounds: page.bounds(for: .cropBox), cgPage: page.pageRef, hasText: false)
        let result = try await PageRasterizer().rasterize(pageData)
        let image = result.pageOutput.image
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let samples = ImageFixtures.samples(in: ctx)
        let topLeft = samples["topLeft"]!
        #expect(topLeft.0 < 40 && topLeft.1 < 40 && topLeft.2 < 40, "orientation \(k): the fill at the top-left \(topLeft)")
        #expect(ImageFixtures.isWhite(samples["topRight"]!), "orientation \(k): \(samples["topRight"]!)")
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var red = 0
        for y in 0..<image.height { for x in 0..<image.width {
            let o = y * ctx.bytesPerRow + x * 4
            if ImageFixtures.isRed((Int(p[o]), Int(p[o + 1]), Int(p[o + 2]))) { red += 1 }
        } }
        #expect(red == 0, "orientation \(k): \(red) marker pixels survive")
    }
}
