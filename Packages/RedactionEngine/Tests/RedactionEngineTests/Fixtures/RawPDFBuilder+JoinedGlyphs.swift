import Foundation
import CoreGraphics
@testable import RedactionEngine

// Pages whose drawn glyphs read as more than one letter, the way a typesetter
// writes a joined glyph: "fi" drawn as one glyph whose text is two letters.
// Built by hand, so nothing is embedded that needs a licence: the fonts are
// named and not embedded, a ToUnicode map gives each code its text, and each
// glyph's ink is a filled rectangle painted inside its advance (so every
// glyph shows ink where a reader would see a letter). Two encodings of the
// same page: one-byte codes in a simple font (the form pdfTeX writes) and
// two-byte codes in a composite font (the form PyMuPDF's writer uses). All
// text is invented.

extension TestFixtures {

    /// How a joined-glyph page encodes its codes.
    enum JoinedGlyphEncoding: Sendable {
        /// A simple font, one byte a code.
        case oneByte
        /// A composite font (Identity-H), two bytes a code.
        case twoByte
    }

    /// What one joined glyph's text is.
    enum JoinedGlyphText: Sendable {
        /// Its letters: "fi" reads as f and i.
        case letters
        /// The one presentation-form code point: "fi" reads as U+FB01.
        case presentationForm
    }

    /// The letters each Latin presentation-form ligature stands for. In a
    /// fixture's authored lines, one of these scalars is one drawn glyph.
    static let joinedGlyphLetters: [Unicode.Scalar: String] = [
        "\u{FB00}": "ff", "\u{FB01}": "fi", "\u{FB02}": "fl", "\u{FB03}": "ffi", "\u{FB04}": "ffl",
    ]

