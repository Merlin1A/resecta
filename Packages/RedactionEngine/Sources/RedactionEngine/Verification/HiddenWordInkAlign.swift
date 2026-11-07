import CoreGraphics
import Foundation

// The hidden-word check's alignment step: where in the SOURCE's own text layer
// each word that survives in the export came from.
//
// The export redraws its text layer on its own grid, so a surviving word does
// not sit on the hidden glyphs it was copied from. This step locates those
// glyphs on the source page (its text layer as PDFKit reads it) and hands the
// predicate each surviving word or fragment at its glyphs' box; the predicate
// then fits the hidden layer to the print, the geometry its slack was measured
// on.
//
// The rule:
// - Matching: each export line's characters, whitespace ignored, are an
//   ordered subsequence of one source line's glyphs. A word's characters
//   match consecutive glyphs of that line (a fragment matches its own
//   glyphs), and the line's words keep their order.
// - The window: a candidate's offset (the export word's leading edge minus
//   its first glyph's, along the axis) must lie within `windowCells` of the
//   word's own cell (its length along the line ÷ its character count) plus
//   `HiddenWordInkCheck.residualSlack` of zero, or of the offset of the
//   nearest aligned word on either side on the same export line (the
//   writer's offsets build up along a group it draws in fixed cells). An
//   offset past `capCells` cells is never accepted. Across, the candidate
//   must lie on a source line whose band overlaps the word's band. The
//   window only narrows; a unique match outside it is unaligned.
// - Rounds: each round judges the words still unaligned against the
//   alignments as they stood at its start; a word that is ever ambiguous
//   stays unaligned; an aligned word stays aligned; the rounds end when one
//   aligns nothing new. Ambiguity is judged over the whole window. The result
//   does not depend on the order the words are listed in.
// - A word with no candidate, or with more than one that the order leaves
//   standing, is unaligned. Position never chooses between candidates.
// - An unaligned word makes the page not inspected when its export box,
//   widened by its window and the drift reach, meets a box's paint.
//
// Every comparison is in integers on the predicate's grid. Nothing here reads
// the writer's own record of where it drew each character, the strip, or the
// search's ink fit.

/// One hidden character of the source's text layer, in `page.string` order,
/// in the normalized frame, with its source line.
struct HiddenWordInkGlyph: Equatable, Sendable {
    var char: Character
    var rect: CGRect
    var line: Int
}

/// The direction text advances in the visual (post-rotation) frame.
enum HiddenWordInkAxis: Equatable, Sendable {
    /// /Rotate 0, 90, 180, 270.
    case right, down, left, up

    init(rotation: Int) {
        switch ((rotation % 360) + 360) % 360 {
        case 90: self = .down
        case 180: self = .left
        case 270: self = .up
        default: self = .right
        }
    }

    var isVertical: Bool { self == .down || self == .up }
}

enum HiddenWordInkAlign {

    /// The window along the line, in the export word's own cells (before the
    /// residual slack): the writer snaps each word left onto its line's grid
    /// and rounds the gaps to whole cells.
    static let windowCells = (numerator: 3, denominator: 2)

    /// The most a chain may carry a word from its own glyphs, in the word's
    /// cells: past it a match is never accepted (a chain cannot walk along a
    /// line onto another copy).
    static let capCells = 6

    /// One spelling of a word on a source line: its glyphs `start ..< end`
    /// and its offset (the word's leading edge minus its first glyph's, along
    /// the line, in grid units).
    struct Candidate: Hashable { var line: Int; var start: Int; var end: Int; var offset: Int }

