/// What a page's unselected words show about a box: its line, the room it
/// stands in, the lines above and below it, how far its column reaches, and
/// whether the words beside it are its own run. Built from the page's words
/// minus every selected character; the selected text says only which room of
/// which line the box stands in.
///
/// Every comparison is between whole sixty-fourths of a point. Each letter's
/// box is turned into sixty-fourths once, rounded outward, when the page's
/// complement is made, and nothing after that reads a point.

/// Two facts of the page that say whether its words are the text its visible
/// print is drawn from, filled by the engine from its own page facts.
package struct PageTextFacts: Hashable, Sendable {
    /// The page draws text in an invisible mode.
    package var showsInvisibleText: Bool
    /// One stored picture covers half the page or more.
    package var carriesPageScaleImage: Bool

    package init(showsInvisibleText: Bool, carriesPageScaleImage: Bool) {
        self.showsInvisibleText = showsInvisibleText
        self.carriesPageScaleImage = carriesPageScaleImage
    }

    /// The facts of a plan made with no page's words: nothing of a page was
    /// read, and a plan with no words reads no line, so neither fact is used.
    /// A plan made from a page's words takes its facts from that page, the
    /// print-is-a-picture answer included.
    package static let noPageRead = PageTextFacts(showsInvisibleText: false, carriesPageScaleImage: false)
}

/// One letter as the complement reads it.
package struct ComplementLetter: Hashable, Sendable {
    package var offset: Int
    /// Its box, rounded outward to whole sixty-fourths.
    package var rect: PageRect64
    /// Its box's height in whole sixty-fourths, rounded to the nearest, as a
    /// word's letter size is counted.
    package var height: Int
}

/// The unselected letters of one word that stand together: a word with no
/// selected letter is one, and a selected letter splits a word into two.
package struct ComplementWord: Hashable, Sendable {
    /// The word's index in the page's partition.
    package var word: Int
    package var letters: [ComplementLetter]
    package var box: PageRect64
}

/// A line's words with no gap between them wider than the run gap.
package struct ComplementRun: Hashable, Sendable {
    /// The run's words, as indices into its line's words.
    package var words: Range<Int>
    package var box: PageRect64
}

/// Unselected words whose heights overlap by more than half the smaller,
/// left to right.
package struct ComplementLine: Hashable, Sendable {
    package var words: [ComplementWord]
    package var runs: [ComplementRun]
    package var box: PageRect64
    /// The line's height: its bounding rectangle's.
    package var height: Int { box.height }
}

/// A page's unselected words as lines, top to bottom.
package struct PageComplement: Hashable, Sendable {
    package var lines: [ComplementLine]
    /// The most common free space between consecutive lines, in whole
    /// sixty-fourths, when there are enough gaps to take it from.
    package var ordinaryGap: Int?
    /// For each line: its unselected words give no evidence against its
    /// direction, so it can show another box's column.
    package var usable: [Bool]
}

/// What a box reads on one of its lines.
package struct RowReading: Hashable, Sendable {
    /// The complement line the row is, or nil when no unselected word stands
    /// on it.
    package var line: Int?
    /// The box's selected letters on this row.
    package var tight: PageRect64
    /// The room's ends: the end of the nearest unselected word before the box
    /// and the start of the nearest after it; nil where the room is open.
    package var roomLeft: Int?
    package var roomRight: Int?
    /// The lines that bridge the room (N.3), as line indices.
    package var bridges: [Int]
    /// The box's own run on this row: the runs of the words beside the room,
    /// when enough lines bridge it; else nil.
    package var ownRun: PageRect64?
    /// How far the column reaches on each side, or nil where nothing shows it.
    package var columnLeft: Int?
    package var columnRight: Int?
    /// The column was read from runs of the stack that lie inside the room,
    /// closed on both sides: a table cell's own column.
    package var columnInsideRoom: Bool = false
}

