import Foundation
import OSLog
import PDFKit

// The OCR literal route's one matcher: every literal match on a scanned page
// (Text and Multi-term), within one recognised line or running from the end
// of one line into the next ("Jane" ending one line, "Doe" starting the
// next). It searches the page's recognised lines as Vision read them, joined
// in reading order, one line feed between them, through the literal tier's
// own preparation, where a line feed folds as on a text-layer
// page (to a space, or to nothing after a word's own hyphen). Two lines join only when the next one lies below the
// previous one and their spans across the page overlap: lines of different
// columns never overlap and are kept apart by a character no query holds,
// while an indented first line, a centred line or a short last line joins.
// Below and across are read as the page is displayed, or, on a scan whose
// print runs sideways, upside down or at a slant of more than 3 degrees,
// along the direction the page's print runs: the mean of the lines' own
// directions (each from the centre of its first word box to the centre of
// its last, in page points) that lie within 20 degrees of the mean of all of
// them, set only when at least three lines lie within those 20 degrees. A
// line whose own direction is more than 20 degrees from the page's, such as
// an upright stamp on a sideways scan, joins only as displayed.
// Both sides of the match take the match skeleton (`OCRMatchSkeleton`): the
// confusable classes of Scan's normalizer, so a typed "Suite 100" matches a
// line read "Suite 1OO"; the lines through Scan's confusable correction are
// read too, as typed (a "1D" Vision read for "ID"), a range both readings
// hold kept once; accents fold on both sides, and the query's edge symbols
// are trimmed. A match is boxed on every line it touches (the
// counting rule of a wrapped text-layer match): one result per line, the
// lines of one match sharing one occurrence. Each line's box is the words
// its part of the match covers (Vision's word boxes,
// `OCREngine.TextLine.wordBoxes`), padded as every OCR box is, never the whole
// line; a line whose words have no box falls back to the line's box, and the
// count of such lines is logged. On iOS 27 a space beside a separator inside
// a digit run folds on both sides, and each range comes back to the read
// line's offsets through the fold's map before a word is boxed. The displayed text is sliced from the
// recognised text itself, what the OCR Check reads. The Search Re-check
// re-runs this searcher on the output, so an instance left printed reads as
// found there too.
private let ocrLiteralLogger = Logger(subsystem: "com.resecta.app", category: "search")
/// A line agrees with a direction when the angle between them is at most 20 degrees.
private let printAgreementCosine = cos(20 * Double.pi / 180)
/// Print is turned when its direction is more than 3 degrees from horizontal.
private let printTurnedCosine = cos(3 * Double.pi / 180)

extension DocumentSearcher {

    /// Whether a phrase may run from the end of `line` into the start of `next`:
    /// `next` lies below `line` and the two lines' spans across the page
    /// overlap (one column).
    nonisolated static func linesJoin(_ line: CGRect, _ next: CGRect) -> Bool {
        next.midY < line.midY && next.minX < line.maxX && line.minX < next.maxX
    }

    /// The direction `line`'s print runs, in page points (`pageSize`, the
    /// displayed page): a unit vector from the centre of its first word box to
    /// the centre of its last, by their order in the line's text; nil for a
    /// line with fewer than two word boxes or whose first and last share a centre.
    nonisolated static func lineDirection(_ line: OCREngine.TextLine, pageSize: CGSize) -> CGVector? {
        let boxes = line.wordBoxes.sorted { $0.range.location < $1.range.location }
        guard boxes.count >= 2, let first = boxes.first?.normalizedRect, let last = boxes.last?.normalizedRect else { return nil }
        return unitVector(CGVector(dx: (last.midX - first.midX) * pageSize.width, dy: (last.midY - first.midY) * pageSize.height))
    }

    /// The direction the page's print runs: the mean of the lines' own
    /// directions that lie within 20 degrees of the mean of all of them, or
    /// nil when fewer than three lines have a direction or fewer than three
    /// lie within those 20 degrees.
    nonisolated static func printDirection(_ lines: [OCREngine.TextLine], pageSize: CGSize) -> CGVector? {
        printDirection(of: lines.map { lineDirection($0, pageSize: pageSize) })
    }

    /// `printDirection(_:pageSize:)` on the lines' own directions.
    nonisolated static func printDirection(of lineDirections: [CGVector?]) -> CGVector? {
        let directions = lineDirections.compactMap { $0 }
        guard directions.count >= 3, let mean = unitSum(directions) else { return nil }
        let agreeing = directions.filter { dot($0, mean) >= printAgreementCosine }
        guard agreeing.count >= 3 else { return nil }
        return unitSum(agreeing)
    }

