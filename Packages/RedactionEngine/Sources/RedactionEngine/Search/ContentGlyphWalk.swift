import Foundation
import CoreGraphics

/// One glyph a page's content shows: its text, its box in the page's default
/// user space (the glyph's advance by its font's ascent and descent, through
/// the text rendering matrix), whether that matrix is singular (the glyph is
/// drawn at no size), and its render mode.
struct ShownGlyph: Equatable, Sendable {
    var text: String
    var box: CGRect
    var singular: Bool
    var renderMode: Int
    /// Drawn upright: no rotation, skew or mirror in its rendering matrix.
    var upright: Bool
}

/// The engine's one text-state walker: the page's own drawing, read glyph by
/// glyph with Core Graphics' content scanner (not a byte parser of its own): the graphics state (`q`, `Q`, `cm`), the text state and text
/// positioning operators, and Form XObjects (their matrix and resources, to a
/// depth of 8). The walk answers nil, not a partial list, wherever a glyph's
/// place or text cannot be read exactly: a font other than a simple one, a
/// code without an advance or text, a `gs` that sets the font, text shown
/// outside `BT`, marked content carrying /ActualText, an unresolved resource,
/// a form past the depth, or more operators than `operatorLimit`.
enum ContentGlyphWalk {
    static let operatorLimit = 200_000
    static let formDepthLimit = 8

    struct GraphicsState {
        var ctm = CGAffineTransform.identity
        var font: ContentGlyphFont?
        var size: CGFloat = 0
        var charSpacing: CGFloat = 0
        var wordSpacing: CGFloat = 0
        var scale: CGFloat = 100
        var leading: CGFloat = 0
        var rise: CGFloat = 0
        var renderMode = 0
    }

    final class State {
        var g = GraphicsState()
        var saved: [GraphicsState] = []
        var tm = CGAffineTransform.identity
        var tlm = CGAffineTransform.identity
        var inText = false
        var glyphs: [ShownGlyph] = []
        var unknown = false
        var operators = 0
        var depth = 0
        var fonts: [Int: ContentGlyphFont] = [:]
        var table: CGPDFOperatorTableRef?

        func fail(_ scanner: CGPDFScannerRef) { unknown = true; CGPDFScannerStop(scanner) }

        /// Counts one operator; false (and the walk stopped) past the limit.
        func count(_ scanner: CGPDFScannerRef) -> Bool {
            operators += 1
            if operators > ContentGlyphWalk.operatorLimit { fail(scanner); return false }
            return !unknown
        }

        func moveLine(_ tx: CGFloat, _ ty: CGFloat) {
            tlm = CGAffineTransform(translationX: tx, y: ty).concatenating(tlm)
            tm = tlm
        }

        /// Shows one string's codes with the current font and state.
        func show(_ string: CGPDFStringRef, _ scanner: CGPDFScannerRef) {
            guard inText, let font = g.font, let bytes = CGPDFStringGetBytePtr(string) else { fail(scanner); return }
            let th = g.scale / 100
            for offset in 0..<CGPDFStringGetLength(string) {
                let code = Int(bytes[offset])
                guard let advance = font.advances[code], let text = font.texts[code] else { fail(scanner); return }
                let textSpace = CGAffineTransform(a: g.size * th, b: 0, c: 0, d: g.size, tx: 0, ty: g.rise)
                let trm = textSpace.concatenating(tm).concatenating(g.ctm)
                let quad = CGRect(x: 0, y: font.descent / 1000, width: advance / 1000,
                                  height: (font.ascent - font.descent) / 1000)
                glyphs.append(ShownGlyph(text: text, box: quad.applying(trm),
                                         singular: trm.a * trm.d - trm.b * trm.c == 0, renderMode: g.renderMode,
                                         upright: trm.b == 0 && trm.c == 0 && trm.a > 0 && trm.d > 0))
                let tx = (advance / 1000 * g.size + g.charSpacing + (code == 32 ? g.wordSpacing : 0)) * th
                tm = CGAffineTransform(translationX: tx, y: 0).concatenating(tm)
            }
        }

        static func from(_ info: UnsafeMutableRawPointer?) -> State? {
            info.map { Unmanaged<State>.fromOpaque($0).takeUnretainedValue() }
        }
    }