/// What the complement reads for one box.
package struct BoxReading: Hashable, Sendable {
    /// The policy table's reading of the box's line.
    package var reading: LineReading
    /// The page's words are the text its visible print is drawn from.
    package var trusted: Bool
    /// The box's own line gives evidence that its print does not run level,
    /// upright and left to right.
    package var directionEvidence: Bool
    /// One row for each line the box stands on, top to bottom.
    package var rows: [RowReading]
    /// The usable lines of its stack other than its own, top to bottom.
    package var stack: [Int]
    /// The nearest usable line above the stack and below it.
    package var outsideAbove: Int?
    package var outsideBelow: Int?
}

extension PageRect64 {
    /// `rect` in whole sixty-fourths, each side rounded outward; nil when a
    /// side is not a finite number.
    package init?(outward rect: PointRect) {
        let sides = [rect.minX, rect.minY, rect.maxX, rect.maxY]
        guard sides.allSatisfy(\.isFinite) else { return nil }
        self.init(minX: Int((rect.minX * 64).rounded(.down)), minY: Int((rect.minY * 64).rounded(.down)),
                  maxX: Int((rect.maxX * 64).rounded(.up)), maxY: Int((rect.maxY * 64).rounded(.up)))
    }

    package func union(_ other: PageRect64) -> PageRect64 {
        PageRect64(minX: Swift.min(minX, other.minX), minY: Swift.min(minY, other.minY),
                   maxX: Swift.max(maxX, other.maxX), maxY: Swift.max(maxY, other.maxY))
    }

    /// Twice the vertical middle, so it stays a whole number.
    var middle2: Int { minY + maxY }

    /// How far the two overlap in height; zero or less when they do not.
    func heightOverlap(_ other: PageRect64) -> Int { Swift.min(maxY, other.maxY) - Swift.max(minY, other.minY) }

    /// Whether the two overlap in height by more than half the smaller height.
    func sharesALine(with other: PageRect64) -> Bool {
        2 * heightOverlap(other) > Swift.min(height, other.height)
    }

    /// Whether the two overlap along the line.
    func overlapsAlong(_ other: PageRect64) -> Bool { minX < other.maxX && other.minX < maxX }
}

