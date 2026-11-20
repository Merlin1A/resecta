import CoreGraphics
import CryptoKit
import Foundation

// What each page of the checked file draws, read by the box check itself
// from the file's bytes, apart from the page-image reader. The check judges
// the stored picture's blocks, and that says what a box shows only when the
// page shows that picture and nothing else: drawn once, over the whole page
// box, with only invisible text beside it. The writer's form, measured on
// its exports, is the one form admitted. A key, an operator or a picture
// segment outside it refuses the page, so a way of drawing that no list
// names is refused, never passed.

/// A page as the check admits it: the digest and sides of its one picture.
struct PageDrawing: Equatable, Sendable {
    let pictureSHA256: Data
    let width: Int
    let height: Int
}

enum PageDrawingReader {
    typealias Reason = PageImageRefusal.Reason

    // The writer's form. Each list holds what its exports were measured to hold.
    static let catalogKeys: Set<String> = ["Type", "Pages"]
    static let pageTreeKeys: Set<String> = ["Type", "Kids", "Count", "MediaBox", "Parent"]
    static let pageKeys: Set<String> = ["Type", "Parent", "Resources", "Contents", "MediaBox"]
    static let resourceKeys: Set<String> = ["ProcSet", "XObject", "Font"]
    static let pictureKeys: Set<String> = ["Type", "Subtype", "Width", "Height", "BitsPerComponent", "ColorSpace",
                                           "Filter", "Interpolate", "Length"]
    static let profileKeys: Set<String> = ["N", "Alternate", "Filter", "Length"]
    static let fontKeys: Set<String> = ["Type", "Subtype", "BaseFont", "FirstChar", "LastChar", "Widths",
                                        "FontDescriptor", "Encoding", "ToUnicode"]
    static let descriptorKeys: Set<String> = ["Type", "FontName", "Flags", "FontBBox", "ItalicAngle", "Ascent", "Descent",
                                              "CapHeight", "XHeight", "StemV", "StemH", "AvgWidth", "MaxWidth", "FontFile2"]
    static let operators: Set<String> = ["q", "Q", "cm", "ri", "Do", "BT", "ET", "Tc", "Tf", "Tm", "Tr", "Tj"]
    /// Every operator of the content-stream syntax. Those not listed above refuse the page.
    static let everyOperator: [String] = [
        "b", "B", "b*", "B*", "BDC", "BI", "BMC", "BT", "BX", "c", "cm", "CS", "cs", "d", "d0", "d1", "Do", "DP",
        "EI", "EMC", "ET", "EX", "f", "F", "f*", "G", "g", "gs", "h", "i", "ID", "j", "J", "K", "k", "l", "m", "M", "MP",
        "n", "q", "Q", "re", "RG", "rg", "ri", "s", "S", "SC", "sc", "SCN", "scn", "sh", "T*", "Tc", "Td", "TD", "Tf",
        "Tj", "TJ", "TL", "Tm", "Tr", "Ts", "Tw", "Tz", "v", "w", "W", "W*", "y", "'", "\""]
    /// The text rendering mode that neither fills, strokes nor clips.
    static let invisibleText = 3
    /// The longest Photoshop segment (APP13) the writer was measured to write, its length field.
    static let photoshopSegmentLength = 56

    /// Every page's drawing, or the reason the check will not judge it. A
    /// reason about the file as a whole is every page's reason.
    static func read(fileData: Data) throws(CancellationError) -> [Result<PageDrawing, PageImageRefusal>] {
        guard let provider = CGDataProvider(data: fileData as CFData), let document = CGPDFDocument(provider) else { return [] }
        let count = document.numberOfPages
        if let reason = fileReason(fileData, document) {
            return Array(repeating: .failure(refused(reason)), count: count)
        }
        var pages: [Result<PageDrawing, PageImageRefusal>] = []
        for number in stride(from: 1, through: count, by: 1) {
            if Task.isCancelled { throw CancellationError() }
            pages.append(page(document.page(at: number)))
        }
        return pages
    }

