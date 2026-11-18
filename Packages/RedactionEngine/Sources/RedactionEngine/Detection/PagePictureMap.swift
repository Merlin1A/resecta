import CoreGraphics
import Foundation
import PDFKit

/// Where a page's pictures are painted, read once from its content: each
/// picture's rectangle in whole points, whether it is known to hide what lies
/// under it, where each line of visible text starts, and the order in which
/// the walk met them. The fit's gate and the plan's page facts read a page's
/// cover from this one map, and keep no line of their own.
struct PagePictureMap: Equatable, Sendable {
    /// The share of the crop box the pictures must cover together: four fifths.
    static let pageCoverNumerator = 4
    static let pageCoverDenominator = 5
    /// More pictures than this on one page and its painting is not followed.
    static let pictureLimit = 4_096

    /// A rectangle of whole points in the page's default user space.
    struct PictureRect: Hashable, Sendable {
        var minX: Int, minY: Int, maxX: Int, maxY: Int

        var area: Int { max(0, maxX - minX) * max(0, maxY - minY) }

        /// Whether a point lies inside, edges included.
        func holds(x: Int, y: Int) -> Bool { minX <= x && x <= maxX && minY <= y && y <= maxY }
    }

    struct Picture: Hashable, Sendable {
        /// Its place in the walk's one count over pictures and text starts.
        var order: Int
        var rect: PictureRect
        /// The picture is known to be opaque, so nothing painted before it
        /// under it shows.
        var hides: Bool
    }

    /// The origin of a line of text shown in a visible mode.
    struct TextStart: Hashable, Sendable {
        var order: Int
        var x: Int
        var y: Int
    }

    var cropBox: PictureRect
    var pictures: [Picture]
    var visibleTextStarts: [TextStart]
    /// False when some of the page's painting could not be read.
    var followed: Bool

    // MARK: - The pure answers

    /// The area the rectangles cover together, in square points: a sweep over
    /// the distinct x edges, summing at each step the covered length in y.
    static func unionArea(_ rects: [PictureRect]) -> Int {
        let live = rects.filter { $0.area > 0 }
        let xs = Array(Set(live.flatMap { [$0.minX, $0.maxX] })).sorted()
        guard xs.count > 1 else { return 0 }
        var total = 0
        for (x0, x1) in zip(xs, xs.dropFirst()) {
            let spans = live.filter { $0.minX <= x0 && $0.maxX >= x1 }.map { ($0.minY, $0.maxY) }.sorted { $0.0 < $1.0 }
            var covered = 0
            var current: (Int, Int)?
            for span in spans {
                if let c = current, span.0 <= c.1 {
                    current = (c.0, max(c.1, span.1))
                } else {
                    if let c = current { covered += c.1 - c.0 }
                    current = span
                }
            }
            if let c = current { covered += c.1 - c.0 }
            total += covered * (x1 - x0)
        }
        return total
    }

    /// Whether the pictures together cover at least `numerator` / `denominator`
    /// of the crop box.
    func coversAtLeast(_ numerator: Int, of denominator: Int) -> Bool {
        Self.unionArea(pictures.map(\.rect)) * denominator >= cropBox.area * numerator
    }

    /// Whether the pictures cover the page by the map's line.
    var coversThePage: Bool { coversAtLeast(Self.pageCoverNumerator, of: Self.pageCoverDenominator) }

    /// Visible text lies under pictures that hide it: some line of visible
    /// text starts inside a hiding picture painted after it, and the hiding
    /// pictures painted after that text cover the page by the map's line.
    var hidesVisibleText: Bool {
        let hiding = pictures.filter(\.hides).sorted { $0.order > $1.order }
        var later: [PictureRect] = []
        var next = 0
        var coverKnown: Bool?
        // From the last text start back: the later hiding pictures only grow.
        for start in visibleTextStarts.sorted(by: { $0.order > $1.order }) {
            while next < hiding.count, hiding[next].order > start.order {
                later.append(hiding[next].rect)
                next += 1
                coverKnown = coverKnown == true ? true : nil
            }
            guard later.contains(where: { $0.holds(x: start.x, y: start.y) }) else { continue }
            if coverKnown == nil {
                coverKnown = Self.unionArea(later) * Self.pageCoverDenominator >= cropBox.area * Self.pageCoverNumerator
            }
            if coverKnown == true { return true }
        }
        return false
    }