    /// One page, one line of text per entry of `lines`, each glyph drawn from
    /// the page's one font. A presentation-form ligature in a line is drawn
    /// as one glyph whose text is given by `text`; every other scalar is one
    /// glyph whose text is itself. With `wordGaps`, a space is not a glyph
    /// but a gap in the line's positioning, as a typesetter writes it; the
    /// reader then supplies the space itself.
    static func joinedGlyphPDF(
        lines: [String],
        encoding: JoinedGlyphEncoding = .oneByte,
        text: JoinedGlyphText = .letters,
        wordGaps: Bool = false,
        fontSize: Int = 18,
        top: Int = 700,
        leading: Int = 30
    ) -> Data {
        // One code per distinct scalar, in order of first use.
        var codes: [Unicode.Scalar: Int] = [:]
        var order: [Unicode.Scalar] = []
        for line in lines {
            for scalar in line.unicodeScalars where codes[scalar] == nil && !(wordGaps && scalar == " ") {
                codes[scalar] = order.count + 1
                order.append(scalar)
            }
        }
        precondition(order.count < 255, "joinedGlyphPDF: too many distinct glyphs")

        func letters(of scalar: Unicode.Scalar) -> Int { joinedGlyphLetters[scalar]?.count ?? 1 }
        func width(of scalar: Unicode.Scalar) -> Int { scalar == " " ? 250 : 450 * letters(of: scalar) }
        func unicodeText(of scalar: Unicode.Scalar) -> String {
            if text == .letters, let joined = joinedGlyphLetters[scalar] { return joined }
            return String(Character(scalar))
        }
        func utf16Hex(_ string: String) -> String {
            string.utf16.map { String(format: "%04X", $0) }.joined()
        }
        let codeHex: (Int) -> String = { code in
            encoding == .oneByte ? String(format: "%02X", code) : String(format: "%04X", code)
        }

        // The ToUnicode map.
        let entries = order.map { "<\(codeHex(codes[$0]!))> <\(utf16Hex(unicodeText(of: $0)))>" }
        var bfchar = ""
        for start in stride(from: 0, to: entries.count, by: 100) {
            let chunk = entries[start..<min(start + 100, entries.count)]
            bfchar += "\(chunk.count) beginbfchar\n" + chunk.joined(separator: "\n") + "\nendbfchar\n"
        }
        let space = encoding == .oneByte ? "<00> <FF>" : "<0000> <FFFF>"
        let toUnicode = """
        /CIDInit /ProcSet findresource begin
        12 dict begin
        begincmap
        /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
        /CMapName /Adobe-Identity-UCS def
        /CMapType 2 def
        1 begincodespacerange \(space) endcodespacerange
        \(bfchar)endcmap
        CMapName currentdict /CMap defineresource pop
        end
        end
        """

        // The page's content: the glyphs' ink, then each line one text
        // object written in hex. A glyph's ink is its advance less a margin
        // each side, from the baseline to 0.6 em: it covers the middle of the
        // glyph's box, where a letter has stroke.
        var content = "0 g\n"
        let em = Double(fontSize) / 1000
        for (index, line) in lines.enumerated() {
            var x = 72.0
            let baseline = Double(top - index * leading)
            for scalar in line.unicodeScalars {
                let advance = Double(width(of: scalar)) * em
                if scalar != " " {
                    content += String(format: "%.2f %.2f %.2f %.2f re f\n",
                                      x + 40 * em, baseline, advance - 80 * em, 600 * em)
                }
                x += advance
            }
        }
        for (index, line) in lines.enumerated() {
            let shown: String
            if wordGaps {
                // Each word a hex string; a space a move of its width.
                let words = line.split(separator: " ", omittingEmptySubsequences: false).map { word in
                    "<" + word.unicodeScalars.map { codeHex(codes[$0]!) }.joined() + ">"
                }
                shown = "[" + words.joined(separator: " -\(width(of: " ")) ") + "] TJ"
            } else {
                shown = "<" + line.unicodeScalars.map { codeHex(codes[$0]!) }.joined() + "> Tj"
            }
            content += "BT /F1 \(fontSize) Tf 72 \(top - index * leading) Td \(shown) ET\n"
        }

        var objects = [
            PDFObject(id: 1, content: "<< /Type /Catalog /Pages 2 0 R >>"),
            PDFObject(id: 2, content: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            PDFObject(id: 3, content: """
                << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] \
                /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>
                """),
            PDFObject(id: 4, content: "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream"),
            PDFObject(id: 6, content: "<< /Length \(toUnicode.utf8.count) >>\nstream\n\(toUnicode)\nendstream"),
        ]

        switch encoding {
        case .oneByte:
            // A simple font with its own encoding: code n is glyph /gn.
            let differences = order.map { "\(codes[$0]!) /g\(codes[$0]!)" }.joined(separator: " ")
            let widths = order.map { String(width(of: $0)) }.joined(separator: " ")
            objects.append(PDFObject(id: 5, content: """
                << /Type /Font /Subtype /Type1 /BaseFont /Helvetica \
                /Encoding << /Type /Encoding /Differences [\(differences)] >> \
                /FirstChar 1 /LastChar \(order.count) /Widths [\(widths)] /ToUnicode 6 0 R >>
                """))
        case .twoByte:
            let widths = order.map { "\(codes[$0]!) [\(width(of: $0))]" }.joined(separator: " ")
            objects.append(PDFObject(id: 5, content: """
                << /Type /Font /Subtype /Type0 /BaseFont /Helvetica /Encoding /Identity-H \
                /DescendantFonts [7 0 R] /ToUnicode 6 0 R >>
                """))
            objects.append(PDFObject(id: 7, content: """
                << /Type /Font /Subtype /CIDFontType2 /BaseFont /Helvetica \
                /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> \
                /FontDescriptor 8 0 R /DW 450 /W [\(widths)] /CIDToGIDMap /Identity >>
                """))
            objects.append(PDFObject(id: 8, content: """
                << /Type /FontDescriptor /FontName /Helvetica /Flags 32 \
                /FontBBox [0 -200 1400 900] /ItalicAngle 0 /Ascent 900 /Descent -200 \
                /CapHeight 700 /StemV 80 >>
                """))
        }
        objects.sort { $0.id < $1.id }
        return buildRawPDF(objects: objects, rootId: 1)
    }
}