    /// Whether a phrase may run from the end of `line` into the start of
    /// `next`: today's test as displayed, or, where the page's print
    /// direction is set and more than 3 degrees from horizontal and neither
    /// line's own direction is more than 20 degrees from it, `next` lies
    /// below `line` and their spans overlap, both measured along that
    /// direction in page points.
    nonisolated static func linesJoin(
        _ line: CGRect, _ next: CGRect, lineDirection: CGVector?, nextDirection: CGVector?,
        printDirection: CGVector?, pageSize: CGSize
    ) -> Bool {
        if linesJoin(line, next) { return true }
        guard let along = printDirection, along.dx < printTurnedCosine else { return false }
        for own in [lineDirection, nextDirection] { if let own, dot(own, along) < printAgreementCosine { return false } }
        let scale = CGAffineTransform(scaleX: pageSize.width, y: pageSize.height)
        let a = line.applying(scale), b = next.applying(scale)
        let down = CGVector(dx: along.dy, dy: -along.dx)
        let below = dot(CGVector(dx: b.midX - a.midX, dy: b.midY - a.midY), down) > 0
        func span(_ rect: CGRect) -> (lower: CGFloat, upper: CGFloat) {
            let ends = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                        CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
                .map { dot(CGVector(dx: $0.x, dy: $0.y), along) }
            return (ends.min() ?? 0, ends.max() ?? 0)
        }
        let (aSpan, bSpan) = (span(a), span(b))
        let overlap = aSpan.lower < bSpan.upper && bSpan.lower < aSpan.upper
        return below && overlap
    }

    private nonisolated static func dot(_ a: CGVector, _ b: CGVector) -> CGFloat { a.dx * b.dx + a.dy * b.dy }

    private nonisolated static func unitVector(_ v: CGVector) -> CGVector? {
        let length = (v.dx * v.dx + v.dy * v.dy).squareRoot()
        return length > 0 ? CGVector(dx: v.dx / length, dy: v.dy / length) : nil
    }

    private nonisolated static func unitSum(_ vectors: [CGVector]) -> CGVector? {
        unitVector(vectors.reduce(CGVector(dx: 0, dy: 0)) { CGVector(dx: $0.dx + $1.dx, dy: $0.dy + $1.dy) })
    }

    /// The box of the part `local` (UTF-16, in the line's text) of a match on
    /// `line`: the union of the words it overlaps, or nil when no word has a box.
    nonisolated static func matchedWordsRect(_ line: OCREngine.TextLine, local: NSRange) -> CGRect? {
        let boxes = line.wordBoxes.filter { NSIntersectionRange($0.range, local).length > 0 }.map(\.normalizedRect)
        guard let first = boxes.first else { return nil }
        return boxes.dropFirst().reduce(first) { $0.union($1) }
    }

    /// The two readings of a page's recognised lines: as Vision read them,
    /// and through Scan's confusable correction (`OCRTextNormalizer`). The
    /// correction keeps a line's UTF-16 length; a line where it would not
    /// reads raw in both, so one set of line offsets serves both readings and
    /// a range means the same place in either.
    func ocrReadings(_ lines: [OCREngine.TextLine]) -> (raw: [String], corrected: [String]) {
        let raw = lines.map(\.text)
        let corrected = lines.map { line -> String in
            let text = ocrNormalizer.normalize(line.text)
            return text.utf16.count == line.text.utf16.count ? text : line.text
        }
        return (raw, corrected)
    }