    // MARK: - Rounding

    /// A crop box rounded inward to whole points; nil when it has no area.
    static func inward(_ r: CGRect) -> PictureRect? {
        guard r.minX.isFinite, r.minY.isFinite, r.maxX.isFinite, r.maxY.isFinite else { return nil }
        let box = PictureRect(minX: Int(r.minX.rounded(.up)), minY: Int(r.minY.rounded(.up)),
                              maxX: Int(r.maxX.rounded(.down)), maxY: Int(r.maxY.rounded(.down)))
        return box.area > 0 ? box : nil
    }

    /// A rectangle already cut to the crop box, rounded outward to whole points.
    static func outward(_ r: CGRect) -> PictureRect {
        PictureRect(minX: Int(r.minX.rounded(.down)), minY: Int(r.minY.rounded(.down)),
                    maxX: Int(r.maxX.rounded(.up)), maxY: Int(r.maxY.rounded(.up)))
    }

    /// Where a picture under `ctm` is painted: the bounding box of the unit
    /// square under the transform, cut to the crop box, rounded outward; nil
    /// when nothing of it lies inside the crop box. The corners must be finite.
    static func paintedRect(_ ctm: CGAffineTransform, crop: CGRect) -> PictureRect? {
        let square = CGRect(x: 0, y: 0, width: 1, height: 1).applying(ctm)
        let cut = square.intersection(crop)
        guard !cut.isNull, cut.width > 0, cut.height > 0 else { return nil }
        return outward(cut)
    }

    /// Whether a picture's corners under `ctm` are finite.
    static func cornersAreFinite(_ ctm: CGAffineTransform) -> Bool {
        let square = CGRect(x: 0, y: 0, width: 1, height: 1).applying(ctm)
        return square.minX.isFinite && square.minY.isFinite && square.maxX.isFinite && square.maxY.isFinite
    }
}

// MARK: - Reading a page

extension PagePictureMap {
    /// The map of a page's content against `cropBox`, by one walk.
    static func read(_ page: CGPDFPage, cropBox: CGRect) -> PagePictureMap {
        let crop = cropBox.standardized
        let walk = PictureWalk(crop: crop)
        let content = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(content) }
        walk.scan(content)
        return PagePictureMap(cropBox: inward(crop) ?? PictureRect(minX: 0, minY: 0, maxX: 0, maxY: 0),
                              pictures: walk.pictures, visibleTextStarts: walk.starts, followed: walk.followed)
    }

    /// A page's map, read once and kept while the page lives.
    static func cached(_ page: PDFPage, cgPage: CGPDFPage) -> PagePictureMap {
        if let known = PagePictureMapCache.shared.value(for: page) { return known }
        let map = read(cgPage, cropBox: page.bounds(for: .cropBox))
        PagePictureMapCache.shared.set(map, for: page)
        return map
    }
}

/// Each page's picture map, held no longer than the page.
final class PagePictureMapCache: @unchecked Sendable {
    static let shared = PagePictureMapCache()
    private final class Box { let map: PagePictureMap; init(_ map: PagePictureMap) { self.map = map } }
    private let lock = NSLock()
    private let table = NSMapTable<PDFPage, Box>.weakToStrongObjects()

    func value(for page: PDFPage) -> PagePictureMap? {
        lock.lock(); defer { lock.unlock() }
        return table.object(forKey: page)?.map
    }

    func set(_ map: PagePictureMap, for page: PDFPage) {
        lock.lock(); defer { lock.unlock() }
        table.setObject(Box(map), forKey: page)
    }
}

/// One walk of a page's content: the transform, the graphics state's alpha,
/// blend mode and soft mask, the text render mode and leading, each saved by
/// `q` and restored by `Q`; the text line matrix; and one count.
final class PictureWalk {
    struct State {
        var ctm = CGAffineTransform.identity
        var alphaIsOne = true
        var blendIsNormal = true
        var softMaskIsNone = true
        var renderMode = 0
        var leading: CGFloat = 0
    }

    let crop: CGRect
    var state = State()
    var saved: [State] = []
    var lineMatrix = CGAffineTransform.identity
    var order = 0
    var painted = 0
    var depth = 0
    var followed = true
    var pictures: [PagePictureMap.Picture] = []
    var starts: [PagePictureMap.TextStart] = []
    private var table: CGPDFOperatorTableRef?

