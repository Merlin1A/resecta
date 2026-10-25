import CoreGraphics
import Foundation
import PDFKit

// Layer lines that are not the text printed on their band (`DocumentSearcher+InkFit.swift`):
// an exporter that interleaved two runs sharing a band, character by character,
// wrote a line no read row agrees with. A word matched there (as a substring of a
// garbled token) has no place on the page: its box is the line's whole printed
// band, degraded (the widened-box notice tells the user).

/// Per page content key: the starts (in the page text) of its interleaved
/// layer lines, and the pages found to have any.
final class InkFitInterleaveCache: @unchecked Sendable {
    static let shared = InkFitInterleaveCache()
    private let lock = NSLock()
    private var lines: [Int: Set<Int>] = [:]
    func value(for key: Int) -> Set<Int>? { lock.withLock { lines[key] } }
    func set(_ value: Set<Int>, for key: Int) { lock.withLock { lines[key] = value } }
}

extension DocumentSearcher {
    /// A layer line this long (alignment-key letters) or longer is judged;
    /// a shorter one (a label, a value) can disagree with its band by chance.
    static let inkFitInterleaveMinimum = 12

    /// The read rows on the band of `box` (reading frame): Vision's lines
    /// there, those at one height joined left to right.
    nonisolated static func readRows(near box: CGRect, tokens: [InkToken]) -> [[InkToken]] {
        let reach = max(box.height, 4)
        var lines: [Int: [InkToken]] = [:]
        for token in tokens where abs(token.rect.midY - box.midY) <= reach { lines[token.line, default: []].append(token) }
        var rows: [[InkToken]] = []
        for line in lines.values.sorted(by: { $0[0].rect.midY > $1[0].rect.midY }) {
            let mid = line.map(\.rect.midY).reduce(0, +) / CGFloat(line.count)
            let height = line.map(\.rect.height).max() ?? 0
            if let i = rows.firstIndex(where: { row in
                abs(row.map(\.rect.midY).reduce(0, +) / CGFloat(row.count) - mid) <= 0.35 * height
            }) { rows[i] += line } else { rows.append(line) }
        }
        return rows.map { $0.sorted { $0.rect.minX < $1.rect.minX } }
    }

    /// Whether a layer line's letters (`lineKey`, long enough to judge) agree
    /// with no read row on the band of `box`, where Vision read at least half
    /// as many letters there.
    nonisolated static func interleaved(_ lineKey: [Character], near box: CGRect, tokens: [InkToken]) -> Bool {
        guard lineKey.count >= inkFitInterleaveMinimum else { return false }
        let rows = readRows(near: box, tokens: tokens)
        let read = rows.map { $0.map(\.key).joined().count }.max() ?? 0
        guard read * 2 >= lineKey.count else { return false }
        return !rows.contains { row in
            let readKey = Array(row.map(\.key).joined())
            return !readKey.isEmpty && align(lineKey, readKey).score * 2 >= min(lineKey.count, readKey.count)
        }
    }

    /// The page's interleaved layer lines (their starts in `pageText`): a line
    /// long enough to judge whose letters agree with no read row on its band
    /// (less than half of the shorter, where Vision read at least half as
    /// many letters there). Read once per page content, from its tokens.
    nonisolated static func interleavedLines(pageKey: Int, pageText: NSString, tokens: [InkToken],
                                             layerBox: (Int) -> CGRect?) -> Set<Int> {
        if let known = InkFitInterleaveCache.shared.value(for: pageKey) { return known }
        var found = Set<Int>()
        var location = 0
        while location < pageText.length {
            let line = pageText.lineRange(for: NSRange(location: location, length: 0))
            defer { location = max(NSMaxRange(line), location + 1) }
            let text = pageText.substring(with: line)
            let lineKey = Array(alignmentKey(Substring(text)))
            guard lineKey.count >= inkFitInterleaveMinimum else { continue }
            var first = line.location
            while first < NSMaxRange(line), let scalar = Unicode.Scalar(pageText.character(at: first)),
                  !CharacterSet.alphanumerics.contains(scalar) { first += 1 }
            guard first < NSMaxRange(line), let band = layerBox(first) else { continue }
            if interleaved(lineKey, near: band, tokens: tokens) { found.insert(line.location) }
        }
        InkFitInterleaveCache.shared.set(found, for: pageKey)
        return found
    }

    /// The printed band of a layer line around `box` (reading frame): every
    /// read word on it, the layer's box, a margin, clamped to `size`.
    nonisolated static func printedBand(around box: CGRect, tokens: [InkToken], size: CGSize) -> CGRect {
        // As far across as a layer was measured to sit from its ink.
        let reach = max(box.height, inkFitDriftAcross)
        let band = tokens.filter { abs($0.rect.midY - box.midY) <= reach }.map(\.rect).reduce(box) { $0.union($1) }
        return band.insetBy(dx: -inkFitAnchorMargin, dy: -inkFitAnchorReach * box.height)
            .intersection(CGRect(origin: .zero, size: size))
    }

    /// The box of a match on an interleaved layer line: the line's whole
    /// printed band, degraded. Nil when the match's line is not interleaved.
    nonisolated static func interleavedBand(_ job: InkFitJob, tokens: [InkToken], box: CGRect) -> CGRect? {
        if let range = job.range {
            let text = job.pageText as NSString
            let lineStart = text.lineRange(for: NSRange(location: range.location, length: 0)).location
            guard interleavedLines(pageKey: job.pageKey, pageText: text, tokens: tokens, layerBox: job.layerBox).contains(lineStart)
            else { return nil }
        } else {
            // A whole line fitted by its text (an address line): judged by
            // its own letters against the read rows on its band.
            guard let text = job.text, interleaved(Array(alignmentKey(Substring(text))), near: box, tokens: tokens) else { return nil }
        }
        inkFitLogger.log("ink fit: the layer's line is interleaved; the box is the line's printed band, degraded")
        let wide = job.envelope()
        let band = job.frame.toVisual(printedBand(around: box, tokens: tokens, size: job.frame.size))
        guard !band.isNull, !band.isEmpty else { return wide }
        return CGRect(x: band.minX / job.visual.width, y: band.minY / job.visual.height,
                      width: band.width / job.visual.width, height: band.height / job.visual.height).clampedToNormalized()
    }
}
