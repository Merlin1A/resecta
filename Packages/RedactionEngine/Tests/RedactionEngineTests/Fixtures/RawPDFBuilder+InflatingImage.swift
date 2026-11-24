import Compression
import Foundation

// A page whose one image is a Flate stream that inflates far past the size its
// dictionary declares. The stream is written a chunk at a time, so making the
// fixture holds a few megabytes, whatever it inflates to.

extension TestFixtures {
    /// The declared image: DeviceGray, 2550 x 3300, 8 bits (8,415,000 bytes).
    static let inflatingImageWidth = 2550
    static let inflatingImageHeight = 3300

    /// A one-page PDF: a hidden (3 Tr) text layer over a page-scale image
    /// whose FlateDecode stream inflates to `inflatedTo` bytes of 0x80.
    static func inflatingImagePage(inflatedTo count: Int) -> Data {
        flateImagePage(stream: zlibOfRepeatedByte(0x80, count: count))
    }

    /// The same page with `stream` stored as the image's FlateDecode stream,
    /// as given (its /Length is the stream's byte count).
    static func flateImagePage(stream: Data) -> Data {
        let content = Data("q 612 0 0 792 0 0 cm /Im1 Do Q BT /F1 12 Tf 3 Tr 72 700 Td (Hello probe words) Tj ET".utf8)
        let image = Data(("<< /Type /XObject /Subtype /Image /Width \(inflatingImageWidth) /Height \(inflatingImageHeight) "
            + "/ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode /Length \(stream.count) >>\nstream\n").utf8)
            + stream + Data("\nendstream".utf8)
        let objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data(("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /XObject << /Im1 4 0 R >> "
                + "/Font << /F1 6 0 R >> >> /Contents 5 0 R >>").utf8),
            image,
            Data("<< /Length \(content.count) >>\nstream\n".utf8) + content + Data("\nendstream".utf8),
            Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".utf8),
        ]
        var pdf = Data("%PDF-1.4\n%".utf8) + Data([0xE2, 0xE3, 0xCF, 0xD3, 0x0A])
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.count)
            pdf += Data("\(index + 1) 0 obj\n".utf8) + object + Data("\nendobj\n".utf8)
        }
        let xref = pdf.count
        pdf += Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8)
        for offset in offsets { pdf += Data(String(format: "%010d 00000 n \n", offset).utf8) }
        pdf += Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8)
        return pdf
    }

    /// A zlib stream (RFC 1950: header, deflate, Adler-32) of `count` bytes
    /// of `byte`, deflated a megabyte at a time. Empty if the encoder fails.
    static func zlibOfRepeatedByte(_ byte: UInt8, count: Int) -> Data {
        let chunk = 1 << 20
        let input = [UInt8](repeating: byte, count: chunk)
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { output.deallocate() }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            return Data()
        }
        defer { compression_stream_destroy(stream) }
        var deflated = Data([0x78, 0x01])
        var left = count
        let ok: Bool = input.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return false }
            stream.pointee.src_size = 0
            while true {
                if stream.pointee.src_size == 0, left > 0 {
                    let take = min(left, chunk)
                    stream.pointee.src_ptr = base
                    stream.pointee.src_size = take
                    left -= take
                }
                stream.pointee.dst_ptr = output
                stream.pointee.dst_size = chunk
                let flags = left == 0 ? Int32(bitPattern: COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                let status = compression_stream_process(stream, flags)
                deflated.append(output, count: chunk - stream.pointee.dst_size)
                if status == COMPRESSION_STATUS_END { return true }
                if status != COMPRESSION_STATUS_OK { return false }
            }
        }
        guard ok else { return Data() }
        // Adler-32 of `count` equal bytes, in closed form: A = 1 + n·v and
        // B = n + v·n(n+1)/2, both mod 65521.
        let n = UInt64(count), v = UInt64(byte), m: UInt64 = 65521
        let a = (1 + (n % m) * v) % m
        let b = (n % m + v * ((n * (n + 1) / 2) % m)) % m
        let adler = UInt32(b << 16 | a)
        deflated.append(contentsOf: [UInt8(adler >> 24), UInt8(adler >> 16 & 0xFF), UInt8(adler >> 8 & 0xFF), UInt8(adler & 0xFF)])
        return deflated
    }

    /// The byte count a zlib stream inflates to, inflated a megabyte at a
    /// time and counted, never held; nil if the stream does not decode.
    static func inflatedCount(ofZlib zlib: Data) -> Int? {
        guard zlib.count > 6 else { return nil }
        let deflate = zlib.subdata(in: 2..<(zlib.count - 4))
        let chunk = 1 << 20
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { output.deallocate() }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            return nil
        }
        defer { compression_stream_destroy(stream) }
        return deflate.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = raw.count
            var total = 0
            while true {
                stream.pointee.dst_ptr = output
                stream.pointee.dst_size = chunk
                let status = compression_stream_process(stream, Int32(bitPattern: COMPRESSION_STREAM_FINALIZE.rawValue))
                total += chunk - stream.pointee.dst_size
                if status == COMPRESSION_STATUS_END { return total }
                if status != COMPRESSION_STATUS_OK { return nil }
            }
        }
    }
}
