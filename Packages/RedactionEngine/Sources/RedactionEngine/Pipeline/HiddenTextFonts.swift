import CoreText
import Foundation

/// The fonts the hidden text is drawn in, and the choice among them. The
/// hidden text is drawn only in Courier, Courier New and Menlo, the families
/// the font check accepts by name; a character none of the three has a glyph
/// for is never handed to the system to draw in a face of its choosing.
enum HiddenTextFonts {

    /// The three faces by PostScript name, in the order they are chosen.
    static let names = ["Courier", "CourierNewPSMT", "Menlo-Regular"]

    /// How a run of text is drawn.
    enum Choice: Equatable, Sendable {
        /// The whole run in one face: the first of the three that has a
        /// glyph for every character of it.
        case oneFont(String)
        /// No one face has them all: each character, in order, in the first
        /// face that has it.
        case eachCharacter([String])
    }

    /// The font for `name`, or nil when this system has no face of that
    /// PostScript name (CoreText would hand back a substitute).
    static func font(named name: String) -> CTFont? {
        let font = CTFontCreateWithName(name as CFString, 12, nil)
        return (CTFontCopyPostScriptName(font) as String) == name ? font : nil
    }

    /// Whether `font` has a glyph for every scalar of `character`. Glyph
    /// number 0 counts as none.
    static func hasGlyphs(for character: Character, in font: CTFont) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            let units = Array(String(scalar).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            return CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count)
                && glyphs[0] != 0
        }
    }

    /// How `run` is drawn, or nil when it cannot be written: one of its
    /// characters is one the hidden text never holds, or none of the three
    /// faces has a glyph for it. `run` is one run's text after the fold. The
    /// object mark is a break between runs and never written; where one is
    /// in `run`, it is passed over and is no reason to leave the run out.
    static func choice(for run: String) -> Choice? {
        let characters = run.filter { $0.unicodeScalars.elementsEqual([NeverWrittenCharacters.objectMark]) == false }
        if characters.unicodeScalars.contains(where: NeverWrittenCharacters.contains) { return nil }
        let faces = names.compactMap { name in font(named: name).map { (name, $0) } }
        if let whole = faces.first(where: { face in characters.allSatisfy { hasGlyphs(for: $0, in: face.1) } }) {
            return .oneFont(whole.0)
        }
        var each: [String] = []
        each.reserveCapacity(characters.count)
        for character in characters {
            guard let face = faces.first(where: { hasGlyphs(for: character, in: $0.1) }) else { return nil }
            each.append(face.0)
        }
        return .eachCharacter(each)
    }

    /// Whether `run` can be written in the hidden text.
    static func canBeWritten(_ run: String) -> Bool {
        choice(for: run) != nil
    }
}
