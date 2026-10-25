import CoreGraphics
import Foundation
import PDFKit

// The ink fit's line measures (`DocumentSearcher+InkFit.swift`): a match's
// distance from its line's start, the wide characters before it there, and
// the reads a page takes (one per CJK script).

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

    /// The CJK scripts a text holds.
    struct InkFitScripts: OptionSet {
        let rawValue: Int
        static let kana = InkFitScripts(rawValue: 1), hangul = InkFitScripts(rawValue: 2), han = InkFitScripts(rawValue: 4)
    }

    nonisolated static func inkFitScripts<S: StringProtocol>(in text: S) -> InkFitScripts {
        var found: InkFitScripts = []
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF: found.insert(.kana)
            case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F: found.insert(.hangul)
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF: found.insert(.han)
            default: continue
            }
        }
        return found
    }

    /// The reads a page takes, one per CJK script its layer uses (one
    /// script's model misreads another's lines: a Korean read of a Chinese
    /// line is noise): Japanese for kana (and the Han among it), Korean for
    /// Hangul, Chinese for Han on a page without kana. A page with none reads
    /// once in Vision's default languages (nil). The first is the page's own
    /// read (`inkFitReadKey`).
    nonisolated static func inkFitReads(for pageText: String) -> [[String]?] {
        let scripts = inkFitScripts(in: pageText)
        var reads: [[String]?] = []
        if scripts.contains(.kana) { reads.append(["ja-JP", "en-US"]) }
        if scripts.contains(.hangul) { reads.append(["ko-KR", "en-US"]) }
        if scripts.contains(.han), !scripts.contains(.kana) { reads.append(["zh-Hans", "zh-Hant", "en-US"]) }
        return reads.isEmpty ? [nil] : reads
    }

    /// Which of `reads` a layer line is fitted on: the read of its own
    /// script, else the page's first (a Latin line reads alike in each).
    nonisolated static func inkFitRead<S: StringProtocol>(forLine line: S, reads: [[String]?]) -> Int {
        guard reads.count > 1 else { return 0 }
        let scripts = inkFitScripts(in: line)
        let wanted = scripts.contains(.kana) ? "ja-JP" : scripts.contains(.hangul) ? "ko-KR"
            : scripts.contains(.han) ? (reads.contains { $0?.first == "ja-JP" } ? "ja-JP" : "zh-Hans") : nil
        return reads.firstIndex { $0?.first == wanted } ?? 0
    }

    /// The token key of a page's `read`-th read: the page's own key for its
    /// first (a page with one script reads as before).
    nonisolated static func inkFitReadKey(pageKey: Int, read: Int) -> Int {
        guard read > 0 else { return pageKey }
        var hasher = Hasher()
        hasher.combine(pageKey)
        hasher.combine(read)
        return hasher.finalize()
    }
}

extension DocumentSearcher.InkFitJob {
    /// The read this job's line is fitted on: its token key and languages.
    var read: (key: Int, languages: [String]?) {
        let reads = DocumentSearcher.inkFitReads(for: pageText)
        let line: String
        if let range, range.location != NSNotFound, NSMaxRange(range) <= (pageText as NSString).length {
            line = (pageText as NSString).substring(with: (pageText as NSString).lineRange(for: range))
        } else {
            line = text ?? ""
        }
        let index = DocumentSearcher.inkFitRead(forLine: line, reads: reads)
        return (DocumentSearcher.inkFitReadKey(pageKey: pageKey, read: index), reads[index])
    }
}
