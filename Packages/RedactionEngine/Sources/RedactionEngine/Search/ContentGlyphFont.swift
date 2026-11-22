import Foundation
import CoreGraphics
import CoreText

/// A simple font as the page's content draws it: each one-byte code's
/// advance, its text, and the font's vertical extent, all in thousandths of
/// the text size. Built only for Type1, MMType1 and TrueType fonts; a code
/// whose advance or text cannot be read is nil, never a guess.
struct ContentGlyphFont {
    /// Advance in thousandths of an em, by code.
    let advances: [Int: CGFloat]
    /// The text each code shows, by code.
    let texts: [Int: String]
    /// Ascent and descent in thousandths of an em (descent negative).
    let ascent: CGFloat
    let descent: CGFloat

    /// The standard fonts a page may name without widths, drawn with the
    /// system font of the same PostScript name.
    static let standardFonts: Set<String> = [
        "Helvetica", "Helvetica-Bold", "Helvetica-Oblique", "Helvetica-BoldOblique",
        "Times-Roman", "Times-Bold", "Times-Italic", "Times-BoldItalic",
        "Courier", "Courier-Bold", "Courier-Oblique", "Courier-BoldOblique",
    ]

    /// The font a `Tf` names, or nil when any part of it cannot be read
    /// exactly (another font type, an unreadable encoding or ToUnicode, a
    /// standard font the system does not have under its own name).
    static func read(_ font: CGPDFDictionaryRef) -> ContentGlyphFont? {
        guard let subtype = name(font, "Subtype"), ["Type1", "MMType1", "TrueType"].contains(subtype) else { return nil }
        let baseFont = name(font, "BaseFont") ?? ""
        var descriptor: CGPDFDictionaryRef?
        _ = CGPDFDictionaryGetDictionary(font, "FontDescriptor", &descriptor)

        // Each code's name and text from the encoding.
        guard let encoding = Encoding.read(font, subtype: subtype, baseFont: baseFont) else { return nil }
        var texts = encoding.texts
        var toUnicode: CGPDFStreamRef?
        if CGPDFDictionaryGetStream(font, "ToUnicode", &toUnicode), let toUnicode {
            var format = CGPDFDataFormat.raw
            guard let data = CGPDFStreamCopyData(toUnicode, &format) as Data?, format == .raw,
                  let mapped = ToUnicode.parse(data) else { return nil }
            texts = mapped
        }

        // Advances: the page's /Widths, else the standard font's own.
        var advances: [Int: CGFloat] = [:]
        var system: CTFont?
        var widths: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(font, "Widths", &widths), let widths {
            var first: CGPDFInteger = 0
            guard CGPDFDictionaryGetInteger(font, "FirstChar", &first) else { return nil }
            var missing: CGPDFReal = 0
            if let descriptor { _ = CGPDFDictionaryGetNumber(descriptor, "MissingWidth", &missing) }
            for code in 0..<256 { advances[code] = CGFloat(missing) }
            for index in 0..<CGPDFArrayGetCount(widths) {
                var width: CGPDFReal = 0
                guard CGPDFArrayGetNumber(widths, index, &width) else { return nil }
                let code = Int(first) + index
                if (0..<256).contains(code) { advances[code] = CGFloat(width) }
            }
        } else {
            guard descriptorIsAbsentOrUnembedded(descriptor), standardFonts.contains(baseFont),
                  let font = systemFont(baseFont) else { return nil }
            system = font
            for code in 0..<256 {
                guard let glyph = encoding.glyph(code, in: font) else { continue }
                var glyphs = [glyph]
                var advance = CGSize.zero
                CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &advance, 1)
                advances[code] = advance.width
            }
        }

