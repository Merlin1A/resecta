import CoreText
import Foundation

/// The hidden text's laid-out line: a line's text at a size, as the writer
/// draws it and the drawn-cell rule measures it. Each run (text between white
/// space) is in the face `HiddenTextFonts.choice(for:)` gives it, white space
/// in Courier. Nil when a run cannot be written, or when the system laid any
/// glyph out in a face other than the three: before the record the page is
/// then a picture, and at write time its hidden text is not written.
/// A page's hidden-text lines as the drawn-cell rule assembled and laid
/// them out before the record, for the writer to draw as they are: each
/// line is assembled and laid out once. `entryCount` is the count of the
/// survivors they were made from; the writer lays the page out itself when
/// it is handed another count, or no line. (A laid-out line is immutable once made.)
struct HiddenTextLines: @unchecked Sendable {
    let lines: [(line: TextLayerLine, laidOut: CTLine)]
    let entryCount: Int
}

enum HiddenTextLine {
    /// The lines a test makes fail to lay out, as when the system puts a
    /// glyph in another face; nil, the default, refuses none.
    @TaskLocal static var refuses: (@Sendable (String) -> Bool)? = nil

    static func layout(_ text: String, size: CGFloat) -> CTLine? {
        if let refuses, refuses(text) { return nil }
        let attributed = NSMutableAttributedString()
        // One font object per face for the line, so text in one face is one
        // glyph run.
        var fonts: [String: CTFont] = [:]
        func append(_ piece: String, _ name: String) {
            let font = fonts[name] ?? CTFontCreateWithName(name as CFString, size, nil)
            fonts[name] = font
            attributed.append(NSAttributedString(string: piece, attributes: [.font: font]))
        }
        var run = ""
        func closeRun() -> Bool {
            defer { run = "" }
            guard !run.isEmpty else { return true }
            guard !run.unicodeScalars.contains(NeverWrittenCharacters.objectMark),
                  let choice = HiddenTextFonts.choice(for: run) else { return false }
            switch choice {
            case .oneFont(let name):
                append(run, name)
            case .eachCharacter(let names):
                guard names.count == run.count else { return false }
                for (character, name) in zip(run, names) { append(String(character), name) }
            }
            return true
        }
        for character in text {
            if character.isWhitespace {
                guard closeRun() else { return nil }
                append(String(character), "Courier")
            } else {
                run.append(character)
            }
        }
        guard closeRun() else { return nil }
        let line = CTLineCreateWithAttributedString(attributed)
        let glyphRuns = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        for glyphRun in glyphRuns {
            let attributes = CTRunGetAttributes(glyphRun) as NSDictionary
            guard let value = attributes[kCTFontAttributeName],
                  CFGetTypeID(value as CFTypeRef) == CTFontGetTypeID() else { return nil }
            let font = value as! CTFont
            guard HiddenTextFonts.names.contains(CTFontCopyPostScriptName(font) as String) else { return nil }
        }
        return line
    }
}