    /// The order: on each source line, a candidate stands only if the words
    /// before and after it (in position order) can keep their order on that
    /// source line; words with no candidate there do not constrain it.
    static func inOrder(_ candidates: [[Candidate]]) -> [Set<Candidate>] {
        var standing = candidates.map { _ in Set<Candidate>() }
        for li in Set(candidates.flatMap { $0.map(\.line) }) {
            let order = candidates.indices.filter { candidates[$0].contains { $0.line == li } }
            var forward: [Int: [Candidate]] = [:]
            var lastEnd: Int?
            for k in order {
                let here = candidates[k].filter { c in c.line == li && (lastEnd.map { c.start >= $0 } ?? true) }
                forward[k] = here
                lastEnd = here.map(\.end).min() ?? lastEnd
            }
            var nextStart: Int?
            for k in order.reversed() {
                let here = (forward[k] ?? []).filter { c in nextStart.map { c.end <= $0 } ?? true }
                standing[k].formUnion(here)
                nextStart = here.map(\.start).max() ?? nextStart
            }
        }
        return standing
    }

    /// A box in the axis's reading frame: x runs the way the text advances
    /// (so `minX` is the leading edge), y runs across the line.
    static func reading(_ b: HiddenWordInkCheck.GridBox, _ axis: HiddenWordInkAxis) -> HiddenWordInkCheck.GridBox {
        switch axis {
        case .right: b
        case .left: .init(minX: -b.maxX, maxX: -b.minX, minY: b.minY, maxY: b.maxY)
        case .down: .init(minX: -b.maxY, maxX: -b.minY, minY: b.minX, maxY: b.maxX)
        case .up: .init(minX: b.minY, maxX: b.maxY, minY: b.minX, maxY: b.maxX)
        }
    }

    /// A word's window along the line, doubled and multiplied by its
    /// character count `n` so it stays integral: 2n·(1.5·length/n + slack).
    static func window2n(length: Int, n: Int) -> Int {
        let slackGrid = Int((HiddenWordInkCheck.residualSlack * Double(HiddenWordInkCheck.gridPerPoint)).rounded())
        return 2 * windowCells.numerator * length / windowCells.denominator + 2 * n * slackGrid
    }

