import CoreGraphics
import Foundation
import PDFKit

// The ink fit's line measures (`DocumentSearcher+InkFit.swift`): a match's
// distance from its line's start, the wide characters before it there, and
// the languages a page's read uses.

extension DocumentSearcher {
    /// The points from the start of the line of `range` (its first letter
    /// that is not a space, in the layer) to the end of `box` (reading frame).
    nonisolated static func distanceFromLineStart(of range: NSRange?, box: CGRect, page: PDFPage,
                                                  visual: CGSize, frame: InkFitFrame) -> CGFloat {
        guard let range, range.location != NSNotFound else { return box.width }
        let text = (page.string ?? "") as NSString
        guard NSMaxRange(range) <= text.length else { return box.width }
        let line = text.lineRange(for: NSRange(location: range.location, length: 0))
        var first = line.location
        while first < range.location,
              let scalar = Unicode.Scalar(text.character(at: first)), CharacterSet.whitespaces.contains(scalar) { first += 1 }
        guard let start = page.selection(for: NSRange(location: first, length: 1))
                .flatMap({ DocumentSearcher().normalizedRect(for: $0, page: page) }) else { return box.width }
        let startBox = frame.toReading(CGRect(x: start.minX * visual.width, y: start.minY * visual.height,
                                              width: start.width * visual.width, height: start.height * visual.height))
        return max(box.maxX - startBox.minX, 0)
    }

    /// The wide (CJK) characters on the line of `range` in `text`, from the
    /// line's start to the range's end.
    nonisolated static func wideCharacters(before range: NSRange?, in text: String) -> Int {
        guard let range, range.location != NSNotFound else { return 0 }
        let ns = text as NSString
        guard NSMaxRange(range) <= ns.length else { return 0 }
        let line = ns.lineRange(for: NSRange(location: range.location, length: 0))
        let span = ns.substring(with: NSRange(location: line.location, length: NSMaxRange(range) - line.location))
        return span.unicodeScalars.reduce(0) { count, scalar in
            switch scalar.value {
            case 0x1100...0x11FF, 0x2E80...0x303F, 0x3040...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
                 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFF60, 0xFFE0...0xFFE6: count + 1
            default: count
            }
        }
    }

    /// The languages a page's read uses: the CJK ones its layer's script
    /// names, else Vision's default (nil).
    nonisolated static func inkFitLanguages(for pageText: String) -> [String]? {
        var han = false, kana = false, hangul = false
        for scalar in pageText.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF: kana = true
            case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F: hangul = true
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF: han = true
            default: continue
            }
        }
        if kana { return ["ja-JP", "en-US"] }
        if hangul { return ["ko-KR", "en-US"] }
        if han { return ["zh-Hans", "zh-Hant", "en-US"] }
        return nil
    }
}
