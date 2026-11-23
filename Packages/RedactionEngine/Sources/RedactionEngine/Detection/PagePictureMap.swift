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
    /// More forms drawn than this on one page, or more forms looked into for
    /// an image, and its painting is not followed: forms that draw each other
    /// many times would otherwise be walked a number of times that grows with
    /// each level.
    static let formLimit = 1_024
    /// More lines of visible text started than this on one page and its
    /// painting is not followed: the starts the map keeps, and the checks of
    /// each start against the page's pictures, stay bounded.
    static let textStartLimit = 16_384
    /// More operators read than this on one page, counted over its content
    /// and every form it draws, and its painting is not followed.
    static let operationLimit = 1_000_000
    /// More names looked at than this in one page's search for a picture
    /// (its pattern names and the names in each XObject dictionary the search
    /// reads), and a picture is taken to be reached.
    static let entryLimit = 65_536
    /// The furthest a crop box's edge is taken from the origin, in points, so
    /// whole points and the areas made from them stay within an Int.
    static let coordinateLimit: CGFloat = 0x1p28

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
        guard !hiding.isEmpty, !visibleTextStarts.isEmpty else { return false }
        // The hiding pictures painted after a text start only grow as the
        // start moves earlier, so whether they cover the page holds from some
        // start back: the fewest latest hiding pictures that cover it, found
        // by halving.
        func cover(_ k: Int) -> Bool {
            Self.unionArea(hiding.prefix(k).map(\.rect)) * Self.pageCoverDenominator >= cropBox.area * Self.pageCoverNumerator
        }
        guard cover(hiding.count) else { return false }
        var low = 1, high = hiding.count
        while low < high {
            let mid = (low + high) / 2
            if cover(mid) { high = mid } else { low = mid + 1 }
        }
        // A start painted before this picture has a cover painted after it.
        let before = hiding[low - 1].order
        return visibleTextStarts.contains { start in
            start.order < before && hiding.contains { $0.order > start.order && $0.rect.holds(x: start.x, y: start.y) }
        }
    }

    // MARK: - Rounding

    /// A crop box cut to `coordinateLimit` on every side; null when nothing
    /// of it lies within.
    static func limited(_ r: CGRect) -> CGRect {
        let l = coordinateLimit
        return r.standardized.intersection(CGRect(x: -l, y: -l, width: 2 * l, height: 2 * l))
    }

    /// A finite value rounded by `rule` to whole points, held within
    /// `coordinateLimit` so it never leaves an Int.
    static func whole(_ v: CGFloat, _ rule: FloatingPointRoundingRule) -> Int {
        Int(max(-coordinateLimit, min(coordinateLimit, v.rounded(rule))))
    }

    /// A crop box rounded inward to whole points; nil when it has no area.
    static func inward(_ r: CGRect) -> PictureRect? {
        guard r.minX.isFinite, r.minY.isFinite, r.maxX.isFinite, r.maxY.isFinite else { return nil }
        let box = PictureRect(minX: whole(r.minX, .up), minY: whole(r.minY, .up),
                              maxX: whole(r.maxX, .down), maxY: whole(r.maxY, .down))
        return box.area > 0 ? box : nil
    }

    /// A rectangle already cut to the crop box, rounded outward to whole points.
    static func outward(_ r: CGRect) -> PictureRect {
        PictureRect(minX: whole(r.minX, .down), minY: whole(r.minY, .down),
                    maxX: whole(r.maxX, .up), maxY: whole(r.maxY, .up))
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
    /// The map of a page's content against `cropBox`, by one walk. A crop
    /// box reaching past `coordinateLimit` is read cut to it.
    static func read(_ page: CGPDFPage, cropBox: CGRect) -> PagePictureMap {
        let crop = limited(cropBox)
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
    /// Forms drawn so far on the page, and the forms being drawn now.
    var formsDrawn = 0
    var drawing: Set<CGPDFStreamRef> = []
    /// Each tiling pattern's answer, read once: whether it can be followed.
    var patterns: [CGPDFStreamRef: Bool] = [:]
    /// The forms the page's pattern searches have looked into, shared by
    /// them all.
    let seen = FormsSeen()
    /// Operators read so far on the page.
    var operations = 0
    var followed = true
    var pictures: [PagePictureMap.Picture] = []
    var starts: [PagePictureMap.TextStart] = []
    private var table: CGPDFOperatorTableRef?

    init(crop: CGRect) { self.crop = crop }

    /// The walk an operator is read for, counting the operator; nil past
    /// `operationLimit`, where the painting is not followed and the scan stops.
    static func walk(_ info: UnsafeMutableRawPointer?, _ scanner: CGPDFScannerRef) -> PictureWalk? {
        guard let w = info.map({ Unmanaged<PictureWalk>.fromOpaque($0).takeUnretainedValue() }) else { return nil }
        w.operations += 1
        guard w.operations <= PagePictureMap.operationLimit else {
            w.followed = false
            CGPDFScannerStop(scanner)
            return nil
        }
        return w
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

    func showText(_ scanner: CGPDFScannerRef) {
        guard state.renderMode != 3, state.renderMode != 7 else { return }
        let origin = CGPoint(x: lineMatrix.tx, y: lineMatrix.ty).applying(state.ctm)
        guard origin.x.isFinite, origin.y.isFinite, abs(origin.x) < 0x1p40, abs(origin.y) < 0x1p40 else { return }
        guard starts.count < PagePictureMap.textStartLimit else { followed = false; CGPDFScannerStop(scanner); return }
        order += 1
        starts.append(.init(order: order, x: Int(origin.x.rounded(.down)), y: Int(origin.y.rounded(.down))))
    }

    func moveLine(_ tx: CGFloat, _ ty: CGFloat) {
        lineMatrix = CGAffineTransform(translationX: tx, y: ty).concatenating(lineMatrix)
    }

    // MARK: Forms and patterns

    func drawForm(_ stream: CGPDFStreamRef, _ dictionary: CGPDFDictionaryRef, parent: CGPDFContentStreamRef,
                  scanner: CGPDFScannerRef) {
        guard depth < PageImageCensus.maxFormDepth, !drawing.contains(stream) else { followed = false; return }
        formsDrawn += 1
        guard formsDrawn <= PagePictureMap.formLimit else { followed = false; CGPDFScannerStop(scanner); return }
        drawing.insert(stream)
        defer { drawing.remove(stream) }
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
        if let known = patterns[stream] {
            if !known { followed = false }
            return
        }
        let canFollow = Self.patternCanBeFollowed(stream, content: content, seen: seen)
        patterns[stream] = canFollow
        if !canFollow { followed = false }
    }

    /// Whether the page's resources (own or inherited), or the resources of
    /// the forms they reach, hold a tiling pattern that holds a picture or
    /// cannot be read: a picture the page may draw that no image census sees.
    static func patternsHoldPicture(_ page: CGPDFPage) -> Bool { patternsHoldPicture(page, seen: FormsSeen()) }

    /// `patternsHoldPicture` with the search's record given: each pattern
    /// stream is read once however many names it has, the patterns share one
    /// record of the forms looked into, and past `entryLimit` names looked
    /// at a picture is taken to be held.
    static func patternsHoldPicture(_ page: CGPDFPage, seen: FormsSeen) -> Bool {
        guard let dictionary = page.dictionary,
              case .found(let resources) = TextLayerExtractor.inheritedResources(of: dictionary) else { return false }
        let content = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(content) }
        return patternsHoldPicture(in: resources, content: content, depth: 0, seen: seen)
    }

    /// Whether the patterns of one resource dictionary, or of the forms it
    /// reaches to the depth, hold a picture; each form looked into once.
    /// More forms than `formLimit`, more names than `entryLimit`, or forms
    /// deeper than the depth, and a picture is taken to be held.
    static func patternsHoldPicture(in resources: CGPDFDictionaryRef, content: CGPDFContentStreamRef,
                                    depth: Int, seen: FormsSeen) -> Bool {
        guard depth < PageImageCensus.maxFormDepth else { return true }
        guard let patterns = streams(in: resources, "Pattern", seen: seen) else { return true }
        if patterns.contains(where: { !patternCanBeFollowed($0, content: content, depth: depth, seen: seen) }) { return true }
        guard let xobjects = streams(in: resources, "XObject", seen: seen) else { return true }
        for form in xobjects where subtype(of: form) == "Form" && seen.formsForPatterns.insert(form).inserted {
            seen.looked += 1
            guard seen.looked <= PagePictureMap.formLimit, let dictionary = CGPDFStreamGetDictionary(form) else { return true }
            var inner: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(dictionary, "Resources", &inner), let inner,
               patternsHoldPicture(in: inner, content: content, depth: depth + 1, seen: seen) { return true }
        }
        return false
    }

    /// The streams one resource category names, a stream once for each name;
    /// nil past `entryLimit` names looked at. Each form and pattern is looked
    /// into once by the page's record (`FormsSeen`), however many names it has.
    static func streams(in resources: CGPDFDictionaryRef, _ category: String, seen: FormsSeen) -> [CGPDFStreamRef]? {
        var dictionary: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, category, &dictionary), let dictionary else { return [] }
        var streams: [CGPDFStreamRef] = []
        var tooMany = false
        CGPDFDictionaryApplyBlock(dictionary, { _, value, _ in
            seen.entries += 1
            guard seen.entries <= PagePictureMap.entryLimit else { tooMany = true; return false }
            var stream: CGPDFStreamRef?
            if CGPDFObjectGetValue(value, .stream, &stream), let stream { streams.append(stream) }
            return true
        }, nil)
        return tooMany ? nil : streams
    }

    /// A stream's `/Subtype`, or nil.
    static func subtype(of stream: CGPDFStreamRef) -> String? {
        var name: UnsafePointer<CChar>?
        guard let dictionary = CGPDFStreamGetDictionary(stream),
              CGPDFDictionaryGetName(dictionary, "Subtype", &name), let name else { return nil }
        return String(cString: name)
    }

    /// Whether a tiling pattern holds no picture and can be read, its forms
    /// and the patterns its cell uses looked into under the page's one
    /// record. A pattern already looked into answers by its first reading;
    /// one nested deeper than the depth, or past `formLimit` patterns read,
    /// cannot be followed.
    static func patternCanBeFollowed(_ stream: CGPDFStreamRef, content: CGPDFContentStreamRef, depth: Int = 0,
                                     seen: FormsSeen) -> Bool {
        guard seen.patterns.insert(stream).inserted else { return true }
        seen.patternsRead += 1
        guard depth < PageImageCensus.maxFormDepth, seen.patternsRead <= PagePictureMap.formLimit,
              let dictionary = CGPDFStreamGetDictionary(stream) else { return false }
        var resources: CGPDFDictionaryRef?
        _ = CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
        if let resources, reachesPicture(resources, content: content, depth: depth, seen: seen) { return false }
        let inner = CGPDFContentStreamCreateWithStream(stream, resources ?? dictionary, content)
        defer { CGPDFContentStreamRelease(inner) }
        return cellDrawsOnlyWhatItNames(inner, resources: resources) == true
    }

    /// Whether a pattern cell draws no inline image and draws by `Do` only
    /// objects its own /Resources /XObject names; nil when it cannot be read.
    /// Core Graphics draws nothing for a `Do` the cell's own resources do not
    /// name (macOS 27.2), but a reader that looks the name up in the
    /// enclosing resources would draw it, so such a cell cannot be followed.
    static func cellDrawsOnlyWhatItNames(_ content: CGPDFContentStreamRef, resources: CGPDFDictionaryRef?) -> Bool? {
        final class Cell { var named: CGPDFDictionaryRef?; var other = false }
        let cell = Cell()
        var named: CGPDFDictionaryRef?
        if let resources, CGPDFDictionaryGetDictionary(resources, "XObject", &named) { cell.named = named }
        guard let table = CGPDFOperatorTableCreate() else { return nil }
        defer { CGPDFOperatorTableRelease(table) }
        CGPDFOperatorTableSetCallback(table, "EI") { scanner, info in
            guard let info else { return }
            Unmanaged<Cell>.fromOpaque(info).takeUnretainedValue().other = true
            CGPDFScannerStop(scanner)
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            guard let info else { return }
            let cell = Unmanaged<Cell>.fromOpaque(info).takeUnretainedValue()
            var name: UnsafePointer<CChar>?
            var object: CGPDFObjectRef?
            if CGPDFScannerPopName(scanner, &name), let name, let named = cell.named,
               CGPDFDictionaryGetObject(named, name, &object) { return }
            cell.other = true
            CGPDFScannerStop(scanner)
        }
        let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(cell).toOpaque())
        defer { CGPDFScannerRelease(scanner) }
        let read = CGPDFScannerScan(scanner)
        return cell.other ? false : (read ? true : nil)
    }

    /// The forms and patterns one page's search for a picture has looked into.
    final class FormsSeen {
        var forms: Set<CGPDFStreamRef> = []
        /// The forms looked into for patterns alone, apart from `forms`: a
        /// form looked into there is still looked into for an image.
        var formsForPatterns: Set<CGPDFStreamRef> = []
        /// The pattern streams looked into.
        var patterns: Set<CGPDFStreamRef> = []
        /// How many forms were looked into.
        var looked = 0
        /// How many names were looked at, against `PagePictureMap.entryLimit`.
        var entries = 0
        /// How many pattern streams were read.
        var patternsRead = 0
    }

    /// Whether resources reach a picture: an image object, a form that draws
    /// an inline image, or a tiling pattern that holds a picture or cannot be
    /// read, through forms and patterns to the depth, each looked into once.
    /// More forms than `formLimit`, more names than `entryLimit`, or forms
    /// deeper than the depth, are taken to reach one.
    static func reachesPicture(_ resources: CGPDFDictionaryRef, content: CGPDFContentStreamRef, depth: Int,
                               seen: FormsSeen) -> Bool {
        guard depth < PageImageCensus.maxFormDepth else { return true }
        guard let patterns = streams(in: resources, "Pattern", seen: seen) else { return true }
        if patterns.contains(where: { !patternCanBeFollowed($0, content: content, depth: depth + 1, seen: seen) }) { return true }
        guard let xobjects = streams(in: resources, "XObject", seen: seen) else { return true }
        for stream in xobjects {
            switch subtype(of: stream) {
            case "Image": return true
            case "Form":
                guard seen.forms.insert(stream).inserted else { continue }
                seen.looked += 1
                guard seen.looked <= PagePictureMap.formLimit, let dictionary = CGPDFStreamGetDictionary(stream) else { return true }
                var inner: CGPDFDictionaryRef?
                _ = CGPDFDictionaryGetDictionary(dictionary, "Resources", &inner)
                let drawn = CGPDFContentStreamCreateWithStream(stream, inner ?? dictionary, content)
                let inline = drawsInlineImage(drawn)
                CGPDFContentStreamRelease(drawn)
                if inline != false { return true }
                if let inner, reachesPicture(inner, content: content, depth: depth + 1, seen: seen) { return true }
            default: continue
            }
        }
        return false
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
        CGPDFOperatorTableSetCallback(table, "q") { scanner, info in
            guard let w = PictureWalk.walk(info, scanner) else { return }
            w.saved.append(w.state)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { scanner, info in
            guard let w = PictureWalk.walk(info, scanner) else { return }
            if let back = w.saved.popLast() { w.state = back }
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            guard let w = PictureWalk.walk(info, scanner), let v = PictureWalk.popNumbers(scanner, 6) else { return }
            w.state.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(w.state.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "gs") { scanner, info in
            guard let w = PictureWalk.walk(info, scanner) else { return }
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
            guard let w = PictureWalk.walk(info, scanner) else { return }
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
            guard let w = PictureWalk.walk(info, scanner) else { return }
            var stream: CGPDFStreamRef?
            let opaque = CGPDFScannerPopStream(scanner, &stream) && stream.flatMap(CGPDFStreamGetDictionary)
                .map(PictureWalk.imageIsOpaque) ?? false
            w.paint(hides: opaque, scanner: scanner)
        }
        let pattern: CGPDFOperatorCallback = { scanner, info in
            guard let w = PictureWalk.walk(info, scanner) else { return }
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name else { return }
            w.setPattern(name, content: CGPDFScannerGetContentStream(scanner))
        }
        CGPDFOperatorTableSetCallback(table, "scn", pattern)
        CGPDFOperatorTableSetCallback(table, "SCN", pattern)
        CGPDFOperatorTableSetCallback(table, "Tr") { scanner, info in
            var mode: CGPDFInteger = 0
            guard let w = PictureWalk.walk(info, scanner), CGPDFScannerPopInteger(scanner, &mode) else { return }
            w.state.renderMode = Int(mode)
        }
        CGPDFOperatorTableSetCallback(table, "TL") { scanner, info in
            guard let w = PictureWalk.walk(info, scanner), let v = PictureWalk.popNumbers(scanner, 1) else { return }
            w.state.leading = v[0]
        }
        CGPDFOperatorTableSetCallback(table, "BT") { scanner, info in
            PictureWalk.walk(info, scanner)?.lineMatrix = .identity
        }
        CGPDFOperatorTableSetCallback(table, "Tm") { scanner, info in
            guard let w = PictureWalk.walk(info, scanner), let v = PictureWalk.popNumbers(scanner, 6) else { return }
            w.lineMatrix = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
        }
        CGPDFOperatorTableSetCallback(table, "Td") { scanner, info in
            guard let w = PictureWalk.walk(info, scanner), let v = PictureWalk.popNumbers(scanner, 2) else { return }
            w.moveLine(v[0], v[1])
        }
        CGPDFOperatorTableSetCallback(table, "TD") { scanner, info in
            guard let w = PictureWalk.walk(info, scanner), let v = PictureWalk.popNumbers(scanner, 2) else { return }
            w.state.leading = -v[1]
            w.moveLine(v[0], v[1])
        }
        CGPDFOperatorTableSetCallback(table, "T*") { scanner, info in
            guard let w = PictureWalk.walk(info, scanner) else { return }
            w.moveLine(0, -w.state.leading)
        }
        let show: CGPDFOperatorCallback = { scanner, info in PictureWalk.walk(info, scanner)?.showText(scanner) }
        CGPDFOperatorTableSetCallback(table, "Tj", show)
        CGPDFOperatorTableSetCallback(table, "TJ", show)
        // ' and " move to the next line before they show.
        let nextLineShow: CGPDFOperatorCallback = { scanner, info in
            guard let w = PictureWalk.walk(info, scanner) else { return }
            w.moveLine(0, -w.state.leading)
            w.showText(scanner)
        }
        CGPDFOperatorTableSetCallback(table, "'", nextLineShow)
        CGPDFOperatorTableSetCallback(table, "\"", nextLineShow)
        return table
    }

    deinit { if let table { CGPDFOperatorTableRelease(table) } }
}