    /// Each export word's aligned source-glyph box (the union of its matched
    /// glyphs, in the normalized frame), or nil when it is unaligned or
    /// ambiguous; one entry per word, in order.
    static func align(words: [HiddenWordInkWord], glyphs: [HiddenWordInkGlyph], pageSize: CGSize,
                      axis: HiddenWordInkAxis) -> [CGRect?] {
        var result = [CGRect?](repeating: nil, count: words.count)
        guard let grid = HiddenWordInkCheck.Grid(pageSize: pageSize) else { return result }

        // The source lines: their non-whitespace glyphs in `page.string`
        // order, each in the reading frame, and the line's band across.
        struct SourceLine { var chars: [Character]; var boxes: [HiddenWordInkCheck.GridBox]; var rects: [CGRect]
                            var minY: Int; var maxY: Int }
        var lines: [SourceLine] = []
        for (_, lineGlyphs) in Dictionary(grouping: glyphs, by: \.line).sorted(by: { $0.key < $1.key }) {
            var line = SourceLine(chars: [], boxes: [], rects: [], minY: .max, maxY: .min)
            for g in lineGlyphs where !g.char.isWhitespace {
                guard let box = grid.box(g.rect) else { continue }
                let r = reading(box, axis)
                line.chars.append(g.char); line.boxes.append(r); line.rects.append(g.rect)
                line.minY = min(line.minY, r.minY); line.maxY = max(line.maxY, r.maxY)
            }
            if !line.chars.isEmpty { lines.append(line) }
        }

        // The export lines, each word in the reading frame, in order along
        // the line by position (never by the order the words are listed).
        for (_, indices) in Dictionary(grouping: words.indices, by: { words[$0].line }).sorted(by: { $0.key < $1.key }) {
            var entries: [(index: Int, chars: [Character], box: HiddenWordInkCheck.GridBox)] = []
            for i in indices {
                let chars = words[i].key.filter { !$0.isWhitespace }.map { $0 }
                guard !chars.isEmpty, let box = grid.box(words[i].rect) else { continue }
                entries.append((i, chars, reading(box, axis)))
            }
            entries.sort { ($0.box.minX, $0.box.maxX, String($0.chars)) < ($1.box.minX, $1.box.maxX, String($1.chars)) }

            // Every spelling of each word on a line whose band overlaps the
            // word's, its first glyph at most `capCells` of its cells away.
            let spellings: [[Candidate]] = entries.map { entry in
                let n = entry.chars.count, length = entry.box.maxX - entry.box.minX
                var found: [Candidate] = []
                for (li, line) in lines.enumerated()
                where line.minY < entry.box.maxY && entry.box.minY < line.maxY && line.chars.count >= n {
                    for s in 0...(line.chars.count - n) where Array(line.chars[s..<(s + n)]) == entry.chars {
                        let offset = entry.box.minX - line.boxes[s].minX
                        if n * abs(offset) <= capCells * length {
                            found.append(Candidate(line: li, start: s, end: s + n, offset: offset))
                        }
                    }
                }
                return found
            }

            // Rounds. Each judges every word still unaligned against the
            // alignments as they stood when the round began: its window is
            // centred on zero and on the offset of the nearest aligned word on
            // either side; the order then keeps the candidates that can stand.
            // One left standing aligns the word; more than one leaves it
            // unaligned for good. An aligned word stays aligned. The rounds end
            // when one aligns nothing new.
            // A word's window under `alignment`: its spellings whose offset lies
            // within its window of zero or of the nearest aligned word's offset
            // on either side; an aligned word's window is its alignment.
            func window(_ k: Int, _ alignment: [Int: Candidate]) -> [Candidate] {
                if let fixed = alignment[k] { return [fixed] }
                let n = entries[k].chars.count
                let w2n = window2n(length: entries[k].box.maxX - entries[k].box.minX, n: n)
                var centres = [0]
                if let left = (0..<k).reversed().first(where: { alignment[$0] != nil }) { centres.append(alignment[left]!.offset) }
                if let right = ((k + 1)..<entries.count).first(where: { alignment[$0] != nil }) {
                    centres.append(alignment[right]!.offset)
                }
                return spellings[k].filter { c in centres.contains { 2 * n * abs(c.offset - $0) <= w2n } }
            }
            var aligned: [Int: Candidate] = [:]
            var ambiguous = Set<Int>()
            while true {
                let settled = aligned
                let windows = entries.indices.map { window($0, settled) }
                let standing = inOrder(windows)
                var added: [Int: Candidate] = [:]
                for k in entries.indices where settled[k] == nil && !ambiguous.contains(k) {
                    if standing[k].count == 1, let only = standing[k].first { added[k] = only }
                    else if standing[k].count > 1 { ambiguous.insert(k) }
                }
                if added.isEmpty { break }
                aligned.merge(added) { old, _ in old }
            }

            for (k, entry) in entries.enumerated() {
                guard let c = aligned[k] else { continue }
                result[entry.index] = lines[c.line].rects[c.start..<c.end].reduce(CGRect.null) { $0.union($1) }
            }
        }
        return result
    }
}

extension HiddenWordInkCheck {