    func ocrLiteralMatches(
        lines: [OCREngine.TextLine], query: String, options: SearchOptions,
        page: PDFPage, pageIndex: Int, term: String
    ) -> [SearchResult] {
        guard !lines.isEmpty else { return [] }
        let (rawTexts, correctedTexts) = ocrReadings(lines)
        // Each line's span in the joined text, in UTF-16 units; a line that
        // does not join the next is followed by U+FFFC, which no query holds.
        // The print direction is the page's, from every recognised line.
        let pageSize = effectiveBounds(page.bounds(for: .cropBox), rotation: page.rotation).size
        let ownDirections = lines.map { Self.lineDirection($0, pageSize: pageSize) }
        let printDirection = Self.printDirection(of: ownDirections)
        var separators: [String] = []
        var spans: [Range<Int>] = []
        var cursor = 0
        for (index, text) in rawTexts.enumerated() {
            let length = (text as NSString).length
            spans.append(cursor..<(cursor + length))
            guard index + 1 < rawTexts.count else { break }
            let joins = Self.linesJoin(
                lines[index].normalizedRect, lines[index + 1].normalizedRect,
                lineDirection: ownDirections[index], nextDirection: ownDirections[index + 1],
                printDirection: printDirection, pageSize: pageSize)
            let separator = joins ? "\n" : "\n\u{FFFC}\n"
            separators.append(separator)
            cursor += length + (separator as NSString).length
        }
        func joinedText(_ texts: [String]) -> String {
            zip(texts, separators + [""]).map { $0 + $1 }.joined()
        }
        let joined = joinedText(rawTexts)
        // iOS 27 can read a space beside a separator inside a digit run
        // ("555- 0147"). There both readings and the query fold it
        // (`TextNormalizer.foldOCRSeparatorSpacesMapped`), and every range
        // comes back to the read text's offsets through the fold's map, so a
        // line's part of a match and its word boxes stay where Vision read
        // them. iOS 26 reads keep their text.
        let foldsSeparatorSpaces: Bool = { if #available(iOS 27, *) { return true }; return false }()
        func reading(_ text: String) -> (text: String, offsetMap: [Int]?) {
            foldsSeparatorSpaces ? TextNormalizer.foldOCRSeparatorSpacesMapped(text) : (text, nil)
        }
        let rawReading = reading(joined)
        let effective = SearchCore.effectiveOptions(OCRMatchSkeleton.options(options), pageText: joined, detectCJK: true)
        let typedQuery = OCRMatchSkeleton.trimmedQuery(query)
        let normalizedQuery = SearchCore.normalizedText(
            foldsSeparatorSpaces ? TextNormalizer.foldOCRSeparatorSpaces(typedQuery) : typedQuery, options: effective)
        guard !normalizedQuery.isEmpty else { return [] }
        // The raw reading matches on the skeleton (the typed digits against
        // the digits Vision read); the corrected reading matches as typed
        // (letters Vision read as digits, "1D" for "ID"). A range both
        // readings hold is kept once.
        func ranges(in reading: (text: String, offsetMap: [Int]?), skeleton: Bool) -> [NSRange] {
            let page = SearchCore.preparePage(reading.text, options: effective)
            let prepared = skeleton ? OCRMatchSkeleton.skeleton(page) : page
            let typed = skeleton ? OCRMatchSkeleton.skeleton(normalizedQuery) : normalizedQuery
            let searchQuery = SearchCore.preparedQuery(normalized: typed, options: effective)
            guard !searchQuery.isEmpty else { return [] }
            return SearchCore.literalSpans(
                in: prepared, query: searchQuery, comparison: [], wholeWord: effective.wholeWord, cap: nil
            ).spans.compactMap { prepared.rawNSRange(of: $0) }
                .map { TextNormalizer.unfoldedRange($0, offsetMap: reading.offsetMap) }
        }
        var seen = Set<NSRange>()
        let matches = (ranges(in: rawReading, skeleton: true) + ranges(in: reading(joinedText(correctedTexts)), skeleton: false))
            .filter { seen.insert($0).inserted }
            .sorted { $0.location < $1.location }
        // The shown text is the raw reading as matched, folded where it was.
        let text = rawReading.text as NSString
        // The context reads the separator of two unjoined lines as a space.
        let shown = rawReading.text.replacingOccurrences(of: "\u{FFFC}", with: " ")
        var results: [SearchResult] = []
        var lineFallbacks = 0
        for raw in matches {
            let touched = spans.indices.filter { spans[$0].lowerBound < NSMaxRange(raw) && spans[$0].upperBound > raw.location }
            let display = TextNormalizer.foldedRange(raw, offsetMap: rawReading.offsetMap)
            let matchedText = TextNormalizer.foldWhitespaceRuns(text.substring(with: display))
            let window = contextSnippet(text: shown, matchNSRange: display)
            let occurrence = touched.count > 1 ? UUID() : nil
            for index in touched {
                let lower = max(raw.location, spans[index].lowerBound), upper = min(NSMaxRange(raw), spans[index].upperBound)
                let local = NSRange(location: lower - spans[index].lowerBound, length: upper - lower)
                let words = Self.matchedWordsRect(lines[index], local: local)
                if words == nil { lineFallbacks += 1 }
                results.append(SearchResult(
                    pageIndex: pageIndex,
                    normalizedRect: Self.paddedNormalizedRect(words ?? lines[index].normalizedRect, in: page),
                    matchedText: matchedText,
                    contextSnippet: window.snippet,
                    source: .ocr(confidence: lines[index].confidence),
                    term: term,
                    matchRangeInSnippet: window.matchRange,
                    occurrenceID: occurrence))
            }
        }
        if lineFallbacks > 0 {
            ocrLiteralLogger.log("OCR literal match: \(lineFallbacks, privacy: .public) line part(s) boxed by the whole line (no word box)")
        }
        return results
    }
}