    init(crop: CGRect) { self.crop = crop }

    static func walk(_ info: UnsafeMutableRawPointer?) -> PictureWalk? {
        info.map { Unmanaged<PictureWalk>.fromOpaque($0).takeUnretainedValue() }
    }

    /// Scans one content stream with the walk's table; a stream the scanner
    /// cannot read leaves the painting not followed.
    func scan(_ content: CGPDFContentStreamRef) {
        if table == nil { table = Self.makeTable() }
        guard let table else { followed = false; return }
        let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(self).toOpaque())
        defer { CGPDFScannerRelease(scanner) }
        if !CGPDFScannerScan(scanner) { followed = false }
    }

    // MARK: Pictures

    func paint(hides opaque: Bool, scanner: CGPDFScannerRef) {
        painted += 1
        guard painted <= PagePictureMap.pictureLimit else { followed = false; CGPDFScannerStop(scanner); return }
        guard PagePictureMap.cornersAreFinite(state.ctm) else { followed = false; return }
        order += 1
        guard let rect = PagePictureMap.paintedRect(state.ctm, crop: crop) else { return }
        let hides = opaque && state.alphaIsOne && state.blendIsNormal && state.softMaskIsNone
        pictures.append(.init(order: order, rect: rect, hides: hides))
    }

    /// An image object is known to be opaque when it has no soft mask, no
    /// mask, no alpha in its data, and is not a stencil.
    static func imageIsOpaque(_ dictionary: CGPDFDictionaryRef) -> Bool {
        var object: CGPDFObjectRef?
        if CGPDFDictionaryGetObject(dictionary, "SMask", &object) { return false }
        if CGPDFDictionaryGetObject(dictionary, "Mask", &object) { return false }
        var inData: CGPDFInteger = 0
        if CGPDFDictionaryGetInteger(dictionary, "SMaskInData", &inData), inData != 0 { return false }
        var stencil: CGPDFBoolean = 0
        if CGPDFDictionaryGetBoolean(dictionary, "ImageMask", &stencil), stencil != 0 { return false }
        if CGPDFDictionaryGetBoolean(dictionary, "IM", &stencil), stencil != 0 { return false }
        return true
    }

    // MARK: Text

    func showText() {
        guard state.renderMode != 3, state.renderMode != 7 else { return }
        let origin = CGPoint(x: lineMatrix.tx, y: lineMatrix.ty).applying(state.ctm)
        guard origin.x.isFinite, origin.y.isFinite, abs(origin.x) < 0x1p40, abs(origin.y) < 0x1p40 else { return }
        order += 1
        starts.append(.init(order: order, x: Int(origin.x.rounded(.down)), y: Int(origin.y.rounded(.down))))
    }

    func moveLine(_ tx: CGFloat, _ ty: CGFloat) {
        lineMatrix = CGAffineTransform(translationX: tx, y: ty).concatenating(lineMatrix)
    }

    // MARK: Forms and patterns

    func drawForm(_ stream: CGPDFStreamRef, _ dictionary: CGPDFDictionaryRef, parent: CGPDFContentStreamRef,
                  scanner: CGPDFScannerRef) {
        guard depth < PageImageCensus.maxFormDepth else { followed = false; return }
        var matrix = CGAffineTransform.identity
        var array: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dictionary, "Matrix", &array), let array, let m = Self.matrix(array) { matrix = m }
        var resources: CGPDFDictionaryRef?
        _ = CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
        saved.append(state)
        state.ctm = matrix.concatenating(state.ctm)
        depth += 1
        let inner = CGPDFContentStreamCreateWithStream(stream, resources ?? dictionary, parent)
        let innerScanner = CGPDFScannerCreate(inner, table, Unmanaged.passUnretained(self).toOpaque())
        if !CGPDFScannerScan(innerScanner) { followed = false }
        CGPDFScannerRelease(innerScanner)
        CGPDFContentStreamRelease(inner)
        depth -= 1
        if let back = saved.popLast() { state = back }
    }

    /// A fill or stroke set to a tiling pattern that holds a picture, or that
    /// cannot be read, leaves the painting not followed.
    func setPattern(_ name: UnsafePointer<CChar>, content: CGPDFContentStreamRef) {
        guard let object = CGPDFContentStreamGetResource(content, "Pattern", name) else { followed = false; return }
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &stream), let stream else { return } // a shading pattern
        guard let dictionary = CGPDFStreamGetDictionary(stream) else { followed = false; return }
        var resources: CGPDFDictionaryRef?
        _ = CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
        if let resources, Self.reachesImage(resources, depth: 0) { followed = false; return }
        let inner = CGPDFContentStreamCreateWithStream(stream, resources ?? dictionary, content)
        defer { CGPDFContentStreamRelease(inner) }
        switch Self.drawsInlineImage(inner) {
        case .some(true), .none: followed = false
        case .some(false): break
        }
    }

    /// Whether resources reach an image object, through forms to the depth.
    static func reachesImage(_ resources: CGPDFDictionaryRef, depth: Int) -> Bool {
        guard depth < PageImageCensus.maxFormDepth else { return true }
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return false }
        final class Found { var value = false; var depth = 0 }
        let found = Found()
        found.depth = depth
        CGPDFDictionaryApplyBlock(xobjects, { _, object, info in
            guard let info else { return false }
            let found = Unmanaged<Found>.fromOpaque(info).takeUnretainedValue()
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let dictionary = CGPDFStreamGetDictionary(stream) else { return true }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return true }
            switch String(cString: subtype) {
            case "Image": found.value = true; return false
            case "Form":
                var inner: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(dictionary, "Resources", &inner), let inner,
                   PictureWalk.reachesImage(inner, depth: found.depth + 1) { found.value = true; return false }
                return true
            default: return true
            }
        }, Unmanaged.passUnretained(found).toOpaque())
        return found.value
    }

    /// Whether a content stream draws an inline image; nil when it cannot be read.
    static func drawsInlineImage(_ content: CGPDFContentStreamRef) -> Bool? {
        final class Flag { var value = false }
        let flag = Flag()
        guard let table = CGPDFOperatorTableCreate() else { return nil }
        defer { CGPDFOperatorTableRelease(table) }
        CGPDFOperatorTableSetCallback(table, "EI") { scanner, info in
            guard let info else { return }
            Unmanaged<Flag>.fromOpaque(info).takeUnretainedValue().value = true
            CGPDFScannerStop(scanner)
        }
        let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(flag).toOpaque())
        defer { CGPDFScannerRelease(scanner) }
        let read = CGPDFScannerScan(scanner)
        return flag.value ? true : (read ? false : nil)
    }

    static func matrix(_ array: CGPDFArrayRef) -> CGAffineTransform? {
        guard CGPDFArrayGetCount(array) == 6 else { return nil }
        var v = [CGPDFReal](repeating: 0, count: 6)
        for i in 0..<6 where !CGPDFArrayGetNumber(array, i, &v[i]) { return nil }
        return CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
    }

    static func popNumbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [CGFloat]? {
        var values = [CGFloat](repeating: 0, count: count)
        for i in stride(from: count - 1, through: 0, by: -1) {
            var n: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &n) else { return nil }
            values[i] = n
        }
        return values
    }

    // MARK: The operator table

    static func makeTable() -> CGPDFOperatorTableRef? {
        guard let table = CGPDFOperatorTableCreate() else { return nil }
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            guard let w = PictureWalk.walk(info) else { return }
            w.saved.append(w.state)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            guard let w = PictureWalk.walk(info) else { return }
            if let back = w.saved.popLast() { w.state = back }
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            guard let w = PictureWalk.walk(info), let v = PictureWalk.popNumbers(scanner, 6) else { return }
            w.state.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(w.state.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "gs") { scanner, info in
            guard let w = PictureWalk.walk(info) else { return }
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name,
                  let object = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "ExtGState", name)
            else { return }
            var dictionary: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary else { return }
            var alpha: CGPDFReal = 1
            if CGPDFDictionaryGetNumber(dictionary, "ca", &alpha) { w.state.alphaIsOne = alpha >= 1 }
            var blend: UnsafePointer<CChar>?
            var blends: CGPDFArrayRef?
            if CGPDFDictionaryGetName(dictionary, "BM", &blend), let blend {
                w.state.blendIsNormal = ["Normal", "Compatible"].contains(String(cString: blend))
            } else if CGPDFDictionaryGetArray(dictionary, "BM", &blends), let blends,
                      CGPDFArrayGetName(blends, 0, &blend), let blend {
                w.state.blendIsNormal = ["Normal", "Compatible"].contains(String(cString: blend))
            }
            var mask: UnsafePointer<CChar>?
            var maskObject: CGPDFObjectRef?
            if CGPDFDictionaryGetName(dictionary, "SMask", &mask), let mask {
                w.state.softMaskIsNone = String(cString: mask) == "None"
            } else if CGPDFDictionaryGetObject(dictionary, "SMask", &maskObject) {
                w.state.softMaskIsNone = false
            }
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            guard let w = PictureWalk.walk(info) else { return }
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name else { return }
            let content = CGPDFScannerGetContentStream(scanner)
            var stream: CGPDFStreamRef?
            guard let object = CGPDFContentStreamGetResource(content, "XObject", name),
                  CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let dictionary = CGPDFStreamGetDictionary(stream) else { return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return }
            switch String(cString: subtype) {
            case "Image": w.paint(hides: PictureWalk.imageIsOpaque(dictionary), scanner: scanner)
            case "Form": w.drawForm(stream, dictionary, parent: content, scanner: scanner)
            default: break
            }
        }
        CGPDFOperatorTableSetCallback(table, "EI") { scanner, info in
            guard let w = PictureWalk.walk(info) else { return }
            var stream: CGPDFStreamRef?
            let opaque = CGPDFScannerPopStream(scanner, &stream) && stream.flatMap(CGPDFStreamGetDictionary)
                .map(PictureWalk.imageIsOpaque) ?? false
            w.paint(hides: opaque, scanner: scanner)
        }
        let pattern: CGPDFOperatorCallback = { scanner, info in
            guard let w = PictureWalk.walk(info) else { return }
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name else { return }
            w.setPattern(name, content: CGPDFScannerGetContentStream(scanner))
        }
        CGPDFOperatorTableSetCallback(table, "scn", pattern)
        CGPDFOperatorTableSetCallback(table, "SCN", pattern)
        CGPDFOperatorTableSetCallback(table, "Tr") { scanner, info in
            var mode: CGPDFInteger = 0
            guard let w = PictureWalk.walk(info), CGPDFScannerPopInteger(scanner, &mode) else { return }
            w.state.renderMode = Int(mode)
        }
        CGPDFOperatorTableSetCallback(table, "TL") { scanner, info in
            guard let w = PictureWalk.walk(info), let v = PictureWalk.popNumbers(scanner, 1) else { return }
            w.state.leading = v[0]
        }
        CGPDFOperatorTableSetCallback(table, "BT") { _, info in
            PictureWalk.walk(info)?.lineMatrix = .identity
        }
        CGPDFOperatorTableSetCallback(table, "Tm") { scanner, info in
            guard let w = PictureWalk.walk(info), let v = PictureWalk.popNumbers(scanner, 6) else { return }
            w.lineMatrix = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
        }
        CGPDFOperatorTableSetCallback(table, "Td") { scanner, info in
            guard let w = PictureWalk.walk(info), let v = PictureWalk.popNumbers(scanner, 2) else { return }
            w.moveLine(v[0], v[1])
        }
        CGPDFOperatorTableSetCallback(table, "TD") { scanner, info in
            guard let w = PictureWalk.walk(info), let v = PictureWalk.popNumbers(scanner, 2) else { return }
            w.state.leading = -v[1]
            w.moveLine(v[0], v[1])
        }
        CGPDFOperatorTableSetCallback(table, "T*") { _, info in
            guard let w = PictureWalk.walk(info) else { return }
            w.moveLine(0, -w.state.leading)
        }
        let show: CGPDFOperatorCallback = { _, info in PictureWalk.walk(info)?.showText() }
        CGPDFOperatorTableSetCallback(table, "Tj", show)
        CGPDFOperatorTableSetCallback(table, "TJ", show)
        // ' and " move to the next line before they show.
        let nextLineShow: CGPDFOperatorCallback = { _, info in
            guard let w = PictureWalk.walk(info) else { return }
            w.moveLine(0, -w.state.leading)
            w.showText()
        }
        CGPDFOperatorTableSetCallback(table, "'", nextLineShow)
        CGPDFOperatorTableSetCallback(table, "\"", nextLineShow)
        return table
    }

    deinit { if let table { CGPDFOperatorTableRelease(table) } }
}