package enum Complement {

    // MARK: - The page

    /// The letters of `word` that are not selected, by their first box; a
    /// letter with no box is left out.
    static func letters(of word: PageWord, keeping keep: (Int) -> Bool) -> [ComplementLetter] {
        var seen: Set<Int> = []
        var out: [ComplementLetter] = []
        for box in word.letterBoxes where keep(box.offset) && !seen.contains(box.offset) {
            guard let rect = PageRect64(outward: box.rect) else { continue }
            seen.insert(box.offset)
            out.append(ComplementLetter(offset: box.offset, rect: rect, height: Int((box.rect.height * 64).rounded())))
        }
        return out
    }

    /// The page's unselected words: each word's unselected letters, split
    /// where a selected letter stands between them.
    static func pieces(of words: PageWords, selected: Set<Int>) -> [ComplementWord] {
        var out: [ComplementWord] = []
        for word in words.words {
            let boxed = letters(of: word, keeping: { _ in true })
            let byOffset = Dictionary(boxed.map { ($0.offset, $0) }, uniquingKeysWith: { a, _ in a })
            var current: [ComplementLetter] = []
            func close() {
                if let first = current.first {
                    let box = current.dropFirst().reduce(first.rect) { $0.union($1.rect) }
                    out.append(ComplementWord(word: word.index, letters: current, box: box))
                }
                current = []
            }
            for offset in word.letters {
                if selected.contains(offset) { close(); continue }
                if let letter = byOffset[offset] { current.append(letter) }
            }
            close()
        }
        return out
    }

    /// The page's complement: its unselected words as lines and runs, the
    /// ordinary gap between lines, and which lines are usable.
    package static func page(words: PageWords, text: String, selected: Set<Int>,
                             constants: ProvisionalConstants) -> PageComplement {
        let pieces = pieces(of: words, selected: selected)
        let lines = lines(of: pieces, constants: constants)
        let units = Array(text.utf16)
        let usable = lines.map { line in
            !givesEvidence(words: line.words.map(\.letters), units: units, constants: constants)
        }
        return PageComplement(lines: lines, ordinaryGap: ordinaryGap(of: lines, constants: constants), usable: usable)
    }

    /// Lines: words joined when their heights overlap by more than half the
    /// smaller, and every word joined to a word of a line in that line.
    static func lines(of pieces: [ComplementWord], constants: ProvisionalConstants) -> [ComplementLine] {
        let order = pieces.indices.sorted { pieces[$0].box.minY < pieces[$1].box.minY }
        var parent = Array(pieces.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        for (k, i) in order.enumerated() {
            for j in order[(k + 1)...] {
                if pieces[j].box.minY >= pieces[i].box.maxY { break }
                if pieces[i].box.sharesALine(with: pieces[j].box) {
                    let a = root(i), b = root(j)
                    if a != b { parent[a] = b }
                }
            }
        }
        var groups: [Int: [ComplementWord]] = [:]
        for i in pieces.indices { groups[root(i), default: []].append(pieces[i]) }
        var lines: [ComplementLine] = groups.values.map { group in
            let words = group.sorted { ($0.box.minX, $0.box.maxX, $0.word) < ($1.box.minX, $1.box.maxX, $1.word) }
            let box = words.dropFirst().reduce(words[0].box) { $0.union($1.box) }
            return ComplementLine(words: words, runs: runs(of: words, height: box.height, constants: constants), box: box)
        }
        lines.sort { a, b in
            a.box.middle2 != b.box.middle2 ? a.box.middle2 > b.box.middle2 : a.box.minX < b.box.minX
        }
        return lines
    }

    /// A gap along a line wider than the run gap ends a run.
    package static func breaksRun(gap: Int, height: Int, constants: ProvisionalConstants) -> Bool {
        gap * constants.runGap.denominator > constants.runGap.numerator * height
    }

    static func runs(of words: [ComplementWord], height: Int, constants: ProvisionalConstants) -> [ComplementRun] {
        var runs: [ComplementRun] = []
        var start = 0
        var box = words[0].box
        for i in words.indices.dropFirst() {
            if breaksRun(gap: words[i].box.minX - box.maxX, height: height, constants: constants) {
                runs.append(ComplementRun(words: start..<i, box: box))
                start = i
                box = words[i].box
            } else {
                box = box.union(words[i].box)
            }
        }
        runs.append(ComplementRun(words: start..<words.count, box: box))
        return runs
    }

    /// The nearest line below `line` that overlaps it along the line, if any.
    static func nextBelow(_ index: Int, in lines: [ComplementLine], excluding: Set<Int> = []) -> Int? {
        let line = lines[index].box
        return lines.indices
            .filter { !excluding.contains($0) && $0 != index && lines[$0].box.middle2 < line.middle2 && lines[$0].box.overlapsAlong(line) }
            .max { lines[$0].box.middle2 < lines[$1].box.middle2 }
    }

    /// The most common free space between consecutive lines, counted in the
    /// table's steps (each rounded to the nearest, a half step up), the
    /// smaller on a tie; nil with fewer gaps than the table asks.
    static func ordinaryGap(of lines: [ComplementLine], constants: ProvisionalConstants) -> Int? {
        let spacing = constants.blockSpacing
        var counts: [Int: Int] = [:]
        var gaps = 0
        for i in lines.indices {
            guard let below = nextBelow(i, in: lines) else { continue }
            let free = lines[i].box.minY - lines[below].box.maxY
            guard free > 0 else { continue }
            gaps += 1
            counts[(free + spacing.stepSixtyFourths / 2) / spacing.stepSixtyFourths, default: 0] += 1
        }
        guard gaps >= spacing.fewestGaps,
              let steps = counts.max(by: { a, b in a.value != b.value ? a.value < b.value : a.key > b.key })?.key
        else { return nil }
        return steps * spacing.stepSixtyFourths
    }

    /// Whether two lines `free` apart stand close enough to be one stack: by
    /// the ordinary gap plus the table's excess of the smaller height, or,
    /// with no ordinary gap, under the table's share of that height.
    package static func keepsSpacing(free: Int, height: Int, ordinaryGap: Int?, constants: ProvisionalConstants) -> Bool {
        let spacing = constants.blockSpacing
        if let ordinaryGap {
            return free * spacing.excess.denominator
                <= ordinaryGap * spacing.excess.denominator + spacing.excess.numerator * height
        }
        return free * spacing.withoutOrdinaryGap.denominator < spacing.withoutOrdinaryGap.numerator * height
    }

    // MARK: - Direction (K.3)

    /// Whether a line's words give evidence that its print does not run
    /// level, upright and left to right: a word whose letters of its most
    /// common height do not lie on one row (test 1b), or whose first and last
    /// such letters, in the page's text order, do not advance to the right
    /// within the level slope (test 1); or a letter of a right-to-left script
    /// (test 2). A word with fewer than two such letters gives no evidence by
    /// tests 1 and 1b.
    static func givesEvidence(words: [[ComplementLetter]], units: [UInt16], constants: ProvisionalConstants) -> Bool {
        for letters in words {
            if wordGivesEvidence(letters, constants: constants) { return true }
            for letter in letters {
                if let scalar = scalar(at: letter.offset, in: units), constants.isRightToLeftLetter(scalar) { return true }
            }
        }
        return false
    }

    static func wordGivesEvidence(_ letters: [ComplementLetter], constants: ProvisionalConstants) -> Bool {
        var counts: [Int: Int] = [:]
        for letter in letters { counts[letter.height, default: 0] += 1 }
        guard let height = counts.max(by: { a, b in a.value != b.value ? a.value < b.value : a.key < b.key })?.key
        else { return false }
        // Letters of the most common height; a letter whose box is the one
        // before it (a mark on its letter, a joined glyph's second letter)
        // is the same place and is left out.
        var chosen: [ComplementLetter] = []
        for letter in letters where letter.height == height {
            if let last = chosen.last, last.rect == letter.rect { continue }
            chosen.append(letter)
        }
        guard let first = chosen.first, let last = chosen.last, chosen.count >= 2 else { return false }
        // Test 1b: one row.
        for letter in chosen.dropFirst() where !(2 * letter.rect.heightOverlap(first.rect) > Swift.min(letter.rect.height, first.rect.height)) {
            return true
        }
        // Test 1: the last lies to the right of the first, within the slope.
        let run = last.rect.minX - first.rect.minX
        guard run > 0 else { return true }
        let rise = abs(last.rect.minY - first.rect.minY)
        return rise * constants.levelSlope.denominator > constants.levelSlope.numerator * run
    }

    /// The scalar starting at a UTF-16 offset, nil for a trailing surrogate
    /// or an offset outside the string.
    static func scalar(at offset: Int, in units: [UInt16]) -> Unicode.Scalar? {
        guard offset >= 0, offset < units.count else { return nil }
        let unit = units[offset]
        if UTF16.isLeadSurrogate(unit), offset + 1 < units.count, UTF16.isTrailSurrogate(units[offset + 1]) {
            return Unicode.Scalar(UTF16.decode(UTF16.EncodedScalar([unit, units[offset + 1]])).value)
        }
        return Unicode.Scalar(unit)
    }
}

extension Complement {

    // MARK: - One box

    /// The nearest line above (`up`) or below `rect` that overlaps it along
    /// the line, leaving out `excluding`.
    static func nearest(_ up: Bool, of rect: PageRect64, in lines: [ComplementLine], excluding: Set<Int>) -> Int? {
        let candidates = lines.indices.filter { i in
            !excluding.contains(i) && lines[i].box.overlapsAlong(rect)
                && (up ? lines[i].box.middle2 > rect.middle2 : lines[i].box.middle2 < rect.middle2)
        }
        return up ? candidates.min { lines[$0].box.middle2 < lines[$1].box.middle2 }
                  : candidates.max { lines[$0].box.middle2 < lines[$1].box.middle2 }
    }

    /// From the box's top row up, or its bottom row down: the lines that keep
    /// the block's spacing, each next one with the one before it, and then
    /// the nearest usable line past them. A line that is not usable keeps the
    /// walk going and is not taken.
    static func walk(_ up: Bool, from start: PageRect64, on page: PageComplement, own: Set<Int>,
                     constants: ProvisionalConstants) -> (stack: [Int], outside: Int?) {
        var stack: [Int] = []
        var current = start
        var seen = own
        while let next = nearest(up, of: current, in: page.lines, excluding: seen) {
            seen.insert(next)
            let line = page.lines[next].box
            let free = up ? line.minY - current.maxY : current.minY - line.maxY
            guard keepsSpacing(free: free, height: Swift.min(current.height, line.height),
                               ordinaryGap: page.ordinaryGap, constants: constants)
            else {
                // Past the stack: the nearest usable line.
                var candidate: Int? = next
                var from = line
                while let c = candidate, !page.usable[c] {
                    from = page.lines[c].box
                    candidate = nearest(up, of: from, in: page.lines, excluding: seen)
                    if let n = candidate { seen.insert(n) }
                }
                return (stack, candidate)
            }
            if page.usable[next] { stack.append(next) }
            current = line
        }
        return (stack, nil)
    }

    /// The rows of a box: its selected letters, joined as the page's lines
    /// are joined, top to bottom.
    static func rows(of letters: [ComplementLetter]) -> [PageRect64] {
        var rows: [PageRect64] = []
        for letter in letters.sorted(by: { $0.rect.middle2 > $1.rect.middle2 }) {
            if let i = rows.firstIndex(where: { $0.sharesALine(with: letter.rect) }) {
                rows[i] = rows[i].union(letter.rect)
            } else {
                rows.append(letter.rect)
            }
        }
        // Rows that came to share a line as they grew are one row.
        var merged: [PageRect64] = []
        for row in rows {
            if let i = merged.firstIndex(where: { $0.sharesALine(with: row) }) { merged[i] = merged[i].union(row) }
            else { merged.append(row) }
        }
        return merged.sorted { $0.middle2 > $1.middle2 }
    }

    /// The complement line a row stands on: the one sharing a line with it
    /// that overlaps it most in height, the nearer middle on a tie.
    static func line(of row: PageRect64, in lines: [ComplementLine]) -> Int? {
        lines.indices.filter { lines[$0].box.sharesALine(with: row) }.max { a, b in
            let oa = lines[a].box.heightOverlap(row), ob = lines[b].box.heightOverlap(row)
            if oa != ob { return oa < ob }
            return abs(lines[a].box.middle2 - row.middle2) > abs(lines[b].box.middle2 - row.middle2)
        }
    }

    /// The reading of one box: `box` is its selected letters' offsets, and
    /// `page` the complement made with every box of the page selected. Nil
    /// when no selected letter has a box.
    package static func reading(of box: Set<Int>, on page: PageComplement, words: PageWords, text: String,
                                facts: PageTextFacts, constants: ProvisionalConstants) -> BoxReading? {
        let own = words.words.filter { word in word.letters.contains(where: box.contains) }
        let selectedLetters = own.flatMap { letters(of: $0, keeping: box.contains) }
        guard !selectedLetters.isEmpty else { return nil }
        let rowRects = rows(of: selectedLetters)

        // Trust: the page half from the page's facts, the word half from the
        // words the box stands in.
        let trusted = !facts.showsInvisibleText && !facts.carriesPageScaleImage
            && own.allSatisfy { $0.source == .textLayer }
        let lineIndices = rowRects.map { line(of: $0, in: page.lines) }

        // Direction: the box's own lines, read from every word on them, the
        // selected ones included.
        let units = Array(text.utf16)
        let directionEvidence = zip(rowRects, lineIndices).contains { row, line in
            let reference = line.map { page.lines[$0].box.union(row) } ?? row
            let onLine = words.words.compactMap { word -> [ComplementLetter]? in
                let letters = letters(of: word, keeping: { _ in true })
                guard let first = letters.first else { return nil }
                let wordBox = letters.dropFirst().reduce(first.rect) { $0.union($1.rect) }
                return wordBox.sharesALine(with: reference) ? letters : nil
            }
            return givesEvidence(words: onLine, units: units, constants: constants)
        }

        let reading: LineReading
        if !trusted { reading = .scanOrPicture }
        else if directionEvidence { reading = .direction }
        else { reading = .column }
        guard reading == .column else {
            return BoxReading(reading: reading, trusted: trusted, directionEvidence: directionEvidence,
                              rows: [], stack: [], outsideAbove: nil, outsideBelow: nil)
        }

        let ownLines = Set(lineIndices.compactMap { $0 })
        let top = lineIndices[0].map { page.lines[$0].box } ?? rowRects[0]
        let bottom = lineIndices[lineIndices.count - 1].map { page.lines[$0].box } ?? rowRects[rowRects.count - 1]
        let above = walk(true, from: top, on: page, own: ownLines, constants: constants)
        let below = walk(false, from: bottom, on: page, own: ownLines.union(above.stack).union(above.outside.map { [$0] } ?? []),
                         constants: constants)
        let stack = above.stack.reversed() + below.stack
        let outside = [above.outside, below.outside].compactMap { $0 }

        let rows = zip(rowRects, lineIndices).map { row, line in
            rowReading(row: row, line: line, page: page, stack: stack, ownLines: ownLines, outside: outside,
                       constants: constants)
        }
        let anyColumn = !stack.isEmpty || !outside.isEmpty
        return BoxReading(reading: anyColumn ? .column : .noColumn, trusted: true, directionEvidence: false,
                          rows: rows, stack: Array(stack), outsideAbove: above.outside, outsideBelow: below.outside)
    }

    // MARK: - One row: room, column, bridges, own run

    static func rowReading(row: PageRect64, line: Int?, page: PageComplement, stack: [Int], ownLines: Set<Int>,
                           outside: [Int], constants: ProvisionalConstants) -> RowReading {
        let words = line.map { page.lines[$0].words } ?? []
        let height = line.map { page.lines[$0].height } ?? row.height
        let before = words.filter { $0.box.minX + $0.box.maxX < row.minX + row.maxX }
        let after = words.filter { $0.box.minX + $0.box.maxX >= row.minX + row.maxX }
        let roomLeft = before.map(\.box.maxX).max()
        let roomRight = after.map(\.box.minX).min()

        // The room, as an interval along the line; an open side is unbounded.
        func overlapsRoom(_ run: PageRect64) -> Bool {
            (roomRight.map { run.minX < $0 } ?? true) && (roomLeft.map { run.maxX > $0 } ?? true)
        }
        // Where the box's column meets its own line: the room when
        // it is closed on both sides, the end of the word before or the start
        // of the word after when it is open on one, and the box itself when
        // it is alone on its line.
        let anchor: (lo: Int, hi: Int) = switch (roomLeft, roomRight) {
        case let (l?, r?): (l, r)
        case let (l?, nil): (l, l)
        case let (nil, r?): (r, r)
        case (nil, nil): (row.minX, row.maxX)
        }
        let gap = constants.runGap.numerator * height  // compared against gap × denominator
        func meetsAnchor(_ run: PageRect64) -> Bool {
            (run.minX - anchor.hi) * constants.runGap.denominator <= gap
                && (anchor.lo - run.maxX) * constants.runGap.denominator <= gap
        }

        let stackRuns = stack.flatMap { page.lines[$0].runs.map(\.box) }
        var candidates = stackRuns.filter(overlapsRoom)
        var inside = false
        if let l = roomLeft, let r = roomRight {
            let within = candidates.filter { $0.minX >= l && $0.maxX <= r }
            if !within.isEmpty { candidates = within; inside = true }
        }

        /// The space past `from` up to `to` on a side holds no word of `lines`
        /// except those of runs that meet the anchor (`exceptMeeting`).
        func spaceIsEmpty(right: Bool, from: Int, to: Int, lines: [Int], exceptMeeting: Bool) -> Bool {
            for i in lines {
                for run in page.lines[i].runs where !(exceptMeeting && meetsAnchor(run.box)) {
                    for w in page.lines[i].words[run.words] {
                        let inSpace = right ? (w.box.maxX > from && w.box.minX < to) : (w.box.minX < from && w.box.maxX > to)
                        if inSpace { return false }
                    }
                }
            }
            return true
        }

        var columnLeft: Int?
        var columnRight: Int?
        for c in candidates {
            if inside || (meetsAnchor(c) && spaceIsEmpty(right: true, from: anchor.hi, to: c.maxX, lines: stack, exceptMeeting: true)) {
                columnRight = Swift.max(columnRight ?? c.maxX, c.maxX)
            }
            if inside || (meetsAnchor(c) && spaceIsEmpty(right: false, from: anchor.lo, to: c.minX, lines: stack, exceptMeeting: true)) {
                columnLeft = Swift.min(columnLeft ?? c.minX, c.minX)
            }
        }
        // N.2 item 2: the outside lines, where the space between the stack's
        // own reach and theirs holds no word of the stack's lines.
        let stackLines = stack + ownLines.sorted()
        let reachRight = Swift.max(columnRight ?? anchor.hi, anchor.hi)
        let reachLeft = Swift.min(columnLeft ?? anchor.lo, anchor.lo)
        for o in outside {
            for run in page.lines[o].runs.map(\.box) where overlapsRoom(run) && meetsAnchor(run) {
                if run.maxX > reachRight, spaceIsEmpty(right: true, from: reachRight, to: run.maxX, lines: stackLines, exceptMeeting: false) {
                    columnRight = Swift.max(columnRight ?? run.maxX, run.maxX)
                }
                if run.minX < reachLeft, spaceIsEmpty(right: false, from: reachLeft, to: run.minX, lines: stackLines, exceptMeeting: false) {
                    columnLeft = Swift.min(columnLeft ?? run.minX, run.minX)
                }
            }
        }

        // On a side where the room is closed the column is read no further
        // than the room's end: past it the stop pulls the band back to the
        // word that closes the room, so no reading reaches across it into
        // another column, cell or field.
        if let l = roomLeft { columnLeft = columnLeft.map { Swift.max($0, l) } }
        if let r = roomRight { columnRight = columnRight.map { Swift.min($0, r) } }

        // N.3: the lines that bridge the room.
        var bridges: [Int] = []
        if roomLeft != nil || roomRight != nil {
            let separateRunInside: Bool = {
                switch (roomLeft, roomRight) {
                case let (l?, nil):
                    return stack.contains { i in page.lines[i].runs.contains { $0.box.minX > l } }
                case let (nil, r?):
                    return stack.contains { i in page.lines[i].runs.contains { $0.box.maxX < r } }
                default: return false
                }
            }()
            if !separateRunInside {
                for i in stack + outside {
                    let runs = page.lines[i].runs
                    let bridged: Bool
                    switch (roomLeft, roomRight) {
                    case let (l?, r?):
                        bridged = runs.contains { $0.box.minX <= l && $0.box.maxX >= r }
                    case let (l?, nil):
                        bridged = runs.last.map { $0.box.minX <= l && $0.box.maxX - l >= height } ?? false
                    case let (nil, r?):
                        bridged = runs.first.map { $0.box.maxX >= r && r - $0.box.minX >= height } ?? false
                    case (nil, nil):
                        bridged = false
                    }
                    if bridged { bridges.append(i) }
                }
            }
        }
        var ownRun: PageRect64?
        if bridges.count >= constants.bridgingLines, let line {
            let ownLine = page.lines[line]
            let beside = [before.max { $0.box.maxX < $1.box.maxX }, after.min { $0.box.minX < $1.box.minX }].compactMap { $0 }
            for word in beside {
                if let k = ownLine.words.firstIndex(of: word), let run = ownLine.runs.first(where: { $0.words.contains(k) }) {
                    ownRun = ownRun.map { $0.union(run.box) } ?? run.box
                }
            }
        }
        return RowReading(line: line, tight: row, roomLeft: roomLeft, roomRight: roomRight, bridges: bridges,
                          ownRun: ownRun, columnLeft: columnLeft, columnRight: columnRight,
                          columnInsideRoom: inside && (columnLeft != nil || columnRight != nil))
    }
}
