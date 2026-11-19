import Foundation
import PDFKit

/// The page's text (PDFKit's `string`) laid onto the glyphs its content
/// shows: each UTF-16 unit that is not white space names the one glyph that
/// shows it. Built only when the two agree unit for unit, in order, with
/// white space dropped from both (PDFKit adds spaces and line breaks of its
/// own, with no glyph behind them); any other difference leaves the page
/// unmapped. Units are compared as they are, never normalised.
struct ContentGlyphMap {
    let glyphs: [ShownGlyph]
    /// For each UTF-16 unit of the page's text, its glyph's index; nil for
    /// white space.
    let glyphOfUnit: [Int?]

    static let whitespace: Set<UInt16> = [0x20, 0x09, 0x0A, 0x0D, 0xA0]

    static func make(pageText: String, glyphs: [ShownGlyph]) -> ContentGlyphMap? {
        var shown: [(unit: UInt16, glyph: Int)] = []
        for (index, glyph) in glyphs.enumerated() {
            for unit in glyph.text.utf16 where !whitespace.contains(unit) { shown.append((unit, index)) }
        }
        var map: [Int?] = []
        map.reserveCapacity(pageText.utf16.count)
        var next = 0
        for unit in pageText.utf16 {
            if whitespace.contains(unit) { map.append(nil); continue }
            guard next < shown.count, shown[next].unit == unit else { return nil }
            map.append(shown[next].glyph)
            next += 1
        }
        guard next == shown.count else { return nil }
        return ContentGlyphMap(glyphs: glyphs, glyphOfUnit: map)
    }

    /// The page's map, read once per page object (held weakly by page); nil
    /// for a page that is not mapped.
    static func of(_ page: PDFPage) -> ContentGlyphMap? {
        if let cached = ContentGlyphMapCache.shared.value(for: page) { return cached.map }
        var map: ContentGlyphMap?
        if let cgPage = page.pageRef, let text = page.string, let glyphs = ContentGlyphWalk.glyphs(on: cgPage) {
            map = make(pageText: text, glyphs: glyphs)
        }
        ContentGlyphMapCache.shared.set(map, for: page)
        return map
    }
}

/// Each page's map, held weakly by page object.
final class ContentGlyphMapCache: @unchecked Sendable {
    static let shared = ContentGlyphMapCache()
    final class Entry { let map: ContentGlyphMap?; init(_ map: ContentGlyphMap?) { self.map = map } }
    private let lock = NSLock()
    private let table = NSMapTable<PDFPage, Entry>.weakToStrongObjects()

    func value(for page: PDFPage) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return table.object(forKey: page)
    }

    func set(_ map: ContentGlyphMap?, for page: PDFPage) {
        lock.lock(); defer { lock.unlock() }
        table.setObject(Entry(map), forKey: page)
    }
}

extension DocumentSearcher {
    /// One drawn glyph of a match: the page-text unit it shows first in the
    /// range, and its box in the page's default user space.
    struct OwnGlyph: Equatable {
        let unit: Int
        let box: CGRect
    }

    /// The glyphs that draw the characters in `nsRange`, each once: only
    /// glyphs drawn upright at a size (a matrix that is not singular) in a
    /// mode that leaves ink (fill, stroke, or both, with or without
    /// clipping). Nil when
    /// the page is not mapped, or when any such glyph's box, widened by
    /// `anchorSlack`, does not meet PDFKit's own box for its character (the
    /// map is then not trusted for this match).
    nonisolated static func ownGlyphs(for nsRange: NSRange, page: PDFPage) -> [OwnGlyph]? {
        guard let map = ContentGlyphMap.of(page), nsRange.location >= 0,
              NSMaxRange(nsRange) <= map.glyphOfUnit.count else { return nil }
        var seen: Set<Int> = []
        var out: [OwnGlyph] = []
        for unit in nsRange.location..<NSMaxRange(nsRange) {
            guard let index = map.glyphOfUnit[unit], seen.insert(index).inserted else { continue }
            let glyph = map.glyphs[index]
            guard !glyph.singular, glyph.upright, [0, 1, 2, 4, 5, 6].contains(glyph.renderMode) else { continue }
            guard let own = page.selection(for: NSRange(location: unit, length: 1))?.bounds(for: page),
                  glyph.box.insetBy(dx: -anchorSlack, dy: -anchorSlack).intersects(own) else { return nil }
            out.append(OwnGlyph(unit: unit, box: glyph.box))
        }
        return out
    }

    /// How far a glyph's box may lie from PDFKit's box for its character and
    /// still be taken as the same glyph, in points.
    static let anchorSlack: CGFloat = 1
}