    /// The glyphs the page shows, in content order, or nil when any of them
    /// cannot be placed or read exactly.
    static func glyphs(on page: CGPDFPage) -> [ShownGlyph]? {
        guard let table = CGPDFOperatorTableCreate() else { return nil }
        defer { CGPDFOperatorTableRelease(table) }
        register(table)
        let state = State()
        state.table = table
        let content = CGPDFContentStreamCreateWithPage(page)
        let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(state).toOpaque())
        let read = CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(content)
        return read && !state.unknown ? state.glyphs : nil
    }

    static func popNumbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [CGFloat]? {
        var values = [CGFloat](repeating: 0, count: count)
        for index in stride(from: count - 1, through: 0, by: -1) {
            var value: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &value) else { return nil }
            values[index] = CGFloat(value)
        }
        return values
    }

    private static func register(_ table: CGPDFOperatorTableRef) {
        CGPDFOperatorTableSetCallback(table, "q") { scanner, info in
            guard let s = State.from(info), s.count(scanner) else { return }
            s.saved.append(s.g)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { scanner, info in
            guard let s = State.from(info), s.count(scanner) else { return }
            guard let g = s.saved.popLast() else { s.fail(scanner); return }
            s.g = g
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            guard let s = State.from(info), s.count(scanner) else { return }
            guard let m = ContentGlyphWalk.popNumbers(scanner, 6) else { s.fail(scanner); return }
            s.g.ctm = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5]).concatenating(s.g.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "BT") { scanner, info in
            guard let s = State.from(info), s.count(scanner) else { return }
            s.inText = true; s.tm = .identity; s.tlm = .identity
        }
        CGPDFOperatorTableSetCallback(table, "ET") { scanner, info in
            guard let s = State.from(info), s.count(scanner) else { return }
            s.inText = false
        }
        CGPDFOperatorTableSetCallback(table, "Tf") { scanner, info in
            guard let s = State.from(info), s.count(scanner) else { return }
            var size: CGPDFReal = 0
            var name: UnsafePointer<CChar>?
            var dictionary: CGPDFDictionaryRef?
            guard CGPDFScannerPopNumber(scanner, &size), CGPDFScannerPopName(scanner, &name), let name,
                  let object = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "Font", name),
                  CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary else { s.fail(scanner); return }
            let key = unsafeBitCast(dictionary, to: Int.self)
            if s.fonts[key] == nil {
                guard let font = ContentGlyphFont.read(dictionary) else { s.fail(scanner); return }
                s.fonts[key] = font
            }
            s.g.font = s.fonts[key]
            s.g.size = CGFloat(size)
        }
        CGPDFOperatorTableSetCallback(table, "Tc") { scanner, info in ContentGlyphWalk.setNumber(scanner, info, \.charSpacing) }
        CGPDFOperatorTableSetCallback(table, "Tw") { scanner, info in ContentGlyphWalk.setNumber(scanner, info, \.wordSpacing) }
        CGPDFOperatorTableSetCallback(table, "Tz") { scanner, info in ContentGlyphWalk.setNumber(scanner, info, \.scale) }
        CGPDFOperatorTableSetCallback(table, "TL") { scanner, info in ContentGlyphWalk.setNumber(scanner, info, \.leading) }
        CGPDFOperatorTableSetCallback(table, "Ts") { scanner, info in ContentGlyphWalk.setNumber(scanner, info, \.rise) }
        CGPDFOperatorTableSetCallback(table, "Tr") { scanner, info in
            guard let s = State.from(info), s.count(scanner) else { return }
            var mode: CGPDFInteger = 0
            guard CGPDFScannerPopInteger(scanner, &mode) else { s.fail(scanner); return }
            s.g.renderMode = Int(mode)
        }
        CGPDFOperatorTableSetCallback(table, "Td") { scanner, info in
            guard let s = State.from(info), s.count(scanner) else { return }
            guard let t = ContentGlyphWalk.popNumbers(scanner, 2) else { s.fail(scanner); return }
            s.moveLine(t[0], t[1])
        }
        CGPDFOperatorTableSetCallback(table, "TD") { scanner, info in
            guard let s = State.from(info), s.count(scanner) else { return }
            guard let t = ContentGlyphWalk.popNumbers(scanner, 2) else { s.fail(scanner); return }
            s.g.leading = -t[1]
            s.moveLine(t[0], t[1])
        }
        CGPDFOperatorTableSetCallback(table, "Tm") { scanner, info in
            guard let s = State.from(info), s.count(scanner) else { return }
            guard let m = ContentGlyphWalk.popNumbers(scanner, 6) else { s.fail(scanner); return }
            s.tlm = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5])
            s.tm = s.tlm
        }
        CGPDFOperatorTableSetCallback(table, "T*") { scanner, info in
            guard let s = State.from(info), s.count(scanner) else { return }
            s.moveLine(0, -s.g.leading)
        }
        CGPDFOperatorTableSetCallback(table, "Tj") { scanner, info in
            guard let s = State.from(info), s.count(scanner) else { return }
            var string: CGPDFStringRef?
            guard CGPDFScannerPopString(scanner, &string), let string else { s.fail(scanner); return }
            s.show(string, scanner)
        }
        CGPDFOperatorTableSetCallback(table, "'") { scanner, info in
            guard let s = State.from(info), s.count(scanner) else { return }
            var string: CGPDFStringRef?
            guard CGPDFScannerPopString(scanner, &string), let string else { s.fail(scanner); return }
            s.moveLine(0, -s.g.leading)
            s.show(string, scanner)
        }
        CGPDFOperatorTableSetCallback(table, "\"") { scanner, info in
            guard let s = State.from(info), s.count(scanner) else { return }
            var string: CGPDFStringRef?
            guard CGPDFScannerPopString(scanner, &string), let string,
                  let spacing = ContentGlyphWalk.popNumbers(scanner, 2) else { s.fail(scanner); return }
            s.g.wordSpacing = spacing[0]
            s.g.charSpacing = spacing[1]
            s.moveLine(0, -s.g.leading)
            s.show(string, scanner)
        }
        CGPDFOperatorTableSetCallback(table, "TJ") { scanner, info in
            guard let s = State.from(info), s.count(scanner) else { return }
            var array: CGPDFArrayRef?
            guard CGPDFScannerPopArray(scanner, &array), let array else { s.fail(scanner); return }
            for index in 0..<CGPDFArrayGetCount(array) {
                var string: CGPDFStringRef?
                var number: CGPDFReal = 0
                if CGPDFArrayGetString(array, index, &string), let string {
                    s.show(string, scanner)
                    if s.unknown { return }
                } else if CGPDFArrayGetNumber(array, index, &number) {
                    let tx = -CGFloat(number) / 1000 * s.g.size * s.g.scale / 100
                    s.tm = CGAffineTransform(translationX: tx, y: 0).concatenating(s.tm)
                } else {
                    s.fail(scanner); return
                }
            }
        }
        CGPDFOperatorTableSetCallback(table, "gs") { scanner, info in
            guard let s = State.from(info), s.count(scanner) else { return }
            var name: UnsafePointer<CChar>?
            var dictionary: CGPDFDictionaryRef?
            var font: CGPDFArrayRef?
            guard CGPDFScannerPopName(scanner, &name), let name,
                  let object = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "ExtGState", name),
                  CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary,
                  !CGPDFDictionaryGetArray(dictionary, "Font", &font) else { s.fail(scanner); return }
        }
        CGPDFOperatorTableSetCallback(table, "BDC") { scanner, info in
            guard let s = State.from(info), s.count(scanner) else { return }
            var object: CGPDFObjectRef?
            var dictionary: CGPDFDictionaryRef?
            var name: UnsafePointer<CChar>?
            var text: CGPDFStringRef?
            guard CGPDFScannerPopObject(scanner, &object), let object else { s.fail(scanner); return }
            if CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary {
                if CGPDFDictionaryGetString(dictionary, "ActualText", &text) { s.fail(scanner) }
            } else if CGPDFObjectGetValue(object, .name, &name), let name {
                guard let resource = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "Properties", name),
                      CGPDFObjectGetValue(resource, .dictionary, &dictionary), let dictionary else { s.fail(scanner); return }
                if CGPDFDictionaryGetString(dictionary, "ActualText", &text) { s.fail(scanner) }
            } else {
                s.fail(scanner)
            }
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            guard let s = State.from(info), s.count(scanner) else { return }
            ContentGlyphWalk.drawObject(scanner, s)
        }
    }

    private static func setNumber(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?,
                                  _ path: WritableKeyPath<GraphicsState, CGFloat>) {
        guard let s = State.from(info), s.count(scanner) else { return }
        var value: CGPDFReal = 0
        guard CGPDFScannerPopNumber(scanner, &value) else { s.fail(scanner); return }
        s.g[keyPath: path] = CGFloat(value)
    }

    /// `Do`: an image draws no glyph; a form is walked under its matrix with
    /// its own resources, the graphics state saved and restored around it.
    private static func drawObject(_ scanner: CGPDFScannerRef, _ s: State) {
        var name: UnsafePointer<CChar>?
        var stream: CGPDFStreamRef?
        let content = CGPDFScannerGetContentStream(scanner)
        guard CGPDFScannerPopName(scanner, &name), let name,
              let object = CGPDFContentStreamGetResource(content, "XObject", name),
              CGPDFObjectGetValue(object, .stream, &stream), let stream,
              let dictionary = CGPDFStreamGetDictionary(stream),
              let subtype = ContentGlyphFont.name(dictionary, "Subtype") else { s.fail(scanner); return }
        guard subtype == "Form" else { return }
        var resources: CGPDFDictionaryRef?
        guard s.depth < formDepthLimit, let table = s.table,
              CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources else { s.fail(scanner); return }
        var matrix = CGAffineTransform.identity
        var array: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dictionary, "Matrix", &array), let array {
            var m = [CGFloat]()
            for index in 0..<CGPDFArrayGetCount(array) {
                var value: CGPDFReal = 0
                guard CGPDFArrayGetNumber(array, index, &value) else { s.fail(scanner); return }
                m.append(CGFloat(value))
            }
            guard m.count == 6 else { s.fail(scanner); return }
            matrix = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5])
        }
        let saved = (s.g, s.saved.count, s.tm, s.tlm, s.inText)
        s.g.ctm = matrix.concatenating(s.g.ctm)
        s.depth += 1
        let inner = CGPDFContentStreamCreateWithStream(stream, resources, content)
        let innerScanner = CGPDFScannerCreate(inner, table, Unmanaged.passUnretained(s).toOpaque())
        if !CGPDFScannerScan(innerScanner) { s.unknown = true }
        CGPDFScannerRelease(innerScanner)
        CGPDFContentStreamRelease(inner)
        s.depth -= 1
        if s.saved.count != saved.1 { s.unknown = true }
        (s.g, s.tm, s.tlm, s.inText) = (saved.0, saved.2, saved.3, saved.4)
        if s.unknown { CGPDFScannerStop(scanner) }
    }
}
