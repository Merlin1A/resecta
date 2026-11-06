import CoreGraphics
import Foundation

/// What a page draws besides its own typed text: the facts that decide whether
/// a box the user placed can leave a copy of a covered word in a Searchable
/// export. On a page that reaches an image, draws an inline image, shows text
/// in an invisible render mode or uses a Type 3 font, the text layer need not
/// sit on the printed words, so a box over a printed word can miss that
/// word's text, which then sits outside the box. A plain page has none of
/// these: its text is its ink. Every reader fails closed.
public struct PageContentFacts: Equatable, Sendable {
    public var reachesImage: Bool
    public var drawsInlineImage: Bool
    public var showsInvisibleText: Bool
    public var usesType3Font: Bool

    public init(reachesImage: Bool, drawsInlineImage: Bool, showsInvisibleText: Bool, usesType3Font: Bool) {
        self.reachesImage = reachesImage
        self.drawsInlineImage = drawsInlineImage
        self.showsInvisibleText = showsInvisibleText
        self.usesType3Font = usesType3Font
    }

    /// A page with none of the four.
    public var isPlain: Bool { !(reachesImage || drawsInlineImage || showsInvisibleText || usesType3Font) }

    /// The facts of a page that could not be read: never plain.
    public static let unread = PageContentFacts(
        reachesImage: true, drawsInlineImage: true, showsInvisibleText: true, usesType3Font: true)

    /// The four facts for one page, read from its content and resources (own,
    /// inherited and through form objects).
    public static func read(_ page: CGPDFPage?) -> PageContentFacts {
        guard let page, let dictionary = page.dictionary else { return .unread }
        let resources: CGPDFDictionaryRef?
        switch TextLayerExtractor.inheritedResources(of: dictionary) {
        case .found(let found): resources = found
        case .none: resources = nil
        case .unreadable: return .unread
        }
        var walk = ContentWalk()
        walk.visit(contents: dictionary, resources: resources, depth: 0)
        return PageContentFacts(
            reachesImage: PageImageCensus.largestImagePixelArea(of: page) != nil,
            drawsInlineImage: walk.inlineImage,
            showsInvisibleText: DocumentSearcher.showsInvisibleText(page),
            usesType3Font: walk.type3Font)
    }

    /// Whether a Searchable page keeps its text layer under these regions.
    /// It does when every region was placed from a match in the page's own
    /// text layer and has not been moved or resized since (`textAnchored`),
    /// or covers the whole page; otherwise only when the page is plain. The
    /// facts are read only when some region is neither.
    public static func keepsTextLayer(regions: [RedactionRegion], facts: () -> PageContentFacts) -> Bool {
        let unanchored = regions.contains { !$0.textAnchored && !$0.coversWholePage }
        return !unanchored || facts().isPlain
    }

    /// The content walk for inline images and Type 3 fonts: the page's
    /// content streams and every form object its resources reach, to
    /// `PageImageCensus.maxFormDepth`, each stream read once. A stream that
    /// cannot be read, or a form chain past the depth, reads as both.
    struct ContentWalk {
        var inlineImage = false
        var type3Font = false
        private var visited = Set<CGPDFStreamRef>()

        mutating func visit(contents page: CGPDFDictionaryRef, resources: CGPDFDictionaryRef?, depth: Int) {
            var stream: CGPDFStreamRef?
            var array: CGPDFArrayRef?
            if CGPDFDictionaryGetStream(page, "Contents", &stream), let stream {
                scan(stream)
            } else if CGPDFDictionaryGetArray(page, "Contents", &array), let array {
                for i in 0..<CGPDFArrayGetCount(array) {
                    var part: CGPDFStreamRef?
                    if CGPDFArrayGetStream(array, i, &part), let part { scan(part) } else { failClosed() }
                }
            }
            if let resources { visit(resources: resources, depth: depth) }
        }

        private mutating func visit(resources: CGPDFDictionaryRef, depth: Int) {
            guard depth < PageImageCensus.maxFormDepth else { failClosed(); return }
            var fonts: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(resources, "Font", &fonts), let fonts {
                var found = false
                CGPDFDictionaryApplyBlock(fonts, { _, value, _ in
                    var font: CGPDFDictionaryRef?
                    var subtype: UnsafePointer<CChar>?
                    if CGPDFObjectGetValue(value, .dictionary, &font), let font,
                       CGPDFDictionaryGetName(font, "Subtype", &subtype), let subtype,
                       String(cString: subtype) == "Type3" {
                        found = true
                    }
                    return true
                }, nil)
                if found { type3Font = true }
            }
            var xobjects: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return }
            var forms: [CGPDFStreamRef] = []
            CGPDFDictionaryApplyBlock(xobjects, { _, value, _ in
                var stream: CGPDFStreamRef?
                if CGPDFObjectGetValue(value, .stream, &stream), let stream,
                   let dictionary = CGPDFStreamGetDictionary(stream) {
                    var subtype: UnsafePointer<CChar>?
                    if CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype,
                       String(cString: subtype) == "Form" {
                        forms.append(stream)
                    }
                }
                return true
            }, nil)
            for form in forms where !visited.contains(form) {
                scan(form)
                guard let dictionary = CGPDFStreamGetDictionary(form) else { failClosed(); continue }
                var inner: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(dictionary, "Resources", &inner), let inner {
                    visit(resources: inner, depth: depth + 1)
                }
            }
        }

        /// One content stream, read once: an inline image is the `BI`
        /// operator, a token on its own between whitespace or delimiters.
        private mutating func scan(_ stream: CGPDFStreamRef) {
            guard !visited.contains(stream) else { return }
            visited.insert(stream)
            var format = CGPDFDataFormat.raw
            guard let data = CGPDFStreamCopyData(stream, &format) as Data?, format == .raw else { failClosed(); return }
            if Self.hasInlineImageOperator(data) { inlineImage = true }
        }

        private mutating func failClosed() {
            inlineImage = true
            type3Font = true
        }

        /// `BI` as a whole token: preceded by the stream start or a whitespace
        /// or delimiter byte, followed by whitespace or a `/` (its first key).
        static func hasInlineImageOperator(_ data: Data) -> Bool {
            let bytes = [UInt8](data)
            guard bytes.count >= 2 else { return false }
            func separates(_ b: UInt8) -> Bool {
                b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 || b == 0x0C || b == 0x00
                    || b == 0x28 || b == 0x29 || b == 0x3C || b == 0x3E || b == 0x5B || b == 0x5D
                    || b == 0x7B || b == 0x7D || b == 0x25
            }
            for i in 0..<(bytes.count - 1) where bytes[i] == 0x42 && bytes[i + 1] == 0x49 {
                let before = i == 0 || separates(bytes[i - 1])
                let after = i + 2 >= bytes.count || separates(bytes[i + 2]) || bytes[i + 2] == 0x2F
                if before && after { return true }
            }
            return false
        }
    }
}

public extension RedactionRegion {
    /// A box over the whole page (Mark Whole Page): it removes every glyph.
    var coversWholePage: Bool {
        normalizedRect.minX <= 0 && normalizedRect.minY <= 0 && normalizedRect.maxX >= 1 && normalizedRect.maxY >= 1
    }
}
