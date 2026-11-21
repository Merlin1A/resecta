import CryptoKit
import Foundation

// Page pictures and files coded by hand, byte by byte, for the cases a system
// encoder never makes: a first coefficient run past any 8-bit picture, a scan
// header cut at the end of the stream, forms named past the reader's limits.
// Every picture is one component, eight bits, baseline, with tables written
// here: a first-coefficient table that codes each size 0...11 in four bits,
// and a table for the other coefficients that holds only the end of the block
// and one coefficient of size one.

enum CraftedPageImages {

    /// One block: the difference of its first coefficient from the block
    /// before, and whether its second coefficient is one (else every other is 0).
    struct Block {
        let difference: Int
        var second = false
    }

    private struct BitWriter {
        var bytes: [UInt8] = []
        var acc = 0
        var count = 0

        mutating func put(_ value: Int, _ bits: Int) {
            guard bits > 0 else { return }
            for i in stride(from: bits - 1, through: 0, by: -1) {
                acc = (acc << 1) | ((value >> i) & 1)
                count += 1
                if count == 8 {
                    bytes.append(UInt8(acc))
                    if acc == 0xFF { bytes.append(0) }
                    acc = 0
                    count = 0
                }
            }
        }

        /// Fills the last byte with ones, as the standard pads.
        mutating func finish() {
            if count > 0 { put((1 << (8 - count)) - 1, 8 - count) }
        }
    }

    private static func segment(_ marker: UInt8, _ body: [UInt8]) -> [UInt8] {
        let length = body.count + 2
        return [0xFF, marker, UInt8(length >> 8), UInt8(length & 0xFF)] + body
    }

    /// Every segment up to the scan's header, for a picture of `columns` by
    /// `rows` blocks whose every step is `step`. The first-coefficient table
    /// holds `dcFourBitCodes` codes of four bits (sizes 0 on), 12 by default;
    /// at 16 its last code is all ones.
    static func header(columns: Int, rows: Int, step: UInt8, dcFourBitCodes: Int = 12) -> [UInt8] {
        let width = 8 * columns, height = 8 * rows
        var out: [UInt8] = [0xFF, 0xD8]
        out += segment(0xE0, Array("JFIF\0".utf8) + [1, 1, 0, 0, 1, 0, 1, 0, 0])
        out += segment(0xDB, [0x00] + [UInt8](repeating: step, count: 64))
        var dcCounts = [UInt8](repeating: 0, count: 16)
        dcCounts[3] = UInt8(dcFourBitCodes) // codes of four bits: size n is coded as n
        out += segment(0xC4, [0x00] + dcCounts + (0..<dcFourBitCodes).map { UInt8($0) })
        var acCounts = [UInt8](repeating: 0, count: 16)
        acCounts[1] = 2 // 00: end of block; 01: run 0, size 1
        out += segment(0xC4, [0x10] + acCounts + [0x00, 0x01])
        out += segment(0xC0, [8, UInt8(height >> 8), UInt8(height & 0xFF), UInt8(width >> 8), UInt8(width & 0xFF),
                              1, 1, 0x11, 0])
        return out
    }

    /// A whole picture of `columns` by `rows` blocks, in raster order.
    static func picture(columns: Int, rows: Int, step: UInt8, blocks: [Block], dcFourBitCodes: Int = 12) -> Data {
        precondition(blocks.count == columns * rows)
        var w = BitWriter()
        for block in blocks {
            let magnitude = abs(block.difference)
            let size = magnitude == 0 ? 0 : Int.bitWidth - magnitude.leadingZeroBitCount
            w.put(size, 4)
            w.put(block.difference >= 0 ? block.difference : block.difference + (1 << size) - 1, size)
            if block.second {
                w.put(0b01, 2)
                w.put(1, 1)
            }
            w.put(0b00, 2)
        }
        w.finish()
        let scan = segment(0xDA, [1, 1, 0x00, 0, 63, 0])
        return Data(header(columns: columns, rows: rows, step: step, dcFourBitCodes: dcFourBitCodes)
                    + scan + w.bytes + [0xFF, 0xD9])
    }