    /// One page: the export's words aligned to the source's hidden glyphs,
    /// then the predicate on the aligned words; an unaligned word makes the
    /// page not inspected when it could lie under a box.
    static func pageVerdict(
        pageIndex: Int, exportWords: [HiddenWordInkWord], glyphs: [HiddenWordInkGlyph],
        sourceInk: [HiddenWordInkWord], regions: [RedactionRegion], pageSize: CGSize,
        kind: HiddenWordInkPageKind, axis: HiddenWordInkAxis
    ) -> HiddenWordInkVerdict {
        if exportWords.isEmpty { return HiddenWordInkVerdict(notApplicable: .noText) }
        if regions.isEmpty { return HiddenWordInkVerdict(notApplicable: .noRegions) }
        if kind == .plain { return HiddenWordInkVerdict(notApplicable: .plainSource) }

        let aligned = HiddenWordInkAlign.align(words: exportWords, glyphs: glyphs, pageSize: pageSize, axis: axis)
        var placed: [HiddenWordInkWord] = []
        var unaligned: [HiddenWordInkWord] = []
        for (word, box) in zip(exportWords, aligned) {
            if let box { placed.append(HiddenWordInkWord(key: word.key, rect: box, line: word.line)) }
            else { unaligned.append(word) }
        }
        var verdict = placed.isEmpty ? HiddenWordInkVerdict()
            : verdict(pageIndex: pageIndex, output: placed, sourceInk: sourceInk, regions: regions,
                      pageSize: pageSize, kind: kind, axis: axis)
        if !unaligned.isEmpty, unalignedNearABox(unaligned, exportWords: exportWords, placed: placed,
                                                 sourceInk: sourceInk, regions: regions, pageSize: pageSize, axis: axis) {
            verdict.unplaceableNearBox = true
        }
        return verdict
    }

    /// Whether some unaligned word could lie under a box: its export box,
    /// widened along the line by its window, either mapped through its line's
    /// accepted fit (from the line's aligned words) meets a box's paint, or is
    /// within the drift reach of one (`nearAnyBox`, the predicate's own reach).
    /// The fitted test only ever adds "not inspected".
    static func unalignedNearABox(_ unaligned: [HiddenWordInkWord], exportWords: [HiddenWordInkWord],
                                  placed: [HiddenWordInkWord], sourceInk: [HiddenWordInkWord],
                                  regions: [RedactionRegion], pageSize: CGSize, axis: HiddenWordInkAxis) -> Bool {
        guard let grid = Grid(pageSize: pageSize) else { return true }
        let t: (GridBox) -> GridBox = { axis.isVertical ? $0.transposed : $0 }
        var boxes: [(UUID, GridBox)] = []
        for region in regions {
            guard let box = grid.box(region.normalizedRect) else { return true }
            boxes.append((region.id, t(box)))
        }
        let source = sourceInk.compactMap { w in grid.box(w.rect).map { GridWord(key: fold(w.key), raw: w.key, box: t($0)) } }
        func gridWords(_ words: [HiddenWordInkWord]) -> [GridWord] {
            words.compactMap { w in grid.box(w.rect).map { GridWord(key: fold(w.key), raw: w.key, box: t($0)) } }
                .sorted { ($0.box.minX, $0.box.maxX) < ($1.box.minX, $1.box.maxX) }
        }
        let exportByLine = Dictionary(grouping: exportWords, by: \.line)
        let placedByLine = Dictionary(grouping: placed, by: \.line)
        var fits: [Int: Fit?] = [:]
        for word in unaligned {
            guard let raw = grid.box(word.rect) else { return true }
            let lineWords = gridWords(exportByLine[word.line] ?? [word])
            guard !lineWords.isEmpty else { return true }
            var box = t(raw)
            let n = max(1, word.key.filter { !$0.isWhitespace }.count)
            // The window, in grid units, rounded up.
            let w2n = HiddenWordInkAlign.window2n(length: box.maxX - box.minX, n: n)
            let window = (w2n + 2 * n - 1) / (2 * n)
            box.minX -= window; box.maxX += window
            // Through the line's fit, when its aligned words give one.
            if fits[word.line] == nil {
                let aligned = gridWords(placedByLine[word.line] ?? [])
                fits[word.line] = aligned.isEmpty ? Fit?.none
                    : placedFit(aligned, line: LineFacts(aligned), source: source, boxes: boxes.map { $0.1 })
            }
            if let fit = fits[word.line] ?? nil {
                let mapped = fit.map(box)
                if boxes.contains(where: { mapped.overlaps($0.1) }) { return true }
            }
            if nearAnyBox(GridWord(key: fold(word.key), raw: word.key, box: box), line: LineFacts(lineWords),
                          boxes: boxes) {
                return true
            }
        }
        return false
    }
}