    /// The reader's outcome for a page, held against the page's drawing:
    /// a completed walk stands only when the page draws that picture, at its sides.
    static func admit(_ outcome: PageImageOutcome, drawing: Result<PageDrawing, PageImageRefusal>) -> PageImageOutcome {
        guard case .completed(let walk) = outcome else { return outcome }
        switch drawing {
        case .failure(let refusal): return .couldNotFinish(refusal)
        case .success(let d):
            if d.pictureSHA256 != walk.sha256 { return .couldNotFinish(PageImageRefusal(reason: .pictureNotDrawnOnce, offset: 0)) }
            if d.width != walk.width || d.height != walk.height {
                return .couldNotFinish(PageImageRefusal(reason: .pictureSizeDiffers, offset: 0))
            }
            return outcome
        }
    }

    /// A refusal of the page as a whole: no byte of its picture is named.
    static func refused(_ reason: Reason) -> PageImageRefusal { PageImageRefusal(reason: reason, offset: 0) }

    // MARK: The file

    /// One revision, and a catalog and page tree of the writer's keys alone.
    static func fileReason(_ data: Data, _ document: CGPDFDocument) -> Reason? {
        let startxref = Data("startxref".utf8), trailer = Data("trailer".utf8)
        guard count(of: startxref, in: data) == 1, let t = data.range(of: trailer, options: .backwards) else { return .fileRevised }
        let tail = data[t.upperBound...]
        if tail.range(of: Data("/Prev".utf8)) != nil || tail.range(of: Data("/XRefStm".utf8)) != nil { return .fileRevised }
        guard let catalog = document.catalog, keys(catalog).isSubset(of: catalogKeys) else { return .documentKeyNotListed }
        return nil
    }

    static func count(of needle: Data, in data: Data) -> Int {
        var n = 0, from = data.startIndex
        while let r = data.range(of: needle, in: from..<data.endIndex) { n += 1; from = r.upperBound }
        return n
    }

    // MARK: A page

    static func page(_ page: CGPDFPage?) -> Result<PageDrawing, PageImageRefusal> {
        guard let page, let dict = page.dictionary else { return .failure(refused(.drawingNotRead)) }
        guard keys(dict).isSubset(of: pageKeys) else { return .failure(refused(.pageKeyNotListed)) }
        // Every node above the page: no key the page would take as its own.
        var node = dict, depth = 0
        while let parent = dictionary(node, "Parent") {
            depth += 1
            guard depth <= 64 else { return .failure(refused(.drawingNotRead)) }
            guard keys(parent).isSubset(of: pageTreeKeys) else { return .failure(refused(.pageKeyNotListed)) }
            node = parent
        }
        guard let resources = dictionary(dict, "Resources") else { return .failure(refused(.resourceNotListed)) }
        guard keys(resources).isSubset(of: resourceKeys) else { return .failure(refused(.resourceNotListed)) }
        if let fonts = dictionary(resources, "Font"), let reason = fontReason(fonts) { return .failure(refused(reason)) }
        guard let pictures = dictionary(resources, "XObject"), CGPDFDictionaryGetCount(pictures) == 1,
              let name = keys(pictures).first else { return .failure(refused(.pictureNotDrawnOnce)) }
        var stream: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(pictures, name, &stream), let stream, let pd = CGPDFStreamGetDictionary(stream)
        else { return .failure(refused(.resourceNotListed)) }
        guard self.name(pd, "Subtype") == "Image" else { return .failure(refused(.resourceNotListed)) }
        let picture: (width: Int, height: Int, bytes: Data)
        switch pictureFacts(pd, stream) {
        case .failure(let reason): return .failure(reason)
        case .success(let facts): picture = facts
        }
        if let reason = segmentReason(picture.bytes) { return .failure(refused(reason)) }
        if let reason = wordReason(dict) { return .failure(refused(reason)) }
        let box = page.getBoxRect(.mediaBox)
        switch scan(page) {
        case .failure(let reason): return .failure(reason)
        case .success(let draws):
            guard draws.count == 1, draws[0].name == name else { return .failure(refused(.pictureNotDrawnOnce)) }
            let pageBox = Matrix(a: Double(box.width), b: 0, c: 0, d: Double(box.height), e: Double(box.minX), f: Double(box.minY))
            guard draws[0].ctm == pageBox else { return .failure(refused(.pictureNotOverThePage)) }
        }
        return .success(PageDrawing(pictureSHA256: Data(SHA256.hash(data: picture.bytes)), width: picture.width, height: picture.height))
    }