    // MARK: - A file whose page names forms

    /// One form: the forms it names, by index in the file's list, and
    /// whether it names the page's picture again.
    struct Form {
        var names: [Int] = []
        var namesPicture = false
    }

    /// A one-page file whose page draws `picture` and names `pageForms`
    /// (indices into `forms`). Written by hand: a system writer makes no
    /// form that names itself. The picture's stream is stored as given under
    /// `filter` (the writer's own is /DCTDecode alone).
    static func formsPage(picture: Data, columns: Int, rows: Int, pageForms: [Int], forms: [Form],
                          filter: String = "/DCTDecode") -> Data {
        // Objects: 1 catalog, 2 pages, 3 page, 4 picture, 5 content, 6... forms.
        func formRef(_ i: Int) -> String { "\(6 + i) 0 R" }
        func xobjects(_ names: [Int], picture: Bool) -> String {
            var entries = names.enumerated().map { "/F\($0.offset) \(formRef($0.element))" }
            if picture { entries.append("/Im0 4 0 R") }
            return "<< " + entries.joined(separator: " ") + " >>"
        }
        var objects: [Data] = []
        objects.append(Data("<< /Type /Catalog /Pages 2 0 R >>".utf8))
        objects.append(Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8))
        objects.append(Data(("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R "
                             + "/Resources << /XObject \(xobjects(pageForms, picture: true)) >> >>").utf8))
        var image = Data(("<< /Type /XObject /Subtype /Image /Width \(8 * columns) /Height \(8 * rows) "
                          + "/ColorSpace /DeviceGray /BitsPerComponent 8 /Filter \(filter) /Length \(picture.count) >>\nstream\n").utf8)
        image += picture
        image += Data("\nendstream".utf8)
        objects.append(image)
        let content = "q 612 0 0 792 0 0 cm /Im0 Do Q"
        objects.append(Data("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream".utf8))
        for form in forms {
            objects.append(Data(("<< /Type /XObject /Subtype /Form /BBox [0 0 1 1] "
                                 + "/Resources << /XObject \(xobjects(form.names, picture: form.namesPicture)) >> "
                                 + "/Length 0 >>\nstream\n\nendstream").utf8))
        }
        var file = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        for (i, body) in objects.enumerated() {
            offsets.append(file.count)
            file += Data("\(i + 1) 0 obj\n".utf8) + body + Data("\nendobj\n".utf8)
        }
        let xref = file.count
        file += Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8)
        for offset in offsets { file += Data(String(format: "%010d 00000 n \n", offset).utf8) }
        file += Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8)
        return file
    }

    static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    /// `data` as a zlib stream of stored (uncompressed) blocks, as /FlateDecode
    /// reads it: header, blocks of at most 65,535 bytes, Adler-32.
    static func zlibStored(_ data: Data) -> Data {
        var out: [UInt8] = [0x78, 0x01]
        let bytes = [UInt8](data)
        var start = 0
        repeat {
            let n = min(65_535, bytes.count - start)
            let last: UInt8 = start + n == bytes.count ? 1 : 0
            out += [last, UInt8(n & 0xFF), UInt8(n >> 8), UInt8(~n & 0xFF), UInt8((~n >> 8) & 0xFF)]
            out += bytes[start..<(start + n)]
            start += n
        } while start < bytes.count
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in bytes { a = (a + UInt32(byte)) % 65_521; b = (b + a) % 65_521 }
        let adler = (b << 16) | a
        out += [UInt8(adler >> 24), UInt8((adler >> 16) & 0xFF), UInt8((adler >> 8) & 0xFF), UInt8(adler & 0xFF)]
        return Data(out)
    }
}
