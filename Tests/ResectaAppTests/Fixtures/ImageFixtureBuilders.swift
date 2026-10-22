import Foundation
import CoreGraphics
import ImageIO
import UIKit
import UniformTypeIdentifiers

// Image fixtures for the import tests, built in memory by ImageIO and by
// hand. Every builder is deterministic. The marker convention: a white
// field with a red block covering the top-left 20 % of the UPRIGHT image,
// so an orientation or a thumbnail mistake shows as the marker moving.

enum ImageFixtures {

    static let canary = "RESECTA-FIXTURE-CANARY-7731"

    // MARK: - Bitmaps

    /// An sRGB 8-bit RGBX bitmap: white, with the red marker when asked and
    /// a line of drawn text when given.
    static func bitmap(width: Int, height: Int, marker: Bool = true, text: String? = nil) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if marker {
            ctx.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
            // CoreGraphics origin is bottom-left: the top-left block sits at y = 0.8 h.
            ctx.fill(CGRect(x: 0, y: CGFloat(height) * 0.8, width: CGFloat(width) * 0.2, height: CGFloat(height) * 0.2))
        }
        if let text {
            UIGraphicsPushContext(ctx)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)
            let font = UIFont.systemFont(ofSize: CGFloat(min(width, height)) / 10, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
            (text as NSString).draw(at: CGPoint(x: CGFloat(width) * 0.3, y: CGFloat(height) * 0.45), withAttributes: attrs)
            ctx.restoreGState()
            UIGraphicsPopContext()
        }
        return ctx.makeImage()!
    }

    static func encode(_ image: CGImage, as type: UTType, properties: [CFString: Any] = [:], quality: Double = 0.9) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        var props = properties
        props[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    // MARK: - The accepted formats

    static func jpeg(width: Int = 400, height: Int = 300, marker: Bool = true, text: String? = nil) -> Data {
        encode(bitmap(width: width, height: height, marker: marker, text: text), as: .jpeg)!
    }

    static func png(width: Int = 400, height: Int = 300, marker: Bool = true) -> Data {
        encode(bitmap(width: width, height: height, marker: marker), as: .png)!
    }

    /// A PNG with an alpha channel: a transparent field with one opaque
    /// black block in the centre. The loader flattens it on white.
    static func alphaPNG(width: Int = 200, height: Int = 200) -> Data {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: CGFloat(width) * 0.4, y: CGFloat(height) * 0.4, width: CGFloat(width) * 0.2, height: CGFloat(height) * 0.2))
        return encode(ctx.makeImage()!, as: .png)!
    }

    /// HEIC through ImageIO; nil where the runtime has no HEIC encoder.
    static func heic(width: Int = 400, height: Int = 300, marker: Bool = true, text: String? = nil,
                     properties: [CFString: Any] = [:]) -> Data? {
        encode(bitmap(width: width, height: height, marker: marker, text: text), as: .heic, properties: properties)
    }

    // MARK: - Metadata carriers

    static var gpsDictionary: [CFString: Any] {
        [kCGImagePropertyGPSLatitude: 41.7658, kCGImagePropertyGPSLatitudeRef: "N",
         kCGImagePropertyGPSLongitude: 72.6734, kCGImagePropertyGPSLongitudeRef: "W"]
    }

    static var probeProperties: [CFString: Any] {
        [kCGImagePropertyGPSDictionary: gpsDictionary,
         kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: canary,
                                          kCGImagePropertyExifDateTimeOriginal: "2024:01:01 12:00:00"],
         kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "FixtureMake", kCGImagePropertyTIFFModel: "FixtureModel"]]
    }

    /// A JPEG carrying GPS, a UserComment canary and a TIFF make/model.
    static func jpegWithProbes(width: Int = 400, height: Int = 300) -> Data {
        encode(bitmap(width: width, height: height), as: .jpeg, properties: probeProperties)!
    }

    /// A HEIC carrying GPS, the canary and a disparity auxiliary image.
    static func heicWithProbesAndDepth(width: Int = 400, height: Int = 300) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.heic.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, bitmap(width: width, height: height), probeProperties as CFDictionary)
        let dw = 64, dh = 48
        let depth = CGContext(data: nil, width: dw, height: dh, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        depth.setFillColor(gray: 0.5, alpha: 1)
        depth.fill(CGRect(x: 0, y: 0, width: dw, height: dh))
        let desc: [CFString: Any] = [
            kCGImagePropertyWidth: dw, kCGImagePropertyHeight: dh,
            kCGImagePropertyBytesPerRow: depth.bytesPerRow,
            kCGImagePropertyPixelFormat: kCVPixelFormatType_DisparityFloat16 as UInt32]
        let info: [CFString: Any] = [
            kCGImageAuxiliaryDataInfoData: Data(bytes: depth.data!, count: depth.bytesPerRow * dh),
            kCGImageAuxiliaryDataInfoDataDescription: desc]
        CGImageDestinationAddAuxiliaryDataInfo(dest, kCGImageAuxiliaryDataTypeDisparity, info as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// A JPEG whose primary image is plain white and whose EXIF thumbnail
    /// still shows the red marker: the APP1 segment of a marker JPEG written
    /// with an embedded thumbnail is spliced into a white JPEG.
    static func staleThumbnailJPEG(width: Int = 400, height: Int = 300) -> Data {
        let withThumb = encode(bitmap(width: width, height: height, marker: true), as: .jpeg,
                               properties: [kCGImageDestinationEmbedThumbnail: true])!
        let white = encode(bitmap(width: width, height: height, marker: false), as: .jpeg)!
        guard let app1 = segment(0xE1, in: withThumb) else { return white }
        var out = Data(white.prefix(2))          // SOI
        out.append(app1)
        out.append(white.dropFirst(2))
        return out
    }

    /// The first segment of the given marker byte (FF xx) in a JPEG stream.
    static func segment(_ marker: UInt8, in jpeg: Data) -> Data? {
        let b = [UInt8](jpeg)
        var i = 2
        while i + 4 <= b.count, b[i] == 0xFF {
            let m = b[i + 1]
            if m == 0xDA { return nil }           // start of scan: no more headers
            let len = Int(b[i + 2]) << 8 | Int(b[i + 3])
            if m == marker { return Data(b[i..<min(b.count, i + 2 + len)]) }
            i += 2 + len
        }
        return nil
    }

    // MARK: - Orientation

    /// A JPEG whose stored pixels are the upright marker image transformed
    /// by the inverse of EXIF orientation `k`, tagged with `k`: a reader
    /// that honours the tag shows the marker at the top-left.
    static func orientedJPEG(_ k: Int, width: Int = 400, height: Int = 300) -> Data {
        let upright = bitmap(width: width, height: height)
        let stored = transformed(upright, inverseOf: k)
        return encode(stored, as: .jpeg, properties: [kCGImagePropertyOrientation: k])!
    }

    /// Applies the inverse of EXIF orientation `k` to an RGBX bitmap, pixel
    /// by pixel (the EXIF table: 1 as is · 2 mirror horizontal · 3 rotate
    /// 180 · 4 mirror vertical · 5 transpose · 6 rotate 90 clockwise ·
    /// 7 transverse · 8 rotate 90 counter-clockwise, each describing how
    /// the stored pixels reach the upright view).
    static func transformed(_ image: CGImage, inverseOf k: Int) -> CGImage {
        let w = image.width, h = image.height
        let src = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        src.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let swap = k >= 5
        let ow = swap ? h : w, oh = swap ? w : h
        let dst = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: ow * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let s = src.data!.assumingMemoryBound(to: UInt32.self)
        let d = dst.data!.assumingMemoryBound(to: UInt32.self)
        // Row 0 of a CGContext bitmap is the top row. For each upright pixel
        // (x, y) the stored position is where orientation k would read it from.
        for y in 0..<h {
            for x in 0..<w {
                let (sx, sy): (Int, Int)
                switch k {
                case 2: (sx, sy) = (w - 1 - x, y)
                case 3: (sx, sy) = (w - 1 - x, h - 1 - y)
                case 4: (sx, sy) = (x, h - 1 - y)
                case 5: (sx, sy) = (y, x)
                case 6: (sx, sy) = (y, w - 1 - x)
                case 7: (sx, sy) = (h - 1 - y, w - 1 - x)
                case 8: (sx, sy) = (h - 1 - y, x)
                default: (sx, sy) = (x, y)
                }
                d[sy * ow + sx] = s[y * w + x]
            }
        }
        return dst.makeImage()!
    }

    // MARK: - Declared sizes without the pixels

    /// A PNG whose IHDR declares the given size over a tiny IDAT; ImageIO
    /// reports the dimensions without decoding.
    static func pngDeclaring(width: UInt32, height: UInt32) -> Data {
        var d = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var ihdr = Data()
        ihdr.append(contentsOf: bigEndian(width)); ihdr.append(contentsOf: bigEndian(height))
        ihdr.append(contentsOf: [8, 2, 0, 0, 0])          // 8-bit RGB
        d.append(chunk("IHDR", ihdr))
        d.append(chunk("IDAT", Data([0x78, 0x9C, 0x63, 0x60, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01])))
        d.append(chunk("IEND", Data()))
        return d
    }

    private static func bigEndian(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    private static func chunk(_ type: String, _ body: Data) -> Data {
        var c = Data(bigEndian(UInt32(body.count)))
        var crcInput = Data(type.utf8); crcInput.append(body)
        c.append(crcInput)
        c.append(contentsOf: bigEndian(crc32(crcInput)))
        return c
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB88320 & (0 &- (crc & 1))) }
        }
        return ~crc
    }

    // MARK: - The refused formats

    static func gif() -> Data { animatedGIF(frames: 1) }

    static func animatedGIF(frames: Int = 3) -> Data {
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.gif.identifier as CFString, frames, nil)!
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for i in 0..<frames {
            CGImageDestinationAddImage(dest, bitmap(width: 40, height: 40 + i), [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    /// An animated PNG, built by hand from a still PNG: an `acTL` chunk, a
    /// frame control before the image data and a second frame as `fdAT`.
    static func apng() -> Data {
        let still = png(width: 40, height: 40)
        var ihdr = Data(), idat = Data()
        var i = 8
        let b = [UInt8](still)
        while i + 8 <= b.count {
            let len = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
            let type = String(decoding: b[(i + 4)..<(i + 8)], as: UTF8.self)
            let body = Data(b[(i + 8)..<(i + 8 + len)])
            if type == "IHDR" { ihdr = body } else if type == "IDAT" { idat.append(body) }
            i += 12 + len
        }
        func frameControl(_ sequence: UInt32) -> Data {
            var f = Data(bigEndian(sequence))
            f.append(contentsOf: bigEndian(40)); f.append(contentsOf: bigEndian(40))
            f.append(contentsOf: bigEndian(0)); f.append(contentsOf: bigEndian(0))
            f.append(contentsOf: [0, 1, 0, 10, 0, 0])   // delay 1/10 s, dispose none, blend source
            return f
        }
        var d = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        d.append(chunk("IHDR", ihdr))
        var actl = Data(bigEndian(2)); actl.append(contentsOf: bigEndian(0))
        d.append(chunk("acTL", actl))
        d.append(chunk("fcTL", frameControl(0)))
        d.append(chunk("IDAT", idat))
        d.append(chunk("fcTL", frameControl(1)))
        var fdat = Data(bigEndian(2)); fdat.append(idat)
        d.append(chunk("fdAT", fdat))
        d.append(chunk("IEND", Data()))
        return d
    }

    /// A PNG cut off before its IEND chunk.
    static func truncatedPNG() -> Data {
        let full = png(width: 300, height: 200)
        return full.prefix(full.count * 6 / 10)
    }

    /// A small JPEG whose frame header declares the given size: Image I/O
    /// reports the declared size from the header alone.
    static func jpegDeclaring(width: Int, height: Int) -> Data {
        var p = [UInt8](jpeg(width: 64, height: 48, marker: false))
        var i = 2
        while i + 8 < p.count {
            if p[i] == 0xFF, p[i + 1] == 0xC0 || p[i + 1] == 0xC2 {
                p[i + 5] = UInt8(height >> 8); p[i + 6] = UInt8(height & 0xFF)
                p[i + 7] = UInt8(width >> 8); p[i + 8] = UInt8(width & 0xFF)
                break
            }
            let len = Int(p[i + 2]) << 8 | Int(p[i + 3])
            i += 2 + len
        }
        return Data(p)
    }

    static func tiff() -> Data { encode(bitmap(width: 40, height: 40), as: .tiff)! }

    /// A hand-built 1 × 1 24-bit BMP.
    static func bmp() -> Data {
        var d = Data("BM".utf8)
        d.append(contentsOf: [58, 0, 0, 0, 0, 0, 0, 0, 54, 0, 0, 0])           // size · reserved · pixel offset
        d.append(contentsOf: [40, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 24, 0]) // DIB header: 1 × 1, 24 bpp
        d.append(contentsOf: [UInt8](repeating: 0, count: 24))
        d.append(contentsOf: [255, 255, 255, 0])
        return d
    }

    /// A minimal WebP (a 1 × 1 VP8L bitstream in a RIFF container).
    static func webp() -> Data {
        let vp8l: [UInt8] = [0x2F, 0x00, 0x00, 0x00, 0x00, 0x07, 0x10, 0x11, 0x11, 0x88, 0x88, 0xFE, 0x07, 0x00]
        var chunk = Data("VP8L".utf8); chunk.append(contentsOf: le32(UInt32(vp8l.count))); chunk.append(contentsOf: vp8l)
        var d = Data("RIFF".utf8); d.append(contentsOf: le32(UInt32(4 + chunk.count))); d.append(Data("WEBP".utf8)); d.append(chunk)
        return d
    }

    /// An ISO BMFF header with the HEIF image-sequence brand and no usable
    /// boxes beyond it: the router reads a HEIC family file, ImageIO does not
    /// report a still image.
    static func heics() -> Data { ftyp(brand: "hevc", compatible: ["msf1", "hevc", "iso8"]) }

    /// An ISO BMFF header with the AVIF brand.
    static func avif() -> Data { ftyp(brand: "avif", compatible: ["avif", "mif1", "miaf"]) }

    private static func ftyp(brand: String, compatible: [String]) -> Data {
        var box = Data(brand.utf8); box.append(contentsOf: [0, 0, 0, 0])
        for c in compatible { box.append(Data(c.utf8)) }
        var d = Data(bigEndian(UInt32(8 + box.count))); d.append(Data("ftyp".utf8)); d.append(box)
        d.append(Data(bigEndian(16))); d.append(Data("mdat".utf8)); d.append(Data(repeating: 0, count: 8))
        return d
    }

    /// A JPEG cut off before its end-of-image marker.
    static func truncatedJPEG() -> Data {
        let full = jpeg(width: 600, height: 400, text: "CUT")
        return full.prefix(full.count * 6 / 10)
    }

    private static func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
    }

    // MARK: - Reading pixels back

    /// Renders a PDF page at the given width and samples the four corners
    /// (5 % in from each edge) plus the centre, as (r, g, b) in 0...255.
    static func samples(of page: CGPDFPage, width: Int = 200) -> [String: (Int, Int, Int)] {
        let box = page.getBoxRect(.mediaBox)
        let height = max(1, Int((CGFloat(width) * box.height / box.width).rounded()))
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: CGFloat(width) / box.width, y: CGFloat(height) / box.height)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.drawPDFPage(page)
        return samples(in: ctx)
    }

    static func samples(in ctx: CGContext) -> [String: (Int, Int, Int)] {
        let w = ctx.width, h = ctx.height
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        func px(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            // The bitmap's row 0 is the top row, so (x, y) is in image coordinates.
            let o = y * ctx.bytesPerRow + x * 4
            return (Int(p[o]), Int(p[o + 1]), Int(p[o + 2]))
        }
        let dx = max(1, w / 20), dy = max(1, h / 20)
        return ["topLeft": px(dx, dy), "topRight": px(w - 1 - dx, dy),
                "bottomLeft": px(dx, h - 1 - dy), "bottomRight": px(w - 1 - dx, h - 1 - dy),
                "centre": px(w / 2, h / 2)]
    }

    static func isRed(_ s: (Int, Int, Int)) -> Bool { s.0 > 180 && s.1 < 90 && s.2 < 90 }
    static func isWhite(_ s: (Int, Int, Int)) -> Bool { s.0 > 235 && s.1 > 235 && s.2 > 235 }

    /// Every red pixel in a rendered page, counted over a coarse grid.
    static func redPixelCount(of page: CGPDFPage, width: Int = 200) -> Int {
        let box = page.getBoxRect(.mediaBox)
        let height = max(1, Int((CGFloat(width) * box.height / box.width).rounded()))
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: CGFloat(width) / box.width, y: CGFloat(height) / box.height)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.drawPDFPage(page)
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var n = 0
        for y in 0..<height { for x in 0..<width {
            let o = y * ctx.bytesPerRow + x * 4
            if isRed((Int(p[o]), Int(p[o + 1]), Int(p[o + 2]))) { n += 1 }
        } }
        return n
    }
}
