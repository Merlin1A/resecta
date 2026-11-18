import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
@testable import RedactionEngine

// Page pictures made for testing, encoded as the app's writer encodes a page
// (a JPEG at quality 0.92 through the system encoder), the exports the writer
// makes of them, and the named byte edits that break one rule each. No found
// document and no real data: every page is drawn here.

enum PageImageFixtures {

    /// A page of lines of dark bars on white, different for each `mark`.
    /// `noise` adds a speckle, as a scan would carry.
    static func madePage(width: Int, height: Int, gray: Bool = false, mark: Int = 0, noise: Bool = false, blank: Bool = false) -> CGImage {
        let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let info = gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: info)!
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if !blank {
            let line = max(4, height / 60)
            var y = height - 3 * line
            var n = mark
            while y > 2 * line {
                n = (n &* 1_103_515_245 &+ 12_345) & 0x7FFF_FFFF
                let length = width / 3 + n % (width / 2)
                ctx.setFillColor(gray: 0.1, alpha: 1)
                ctx.fill(CGRect(x: width / 12, y: y, width: length, height: line * 2 / 3))
                if !gray {
                    ctx.setFillColor(red: 0.7, green: 0.1, blue: 0.1, alpha: 1)
                    ctx.fill(CGRect(x: width / 12 + length + line, y: y, width: line * 3, height: line * 2 / 3))
                }
                y -= line * 2
            }
            if noise {
                var s = 7 &+ mark
                for _ in 0..<(width * height / 400) {
                    s = (s &* 1_103_515_245 &+ 12_345) & 0x7FFF_FFFF
                    ctx.setFillColor(gray: 0.6, alpha: 1)
                    ctx.fill(CGRect(x: s % width, y: (s / width) % height, width: 1, height: 1))
                }
            }
        }
        return ctx.makeImage()!
    }

    /// The picture as the writer encodes a page.
    static func encode(_ image: CGImage) -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        precondition(CGImageDestinationFinalize(dest))
        return data as Data
    }

    static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    /// An export of these pictures through the writer's draw path, one page
    /// each, Searchable when `searchable` (an empty text layer), else Secure.
    static func export(_ jpegs: [Data], size: CGSize, searchable: Bool = false) async throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("page-image-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = PDFStreamReconstructor(tempURL: url)
        try await writer.begin(firstPageSize: size)
        for jpeg in jpegs {
            await writer.appendUnencodedPageForTesting(jpegData: jpeg, size: size, textLayerEntries: searchable ? [] : nil)
        }
        await writer.finalize()
        return try Data(contentsOf: url)
    }

    /// A one-page file that draws two pictures on its page.
    static func pageWithTwoImages(_ a: Data, _ b: Data, size: CGSize) -> Data {
        let out = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        let ctx = CGContext(consumer: CGDataConsumer(data: out as CFMutableData)!, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        for (jpeg, half) in [(a, 0.0), (b, 0.5)] {
            let image = CGImage(jpegDataProviderSource: CGDataProvider(data: jpeg as CFData)!, decode: nil,
                                shouldInterpolate: false, intent: .defaultIntent)!
            ctx.draw(image, in: CGRect(x: 0, y: size.height * half, width: size.width, height: size.height / 2))
        }
        ctx.endPDFPage()
        ctx.closePDF()
        return out as Data
    }

    // MARK: - Named byte edits

    struct Segment {
        let marker: UInt8
        /// The offset of its 0xFF.
        let at: Int
        /// Its bytes, the marker included.
        let length: Int
    }

    /// The segments before the coded data, the scan's own included.
    static func segments(_ jpeg: Data) -> [Segment] {
        let b = [UInt8](jpeg)
        var out: [Segment] = []
        var i = 2
        while i + 4 <= b.count, b[i] == 0xFF {
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            out.append(Segment(marker: b[i + 1], at: i, length: length + 2))
            if b[i + 1] == 0xDA { break }
            i += length + 2
        }
        return out
    }

    static func segment(_ marker: UInt8, in jpeg: Data) -> Segment {
        segments(jpeg).first { $0.marker == marker }!
    }

    /// The coded data: after the scan's header, before the end marker.
    static func codedData(_ jpeg: Data) -> Range<Int> {
        let scan = segment(0xDA, in: jpeg)
        return (scan.at + scan.length)..<(jpeg.count - 2)
    }

    /// Offsets of the restart markers in the coded data, in order.
    static func restartMarkers(_ jpeg: Data) -> [Int] {
        let b = [UInt8](jpeg)
        return codedData(jpeg).dropLast().filter { b[$0] == 0xFF && (0xD0...0xD7).contains(b[$0 + 1]) }
    }

    static func inserting(_ bytes: [UInt8], at offset: Int, in jpeg: Data) -> Data {
        var d = jpeg
        d.insert(contentsOf: bytes, at: offset)
        return d
    }

    static func removing(_ s: Segment, from jpeg: Data) -> Data {
        var d = jpeg
        d.removeSubrange(s.at..<(s.at + s.length))
        return d
    }

    static func setting(_ offset: Int, to value: UInt8, in jpeg: Data) -> Data {
        var d = jpeg
        d[offset] = value
        return d
    }

    /// A segment of this marker whose body is `body`.
    static func segmentBytes(_ marker: UInt8, body: [UInt8]) -> [UInt8] {
        let length = body.count + 2
        return [0xFF, marker, UInt8(length >> 8), UInt8(length & 0xFF)] + body
    }
}

/// A page source that reports what it is given: for the one case the system
/// reader cannot be brought to make, a stream whose bytes are nowhere in the
/// checked file.
struct GivenPageImageSource: PageImageSource {
    let pages: [[PageImageStream]]
    var pageCount: Int { pages.count }
    func images(onPage index: Int) -> [PageImageStream] { pages[index] }
}