        // Vertical extent: the descriptor's, else the system font's.
        var ascent: CGPDFReal = 0, descent: CGPDFReal = 0
        if let descriptor, CGPDFDictionaryGetNumber(descriptor, "Ascent", &ascent),
           CGPDFDictionaryGetNumber(descriptor, "Descent", &descent), ascent > descent {
            return ContentGlyphFont(advances: advances, texts: texts, ascent: CGFloat(ascent), descent: CGFloat(descent))
        }
        if let system {
            return ContentGlyphFont(advances: advances, texts: texts,
                                    ascent: CTFontGetAscent(system), descent: -CTFontGetDescent(system))
        }
        return nil
    }

    static func name(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, key, &value), let value else { return nil }
        return String(cString: value)
    }

    /// A standard font is one the file does not carry: no font program.
    private static func descriptorIsAbsentOrUnembedded(_ descriptor: CGPDFDictionaryRef?) -> Bool {
        guard let descriptor else { return true }
        var stream: CGPDFStreamRef?
        let keys: [String] = ["FontFile", "FontFile2", "FontFile3"]
        return !keys.contains { CGPDFDictionaryGetStream(descriptor, $0, &stream) }
    }

    /// The system font of exactly this PostScript name at 1000 units, or nil
    /// when the system would substitute another.
    private static func systemFont(_ postScriptName: String) -> CTFont? {
        let font = CTFontCreateWithName(postScriptName as CFString, 1000, nil)
        return (CTFontCopyPostScriptName(font) as String) == postScriptName ? font : nil
    }
}

// MARK: - Encodings

extension ContentGlyphFont {
    /// A simple font's encoding: each code's glyph name where the page names
    /// one (/Differences), and each code's text.
    struct Encoding {
        var names: [Int: String] = [:]
        var texts: [Int: String] = [:]

        /// The glyph a code draws in a system font: by its /Differences name,
        /// else by its text.
        func glyph(_ code: Int, in font: CTFont) -> CGGlyph? {
            if let name = names[code] {
                let glyph = CTFontGetGlyphWithName(font, name as CFString)
                return glyph == 0 ? nil : glyph
            }
            guard let text = texts[code] else { return nil }
            let units = Array(text.utf16)
            guard units.count == 1 else { return nil }
            var glyph: CGGlyph = 0
            var unit = units[0]
            return CTFontGetGlyphsForCharacters(font, &unit, &glyph, 1) && glyph != 0 ? glyph : nil
        }

        static func read(_ font: CGPDFDictionaryRef, subtype: String, baseFont: String) -> Encoding? {
            var base: String?
            var differences: CGPDFArrayRef?
            if let named = ContentGlyphFont.name(font, "Encoding") {
                base = named
            } else {
                var dictionary: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(font, "Encoding", &dictionary), let dictionary {
                    base = ContentGlyphFont.name(dictionary, "BaseEncoding")
                    _ = CGPDFDictionaryGetArray(dictionary, "Differences", &differences)
                }
            }
            // No encoding named: only an unembedded standard Type1 font is
            // known to use the standard encoding.
            if base == nil {
                guard subtype == "Type1", ContentGlyphFont.standardFonts.contains(baseFont) else { return nil }
                base = "StandardEncoding"
            }
            var encoding = Encoding()
            for code in 0..<256 {
                if let text = baseText(code, encoding: base ?? "") { encoding.texts[code] = text }
            }
            if let differences {
                var code = -1
                for index in 0..<CGPDFArrayGetCount(differences) {
                    var number: CGPDFInteger = 0
                    var name: UnsafePointer<CChar>?
                    if CGPDFArrayGetInteger(differences, index, &number) {
                        code = Int(number)
                    } else if CGPDFArrayGetName(differences, index, &name), let name, (0..<256).contains(code) {
                        let glyphName = String(cString: name)
                        encoding.names[code] = glyphName
                        encoding.texts[code] = GlyphNames.text(glyphName)
                        code += 1
                    } else {
                        return nil
                    }
                }
            }
            return encoding
        }

        /// A code's text in a base encoding; nil where the encoding leaves
        /// it undefined, or for an encoding not read here.
        static func baseText(_ code: Int, encoding: String) -> String? {
            let byte = [UInt8(code)]
            switch encoding {
            case "WinAnsiEncoding":
                guard code >= 0x20, code != 0x7F, ![0x81, 0x8D, 0x8F, 0x90, 0x9D].contains(code) else { return nil }
                return String(bytes: byte, encoding: .windowsCP1252)
            case "MacRomanEncoding":
                guard code >= 0x20, code != 0x7F else { return nil }
                return String(bytes: byte, encoding: .macOSRoman)
            case "StandardEncoding":
                // The printable ASCII range, where the standard encoding
                // differs from ASCII only at the two quotes.
                guard (0x20...0x7E).contains(code) else { return nil }
                if code == 0x27 { return "\u{2019}" }
                if code == 0x60 { return "\u{2018}" }
                return String(bytes: byte, encoding: .ascii)
            default:
                return nil
            }
        }
    }
}