    static func fontReason(_ fonts: CGPDFDictionaryRef) -> Reason? {
        for key in keys(fonts) {
            guard let font = dictionary(fonts, key), keys(font).isSubset(of: fontKeys), name(font, "Subtype") == "TrueType",
                  let descriptor = dictionary(font, "FontDescriptor"), keys(descriptor).isSubset(of: descriptorKeys)
            else { return .resourceNotListed }
        }
        return nil
    }

    /// The picture's dictionary, key by key: its sides, and its bytes as stored.
    static func pictureFacts(_ pd: CGPDFDictionaryRef, _ stream: CGPDFStreamRef) -> Result<(width: Int, height: Int, bytes: Data), PageImageRefusal> {
        guard keys(pd).isSubset(of: pictureKeys), name(pd, "Filter") == "DCTDecode" else { return .failure(refused(.pictureKeyNotListed)) }
        var bpc: CGPDFInteger = 0, w: CGPDFInteger = 0, h: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(pd, "BitsPerComponent", &bpc), bpc == 8 else { return .failure(refused(.pictureColourNotListed)) }
        var space: CGPDFArrayRef?, family: UnsafePointer<CChar>?, profile: CGPDFStreamRef?
        guard CGPDFDictionaryGetArray(pd, "ColorSpace", &space), let space, CGPDFArrayGetCount(space) == 2,
              CGPDFArrayGetName(space, 0, &family), let family, String(cString: family) == "ICCBased",
              CGPDFArrayGetStream(space, 1, &profile), let profile, let icc = CGPDFStreamGetDictionary(profile),
              keys(icc).isSubset(of: profileKeys), name(icc, "Alternate") == "DeviceRGB"
        else { return .failure(refused(.pictureColourNotListed)) }
        var n: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(icc, "N", &n), n == 3 else { return .failure(refused(.pictureColourNotListed)) }
        guard CGPDFDictionaryGetInteger(pd, "Width", &w), CGPDFDictionaryGetInteger(pd, "Height", &h) else {
            return .failure(refused(.pictureSizeDiffers))
        }
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format), format == .jpegEncoded else { return .failure(refused(.pictureKeyNotListed)) }
        return .success((w, h, data as Data))
    }

    // MARK: The picture's segments

    /// The segments before the picture's scan: those a decoder reads, and of
    /// those it does not, only a JFIF header, an Exif segment with no second
    /// directory (the one that holds a thumbnail) and a Photoshop segment no
    /// longer than the writer's. The reader judges the header's own segments.
    static func segmentReason(_ data: Data) -> Reason? {
        let b = [UInt8](data)
        guard b.count >= 4, b[0] == 0xFF, b[1] == 0xD8 else { return .drawingNotRead }
        var i = 2
        while i + 4 <= b.count {
            guard b[i] == 0xFF else { return .drawingNotRead }
            let marker = b[i + 1]
            if marker == 0xDA { return nil }
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard length >= 2, i + 2 + length <= b.count else { return .drawingNotRead }
            let body = Array(b[(i + 4)..<(i + 2 + length)])
            switch marker {
            case 0xE0:
                guard body.starts(with: Array("JFIF\0".utf8)) else { return .unlistedSegment }
            case 0xE1:
                guard exifHasNoSecondDirectory(body) else { return .unlistedSegment }
            case 0xED:
                guard length <= photoshopSegmentLength, body.starts(with: Array("Photoshop 3.0\0".utf8)) else { return .unlistedSegment }
            case 0xE2...0xEC, 0xEE, 0xEF, 0xFE:
                return .unlistedSegment
            default:
                break
            }
            i += 2 + length
        }
        return .drawingNotRead
    }

    /// An Exif segment whose first directory names no second one.
    static func exifHasNoSecondDirectory(_ body: [UInt8]) -> Bool {
        guard body.starts(with: [0x45, 0x78, 0x69, 0x66, 0, 0]) else { return false }
        let t = Array(body.dropFirst(6))
        guard t.count >= 8 else { return false }
        let little: Bool
        switch (t[0], t[1], t[2], t[3]) {
        case (0x49, 0x49, 0x2A, 0x00): little = true
        case (0x4D, 0x4D, 0x00, 0x2A): little = false
        default: return false
        }
        func u16(_ o: Int) -> Int? {
            guard o >= 0, o + 2 <= t.count else { return nil }
            return little ? Int(t[o]) | Int(t[o + 1]) << 8 : Int(t[o]) << 8 | Int(t[o + 1])
        }
        func u32(_ o: Int) -> Int? {
            guard let lo = u16(little ? o : o + 2), let hi = u16(little ? o + 2 : o) else { return nil }
            return lo | hi << 16
        }
        guard let first = u32(4), let entries = u16(first), let next = u32(first + 2 + 12 * entries) else { return false }
        return next == 0
    }

    // MARK: The content

    /// The page's content read word by word: every operator it names must be
    /// one of the writer's. Core Graphics' scanner reports only the operators
    /// given to it and never a compatibility section, so this reading, not
    /// the scanner's, holds the page to the list.
    static func wordReason(_ page: CGPDFDictionaryRef) -> Reason? {
        var streams: [CGPDFStreamRef] = []
        var one: CGPDFStreamRef?, many: CGPDFArrayRef?
        if CGPDFDictionaryGetStream(page, "Contents", &one), let one {
            streams = [one]
        } else if CGPDFDictionaryGetArray(page, "Contents", &many), let many {
            for k in 0..<CGPDFArrayGetCount(many) {
                var s: CGPDFStreamRef?
                guard CGPDFArrayGetStream(many, k, &s), let s else { return .drawingNotRead }
                streams.append(s)
            }
        } else {
            return .drawingNotRead
        }
        for stream in streams {
            var format = CGPDFDataFormat.raw
            guard let data = CGPDFStreamCopyData(stream, &format), format == .raw else { return .drawingNotRead }
            guard let words = operatorWords(data as Data) else { return .drawingNotRead }
            if words.contains(where: { !operators.contains($0) }) { return .operatorNotListed }
        }
        return nil
    }

    /// The operator words of a content stream, in order, by the syntax's
    /// rules for strings, names, numbers and delimiters; nil when a string,
    /// a hex string or a comment runs past the end. Reading stops after an
    /// inline picture's ID, whose data follows.
    static func operatorWords(_ data: Data) -> [String]? {
        let b = [UInt8](data)
        let white: Set<UInt8> = [0, 9, 10, 12, 13, 32]
        let delimiters: Set<UInt8> = Set("()<>[]{}/%".utf8)
        var words: [String] = []
        var i = 0
        func regular(_ c: UInt8) -> Bool { !white.contains(c) && !delimiters.contains(c) }
        while i < b.count {
            let c = b[i]
            if white.contains(c) { i += 1; continue }
            switch c {
            case UInt8(ascii: "%"):
                while i < b.count, b[i] != 10, b[i] != 13 { i += 1 }
            case UInt8(ascii: "("):
                var depth = 0
                repeat {
                    guard i < b.count else { return nil }
                    switch b[i] {
                    case UInt8(ascii: "\\"): i += 1
                    case UInt8(ascii: "("): depth += 1
                    case UInt8(ascii: ")"): depth -= 1
                    default: break
                    }
                    i += 1
                } while depth > 0
            case UInt8(ascii: "<"):
                if i + 1 < b.count, b[i + 1] == UInt8(ascii: "<") { i += 2; continue }
                while i < b.count, b[i] != UInt8(ascii: ">") { i += 1 }
                guard i < b.count else { return nil }
                i += 1
            case UInt8(ascii: ">"):
                i += (i + 1 < b.count && b[i + 1] == UInt8(ascii: ">")) ? 2 : 1
            case UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: ")"):
                i += 1
            case UInt8(ascii: "/"):
                i += 1
                while i < b.count, regular(b[i]) { i += 1 }
            default:
                let start = i
                while i < b.count, regular(b[i]) { i += 1 }
                let word = String(decoding: b[start..<i], as: UTF8.self)
                if isNumber(word) || word == "true" || word == "false" || word == "null" { continue }
                words.append(word)
                if word == "ID" { return words }
            }
        }
        return words
    }

    static func isNumber(_ word: String) -> Bool {
        var digits = 0, points = 0
        for (k, ch) in word.enumerated() {
            switch ch {
            case "+", "-": if k != 0 { return false }
            case ".": points += 1
            case "0"..."9": digits += 1
            default: return false
            }
        }
        return digits > 0 && points <= 1
    }

    struct Matrix: Equatable {
        var a, b, c, d, e, f: Double
        static let identity = Matrix(a: 1, b: 0, c: 0, d: 1, e: 0, f: 0)
        /// `m` applied first, then this one: the matrix `cm m` leaves.
        func after(_ m: Matrix) -> Matrix {
            Matrix(a: m.a * a + m.b * c, b: m.a * b + m.b * d, c: m.c * a + m.d * c, d: m.c * b + m.d * d,
                   e: m.e * a + m.f * c + e, f: m.e * b + m.f * d + f)
        }
    }

    final class Scan {
        var refusal: Reason?
        var ctm = Matrix.identity
        var mode = 0
        var saved: [(Matrix, Int)] = []
        var draws: [(name: String, ctm: Matrix)] = []
        func refuse(_ reason: Reason, _ scanner: CGPDFScannerRef) {
            if refusal == nil { refusal = reason }
            CGPDFScannerStop(scanner)
        }
    }

    static func scan(_ page: CGPDFPage) -> Result<[(name: String, ctm: Matrix)], PageImageRefusal> {
        guard let table = CGPDFOperatorTableCreate() else { return .failure(refused(.drawingNotRead)) }
        for op in everyOperator where !operators.contains(op) {
            CGPDFOperatorTableSetCallback(table, op) { s, info in
                Unmanaged<Scan>.fromOpaque(info!).takeUnretainedValue().refuse(.operatorNotListed, s)
            }
        }
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            let scan = Unmanaged<Scan>.fromOpaque(info!).takeUnretainedValue()
            scan.saved.append((scan.ctm, scan.mode))
        }
        CGPDFOperatorTableSetCallback(table, "Q") { s, info in
            let scan = Unmanaged<Scan>.fromOpaque(info!).takeUnretainedValue()
            guard let top = scan.saved.popLast() else { scan.refuse(.drawingNotRead, s); return }
            (scan.ctm, scan.mode) = top
        }
        CGPDFOperatorTableSetCallback(table, "cm") { s, info in
            let scan = Unmanaged<Scan>.fromOpaque(info!).takeUnretainedValue()
            var v = [CGPDFReal](repeating: 0, count: 6)
            for k in (0..<6).reversed() where !CGPDFScannerPopNumber(s, &v[k]) { scan.refuse(.drawingNotRead, s); return }
            let m = Matrix(a: Double(v[0]), b: Double(v[1]), c: Double(v[2]), d: Double(v[3]), e: Double(v[4]), f: Double(v[5]))
            scan.ctm = scan.ctm.after(m)
        }
        CGPDFOperatorTableSetCallback(table, "Tr") { s, info in
            let scan = Unmanaged<Scan>.fromOpaque(info!).takeUnretainedValue()
            var mode: CGPDFInteger = 0
            guard CGPDFScannerPopInteger(s, &mode) else { scan.refuse(.textNotInvisible, s); return }
            scan.mode = mode
        }
        CGPDFOperatorTableSetCallback(table, "Tj") { s, info in
            let scan = Unmanaged<Scan>.fromOpaque(info!).takeUnretainedValue()
            if scan.mode != PageDrawingReader.invisibleText { scan.refuse(.textNotInvisible, s) }
        }
        CGPDFOperatorTableSetCallback(table, "Do") { s, info in
            let scan = Unmanaged<Scan>.fromOpaque(info!).takeUnretainedValue()
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(s, &name), let name else { scan.refuse(.drawingNotRead, s); return }
            scan.draws.append((String(cString: name), scan.ctm))
        }
        let state = Scan()
        let content = CGPDFContentStreamCreateWithPage(page)
        let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(state).toOpaque())
        let finished = CGPDFScannerScan(scanner)
        if let refusal = state.refusal { return .failure(refused(refusal)) }
        guard finished else { return .failure(refused(.drawingNotRead)) }
        return .success(state.draws)
    }

    // MARK: Dictionaries

    static func keys(_ d: CGPDFDictionaryRef) -> Set<String> {
        var out: Set<String> = []
        withUnsafeMutablePointer(to: &out) { p in
            CGPDFDictionaryApplyFunction(d, { key, _, info in
                info!.assumingMemoryBound(to: Set<String>.self).pointee.insert(String(cString: key))
            }, p)
        }
        return out
    }

    static func dictionary(_ d: CGPDFDictionaryRef, _ key: String) -> CGPDFDictionaryRef? {
        var r: CGPDFDictionaryRef?
        return CGPDFDictionaryGetDictionary(d, key, &r) ? r : nil
    }

    static func name(_ d: CGPDFDictionaryRef, _ key: String) -> String? {
        var r: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(d, key, &r), let r else { return nil }
        return String(cString: r)
    }
}
