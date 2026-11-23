import Compression
import CoreGraphics
import CoreText
import Foundation
import PDFKit
@testable import RedactionEngine

// Made pages for the ink fit on scans stored in pieces and on pages whose text
// lies under pictures: three printed lines rendered as an 8-bit gray picture
// with no alpha, no soft mask and no mask, stored whole, in strips, in tiles or
// as inline images, under a text layer at the unshifted positions. Typed pages
// for the rows that must not change are written beside them. Invented text.

enum PiecewiseScan {
    static let page = CGSize(width: 612, height: 792)
    static let pointSize: CGFloat = 14
    static let lines: [(String, CGFloat, CGFloat)] = [
        ("Account holder MARISOL QUENTIN", 100, 700),
        ("Payee HALVERSON TIMBER", 100, 670),
        ("Reference 5193 Duluth Minnesota", 100, 640),
    ]
    static let word = "QUENTIN"
    /// Words whose boxes a strip scan and its one-image twin are compared on.
    static let words = ["QUENTIN", "HALVERSON", "Duluth"]

    static var font: CTFont { CTFontCreateWithName("Helvetica" as CFString, pointSize, nil) }

    static func width(_ s: String) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        return CGFloat(CTLineGetTypographicBounds(
            CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attributes)), nil, nil, nil))
    }

    /// Half the word's width: how far "half a word off" moves the print along its line.
    static var halfWord: CGFloat { (width(word) / 2).rounded() }

    /// The word's own ink on a page printed at `shift`, in points, from the font's metrics.
    static func wordInk(shift: CGFloat) -> CGRect {
        CGRect(x: 100 + shift + width("Account holder MARISOL "), y: 700 - CTFontGetDescent(font),
               width: width(word), height: CTFontGetAscent(font) + CTFontGetDescent(font))
    }

    // MARK: - Pictures

    /// An 8-bit gray picture, its first row at the top.
    struct Gray {
        var width: Int
        var height: Int
        var pixels: [UInt8]

        init(width: Int, height: Int, value: UInt8 = 255) {
            self.width = width; self.height = height
            pixels = [UInt8](repeating: value, count: width * height)
        }

        /// The rows `rows` and columns `columns`.
        func piece(rows: Range<Int>, columns: Range<Int>) -> Gray {
            var out = Gray(width: columns.count, height: rows.count)
            for (j, r) in rows.enumerated() {
                for (i, c) in columns.enumerated() { out.pixels[j * out.width + i] = pixels[r * width + c] }
            }
            return out
        }

        /// The picture stored turned a quarter clockwise: drawn under
        /// `turnedPlacement`, it shows as the picture itself.
        func turnedClockwise() -> Gray {
            var out = Gray(width: height, height: width)
            for r in 0..<out.height {
                for c in 0..<out.width { out.pixels[r * out.width + c] = pixels[(height - 1 - c) * width + r] }
            }
            return out
        }
    }

    /// The three lines printed black on white at `dpi`, moved `shift` points along their line.
    static func print(dpi: CGFloat, shift: CGFloat) -> Gray {
        let scale = dpi / 72
        var gray = Gray(width: Int(page.width * scale), height: Int(page.height * scale))
        let w = gray.width, h = gray.height
        gray.pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return }
            ctx.scaleBy(x: scale, y: scale)
            for (text, x, y) in lines {
                let attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
                ]
                ctx.textPosition = CGPoint(x: x + shift, y: y)
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), ctx)
            }
        }
        return gray
    }

    /// A picture of rising gray, for photographs, stationery and logos.
    static func shade(width: Int, height: Int, light: Bool = false) -> Gray {
        var gray = Gray(width: width, height: height)
        for r in 0..<height {
            for c in 0..<width { gray.pixels[r * width + c] = UInt8(light ? 200 + (r + c) % 50 : (r * 3 + c * 5) % 200) }
        }
        return gray
    }

    /// Bytes zlib-encoded, as `/FlateDecode` reads them.
    static func flate(_ bytes: [UInt8]) -> Data {
        var deflated = [UInt8](repeating: 0, count: bytes.count + 4096)
        let n = compression_encode_buffer(&deflated, deflated.count, bytes, bytes.count, nil, COMPRESSION_ZLIB)
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in bytes { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        let adler = (b << 16) | a
        var out = Data([0x78, 0x9C])
        out.append(contentsOf: deflated[0..<n])
        out.append(contentsOf: [UInt8(adler >> 24), UInt8((adler >> 16) & 0xFF), UInt8((adler >> 8) & 0xFF), UInt8(adler & 0xFF)])
        return out
    }

    static func n(_ v: CGFloat) -> String { String(format: "%.5f", Double(v)) }

    // MARK: - Documents

    /// An object of a made page: a dictionary, and a stream when it has one.
    /// In the dictionary, `@k@` names the page's own k-th object.
    struct Object {
        var dictionary: String
        var stream: Data?
    }

    static func image(_ g: Gray, extra: String = "") -> Object {
        Object(dictionary: "/Type /XObject /Subtype /Image /Width \(g.width) /Height \(g.height) /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode \(extra)",
               stream: flate(g.pixels))
    }

    static func form(_ content: String, resources: String, extra: String = "") -> Object {
        Object(dictionary: "/Type /XObject /Subtype /Form /BBox [0 0 612 792] /Resources << \(resources) >> \(extra)",
               stream: Data(content.utf8))
    }

    /// One page: its content, its resources (the font `/F1` is added), its own
    /// objects, its turn, and its size (a letter page unless set).
    struct Page {
        var content: Data
        var resources: String = ""
        var objects: [Object] = []
        var rotate: Int = 0
        var contentEntries: String = ""
        var size: CGSize = PiecewiseScan.page

        init(_ content: String, resources: String = "", objects: [Object] = [], rotate: Int = 0) {
            self.content = Data(content.utf8); self.resources = resources; self.objects = objects; self.rotate = rotate
        }
    }

    static func document(_ pages: [Page]) -> Data {
        var bodies: [Data] = []
        func add(_ d: Data) { bodies.append(d) }
        add(Data("<< /Type /Catalog /Pages 2 0 R >>".utf8))
        bodies.append(Data()) // the page tree, written below
        add(Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>".utf8))
        var kids: [Int] = []
        for page in pages {
            let pageNumber = bodies.count + 1, contentNumber = pageNumber + 1, first = pageNumber + 2
            func refs(_ s: String) -> String {
                var out = s
                for k in stride(from: page.objects.count - 1, through: 0, by: -1) {
                    out = out.replacingOccurrences(of: "@\(k)@", with: "\(first + k) 0 R")
                }
                return out
            }
            kids.append(pageNumber)
            let turn = page.rotate == 0 ? "" : " /Rotate \(page.rotate)"
            add(Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(n(page.size.width)) \(n(page.size.height))]\(turn) /Contents \(contentNumber) 0 R /Resources << /Font << /F1 3 0 R >> \(refs(page.resources)) >> >>".utf8))
            var content = Data("<< /Length \(page.content.count) \(page.contentEntries) >>\nstream\n".utf8)
            content.append(page.content); content.append(Data("\nendstream".utf8))
            add(content)
            for object in page.objects {
                guard let stream = object.stream else { add(Data("<< \(refs(object.dictionary)) >>".utf8)); continue }
                var d = Data("<< \(refs(object.dictionary)) /Length \(stream.count) >>\nstream\n".utf8)
                d.append(stream); d.append(Data("\nendstream".utf8))
                add(d)
            }
        }
        bodies[1] = Data("<< /Type /Pages /Kids [\(kids.map { "\($0) 0 R" }.joined(separator: " "))] /Count \(pages.count) >>".utf8)
        var out = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (i, body) in bodies.enumerated() {
            offsets.append(out.count)
            out.append(Data("\(i + 1) 0 obj\n".utf8)); out.append(body); out.append(Data("\nendobj\n".utf8))
        }
        let xref = out.count
        out.append(Data("xref\n0 \(bodies.count + 1)\n0000000000 65535 f \n".utf8))
        for o in offsets { out.append(Data(String(format: "%010d 00000 n \n", o).utf8)) }
        out.append(Data("trailer\n<< /Size \(bodies.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return out
    }

    /// A made document opened as the app opens one: a new ink-fit session
    /// first, so its pages never share a fit key with an earlier made
    /// document's page of the same text and largest picture (two strip scans
    /// whose top strip is blank, for one).
    static func pdfPage(_ data: Data, at index: Int = 0) -> (PDFDocument, PDFPage, CGPDFPage)? {
        DocumentSearcher.startNewInkFitSession()
        guard let document = PDFDocument(data: data), let page = document.page(at: index), let cgPage = page.pageRef
        else { return nil }
        return (document, page, cgPage)
    }

    // MARK: - Text

    /// The three lines as text in render mode `mode`, at the unshifted
    /// positions, inside `q … Q` so the mode does not carry on.
    static func text(mode: Int) -> String {
        var s = "q BT /F1 \(Int(pointSize)) Tf \(mode) Tr "
        for (line, x, y) in lines { s += "1 0 0 1 \(Int(x)) \(Int(y)) Tm (\(line)) Tj " }
        return s + "ET Q "
    }

    /// Four lines of invisible text below the printed ones, away from their
    /// words: with the three lines, a text layer too long to read as a stamp
    /// alone (over 200 characters on a letter page), as a scanner's own
    /// recognition leaves.
    static var fillerLayer: String {
        [("Statement of account prepared for the holder named above", 380),
         ("All amounts are shown in United States dollars and cents", 360),
         ("Questions about this statement go to the branch office", 340),
         ("Keep this page with your records for seven years", 320)]
            .map { line($0.0, x: 100, y: CGFloat($0.1), mode: 3, size: 10) }.joined()
    }

    static func line(_ text: String, x: CGFloat, y: CGFloat, mode: Int = 0, size: Int = 14) -> String {
        "q BT /F1 \(size) Tf \(mode) Tr 1 0 0 1 \(n(x)) \(n(y)) Tm (\(text)) Tj ET Q "
    }

    // MARK: - Scans

    enum Pieces {
        case one
        case strips(rows: Int)
        case tiles(Int)
        case inlineStrips(rows: Int)
        case turnedStrips(rows: Int)
    }

    enum Layer {
        /// Invisible text (mode 3), drawn after the pictures.
        case invisible
        /// Visible text (mode 0), drawn before the pictures, which hide it.
        case visibleBefore
    }

    /// The content that draws `g` as `pieces`, and the objects it names
    /// (`/S<k>` is the page's k-th object, from `base`).
    static func draw(_ g: Gray, dpi: CGFloat, _ pieces: Pieces, base: Int = 0) -> (ops: String, names: String, objects: [Object]) {
        let unit = 72 / dpi
        var ops = "", names = "", objects: [Object] = []
        func place(_ rows: Range<Int>, _ columns: Range<Int>) -> (x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) {
            (CGFloat(columns.lowerBound) * unit, page.height - CGFloat(rows.upperBound) * unit,
             CGFloat(columns.count) * unit, CGFloat(rows.count) * unit)
        }
        func rowBands(_ step: Int) -> [Range<Int>] {
            stride(from: 0, to: g.height, by: step).map { $0..<min($0 + step, g.height) }
        }
        func object(_ piece: Gray, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, turned: Bool = false) {
            let k = base + objects.count
            objects.append(image(turned ? piece.turnedClockwise() : piece))
            names += "/S\(k) @\(k)@ "
            ops += turned
                ? "q 0 \(n(h)) \(n(-w)) 0 \(n(x + w)) \(n(y)) cm /S\(k) Do Q "
                : "q \(n(w)) 0 0 \(n(h)) \(n(x)) \(n(y)) cm /S\(k) Do Q "
        }
        switch pieces {
        case .one:
            object(g, 0, 0, page.width, page.height)
        case .strips(let rows), .turnedStrips(let rows):
            var turned = false
            if case .turnedStrips = pieces { turned = true }
            for band in rowBands(rows) {
                let p = place(band, 0..<g.width)
                object(g.piece(rows: band, columns: 0..<g.width), p.x, p.y, p.w, p.h, turned: turned)
            }
        case .tiles(let size):
            for band in rowBands(size) {
                for c in stride(from: 0, to: g.width, by: size) {
                    let columns = c..<min(c + size, g.width)
                    let p = place(band, columns)
                    object(g.piece(rows: band, columns: columns), p.x, p.y, p.w, p.h)
                }
            }
        case .inlineStrips(let rows):
            for band in rowBands(rows) {
                let piece = g.piece(rows: band, columns: 0..<g.width)
                let p = place(band, 0..<g.width)
                let hex = flate(piece.pixels).map { String(format: "%02X", $0) }.joined()
                ops += "q \(n(p.w)) 0 0 \(n(p.h)) \(n(p.x)) \(n(p.y)) cm BI /W \(piece.width) /H \(piece.height) /CS /G /BPC 8 /F [/AHx /Fl] ID \(hex)> EI Q "
            }
        }
        return (ops, names, objects)
    }

    /// A scan of the three lines printed at `shift`, stored as `pieces`, under
    /// the text layer at the unshifted positions.
    static func scanPage(_ pieces: Pieces, dpi: CGFloat = 300, shift: CGFloat, layer: Layer = .invisible,
                         rotate: Int = 0, mark: Bool = false) -> Page {
        var g = print(dpi: dpi, shift: shift)
        if mark { // a dot in the last rows, so two pages differ only in their last piece
            for r in (g.height - 20)..<(g.height - 10) { for c in 40..<50 { g.pixels[r * g.width + c] = 0 } }
        }
        let d = draw(g, dpi: dpi, pieces)
        let content = layer == .invisible ? d.ops + text(mode: 3) : text(mode: 0) + d.ops
        return Page(content, resources: d.names.isEmpty ? "" : "/XObject << \(d.names)>>", objects: d.objects, rotate: rotate)
    }

    static func scan(_ pieces: Pieces, dpi: CGFloat = 300, shift: CGFloat, layer: Layer = .invisible, rotate: Int = 0) -> Data {
        document([scanPage(pieces, dpi: dpi, shift: shift, layer: layer, rotate: rotate)])
    }

    // MARK: - Typed pages

    /// The typed lines, visible.
    static var typedText: String { text(mode: 0) }
    /// One line of invisible text, as a vendor's text layer leaves at a page's foot.
    static var invisibleFooter: String { line("Prepared for the account holder", x: 72, y: 60, mode: 3, size: 10) }

    /// A picture `g` drawn at `rect`, named `/P<k>` for the page's k-th object.
    static func picture(_ k: Int, at rect: CGRect) -> String {
        "q \(n(rect.width)) 0 0 \(n(rect.height)) \(n(rect.minX)) \(n(rect.minY)) cm /P\(k) Do Q "
    }
}
