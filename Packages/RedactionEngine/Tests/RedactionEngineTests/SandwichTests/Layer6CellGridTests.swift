import Testing
import Foundation
import CoreGraphics
import CoreText
import PDFKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
@testable import RedactionEngine

// Character Positions and a piece the writer starts on its line's cell grid.
//
// The source page is set in Helvetica 12 pt on 11.5 pt lines, so a letter's
// box on one line reaches into the line above. A Search box for "Supply"
// ends its line; on the line below, "≈" (drawn in Courier at 0.549 of the
// size, not one cell) stands 3.58 pt before the box's left edge. The letters
// under the box on that line are removed and the writer splits the line
// there; the next piece starts on the line's cell grid, so it is not a whole
// number of cells past the "≈". The control has "x" in its place, and the
// ordinary page sets the same text on 14.4 pt lines. The text holds joined
// letters ("fi" in "finished", "ffi" in "office", one of them on the box's
// own line), whose line's hidden letters and drawn cells the writer moves;
// the plain page sets the same lines with other words in their place.
//
// The made layers draw invisible Courier pieces the way the writer does
// (one CTLineDraw per piece, at the piece's origin) on a page with no box.

@Suite("Character Positions accepts a piece that starts on its line's cell grid")
struct Layer6CellGridTests {
    typealias F = HiddenWordInkFixtures
    let verifier = SandwichVerification()
    static let advanceFail = VerificationStatus.fail("Non-uniform glyph advance on page 1")

    // MARK: - The source page

    static func helvetica(_ text: String) -> CTLine {
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let attributes = [kCTFontAttributeName as String: font] as CFDictionary
        return CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attributes)!)
    }

    static func lines(mark: String, joinedLetters: Bool = true) -> [String] {
        let finished = joinedLetters ? "finished" : "closed"
        let office = joinedLetters ? "office" : "desk"
        return [
            "The notes below cover the work done in the last quarter.",
            "Each team lists what it \(finished) and what is still open.",
            "Open items carry a short line on what they wait for now.",
            "Questions about these notes go to the \(office) named here.",
            "Each \(office) keeps one copy of the list it calls Supply",
            "The cost rose \(mark) and the rest of the line runs on past it.",
            "The list is read again at the start of the next quarter.",
            "Nothing here changes the plan the teams agreed last year.",
        ]
    }

    /// The source page, with `/Rotate` set to `rotate` when it is not 0.
    static func sourcePage(mark: String, leading: CGFloat, rotate: Int = 0, joinedLetters: Bool = true) throws -> Data {
        let text = lines(mark: mark, joinedLetters: joinedLetters)
        let top: CGFloat = 700
        let boxLine = text[4] as NSString
        let boxX = 72 + CTLineGetOffsetForStringIndex(helvetica(text[4]), boxLine.range(of: "Supply").location, nil)
        let markRange = (text[5] as NSString).range(of: mark)
        let markRight = CTLineGetOffsetForStringIndex(helvetica(text[5]), markRange.location + markRange.length, nil)
        let markLineX = boxX - 3.58 - markRight
        let out = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try #require(CGDataConsumer(data: out as CFMutableData))
        let ctx = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        ctx.textMatrix = .identity
        for (i, line) in text.enumerated() {
            ctx.textPosition = CGPoint(x: i == 5 ? markLineX : 72, y: top - leading * CGFloat(i))
            CTLineDraw(helvetica(line), ctx)
        }
        ctx.endPDFPage()
        ctx.closePDF()
        guard rotate != 0 else { return out as Data }
        let doc = try #require(PDFDocument(data: out as Data))
        try #require(doc.page(at: 0)).rotation = rotate
        return try #require(doc.dataRepresentation())
    }

    /// The page exported Searchable with a Search box for "Supply", through
    /// the corpus mirror's route, and verified once.
    static func exportRun(mark: String, leading: CGFloat, rotate: Int = 0, joinedLetters: Bool = true) async throws -> F.Run {
        let data = try sourcePage(mark: mark, leading: leading, rotate: rotate, joinedLetters: joinedLetters)
        let source = try #require(PDFDocument(data: data)?.page(at: 0))
        let strip = try #require(F.hiddenRect(source, "Supply"))
        return try await F.mirrorRun(data, paint: strip, searchTerm: "Supply", strip: strip)
    }

    static func positionsRow(_ run: F.Run) throws -> VerificationStatus {
        try #require(run.report.layers.first { $0.layer == .spatialVerification }).status
    }

    // MARK: - Reading the hidden layer back

    struct Unit {
        let text: String
        let bounds: CGRect
        let size: CGFloat
    }

    /// The page's non-whitespace read-back units with a font size.
    static func units(_ page: PDFPage) -> [Unit] {
        let ns = (page.string ?? "") as NSString
        var out: [Unit] = []
        var offset = 0
        while offset < page.numberOfCharacters {
            let range = ns.rangeOfComposedCharacterSequence(at: offset)
            defer { offset += max(range.length, 1) }
            let text = ns.substring(with: range)
            guard !SandwichMetrics.isLineageWhitespace(text), let sel = page.selection(for: range) else { continue }
            let bounds = sel.bounds(for: page)
            guard bounds.width > 0, bounds.height > 0 else { continue }
            var size: CGFloat = 0
            #if canImport(UIKit)
            if let a = sel.attributedString, a.length > 0,
               let f = a.attribute(.font, at: 0, effectiveRange: nil) as? UIFont { size = f.pointSize }
            #else
            if let a = sel.attributedString, a.length > 0,
               let f = a.attribute(.font, at: 0, effectiveRange: nil) as? NSFont { size = f.pointSize }
            #endif
            if size > 0 { out.append(Unit(text: text, bounds: bounds, size: size)) }
        }
        return out
    }

    /// Where a letter starts, measured from the edge its line starts at on
    /// a page written from a source turned `rotate`: the left edge (0), the
    /// top (90), the right (180), the bottom (270).
    static func fromStartEdge(_ b: CGRect, box: CGRect, rotate: Int) -> CGFloat {
        switch rotate {
        case 90: return box.maxY - b.maxY
        case 180: return box.maxX - b.maxX
        case 270: return b.minY - box.minY
        default: return b.minX - box.minX
        }
    }

    /// How far a length lies from a whole number of cells.
    static func offGrid(_ length: CGFloat, cell: CGFloat) -> CGFloat {
        abs(length - (length / cell).rounded() * cell)
    }

    /// The units of the mark's line in reading order.
    static func markLine(_ page: PDFPage, mark: String, rotate: Int) throws -> [Unit] {
        let all = units(page)
        let m = try #require(all.first { $0.text == mark }, "the mark must read back")
        let vertical = rotate == 90 || rotate == 270
        let line = all.filter { vertical ? abs($0.bounds.minX - m.bounds.minX) < 1 : abs($0.bounds.minY - m.bounds.minY) < 1 }
        let box = page.bounds(for: .cropBox)
        return line.sorted { fromStartEdge($0.bounds, box: box, rotate: rotate) < fromStartEdge($1.bounds, box: box, rotate: rotate) }
    }

    /// The shape the fix is for, read on the export: the letter after the
    /// mark is not a whole number of cells past the mark's own advance, and
    /// it starts on the line's cell grid from the edge the line starts at.
    /// Returns that letter's distance from the edge, in cells.
    @discardableResult
    static func requireShape(_ page: PDFPage, mark: String, rotate: Int) throws -> CGFloat {
        let line = try markLine(page, mark: mark, rotate: rotate)
        let k = try #require(line.firstIndex { $0.text == mark })
        try #require(k + 1 < line.count, "a letter must follow the mark on its line")
        let a = line[k], b = line[k + 1]
        let box = page.bounds(for: .cropBox)
        let cell = SandwichMetrics.courierAdvancePerPoint * a.size
        let tolerance = SandwichMetrics.advanceWidthTolerancePerPoint * a.size
        let courier = CTFontCreateWithName("Courier" as CFString, a.size, nil)
        let markLine = CTLineCreateWithAttributedString(
            NSAttributedString(string: mark, attributes: [.font: courier]))
        let natural = CGFloat(CTLineGetTypographicBounds(markLine, nil, nil, nil))
        let delta = fromStartEdge(b.bounds, box: box, rotate: rotate) - fromStartEdge(a.bounds, box: box, rotate: rotate)
        try #require(delta > natural + cell, "the line must be split after the mark")
        let pastMark = offGrid(delta - natural, cell: cell)
        let start = fromStartEdge(b.bounds, box: box, rotate: rotate)
        print("turn \(rotate): the letter after \"\(mark)\" is \(String(format: "%.4f", start / cell)) cells from the start edge; "
              + "\(String(format: "%.3f", pastMark)) pt off whole cells past the mark (tolerance \(String(format: "%.4f", tolerance)))")
        try #require(pastMark > tolerance, "the letter after the mark must not be a whole number of cells past it")
        try #require(offGrid(start, cell: cell) <= tolerance, "the next piece must start on the line's cell grid")
        return start / cell
    }

    // MARK: - A-1 and A-2: the made pages

    @Test("A-1: a tightly set page with \"≈\" before the split reads the control's edge warning, not Failed",
          .timeLimit(.minutes(3)))
    func a1() async throws {
        let run = try await Self.exportRun(mark: "≈", leading: 11.5)
        try Self.requireShape(try #require(run.output.page(at: 0)), mark: "≈", rotate: 0)
        let control = try await Self.exportRun(mark: "x", leading: 11.5)
        let row = try Self.positionsRow(run)
        #expect(!row.isFail, "Character Positions must not fail a correct export; got \(row)")
        #expect(row == (try Self.positionsRow(control)), "the case must read as its control does")
        #expect(run.report.layers.allSatisfy { !$0.status.isFail }, "with nothing else failing the headline is not Checks Failed")
    }

    /// How many lines of the source draw fewer glyphs than they hold
    /// characters: a line with a joined letter pair.
    static func linesWithJoinedLetters(_ text: [String]) -> Int {
        text.filter { CTLineGetGlyphCount(helvetica($0)) < ($0 as NSString).length }.count
    }

    @Test("A-2: the control and the ordinary page read the edge warning, and the plain page reads Passed (pins)",
          .timeLimit(.minutes(3)))
    func a2() async throws {
        let control = try await Self.exportRun(mark: "x", leading: 11.5)
        #expect(try Self.positionsRow(control) == SandwichVerification.grazeWarning(pages: [0]))
        // The box's own line holds the joined "ffi" of "office": the writer
        // moves that line's drawn cells, and the "s" of "calls" grazes the
        // box's edge.
        try #require(Self.linesWithJoinedLetters(Self.lines(mark: "≈")) > 0, "the ordinary page must hold joined letters")
        let ordinary = try await Self.exportRun(mark: "≈", leading: 14.4)
        #expect(try Self.positionsRow(ordinary) == SandwichVerification.grazeWarning(pages: [0]))
        try #require(Self.linesWithJoinedLetters(Self.lines(mark: "≈", joinedLetters: false)) == 0,
                     "the plain page must hold no joined letters")
        let plain = try await Self.exportRun(mark: "≈", leading: 14.4, joinedLetters: false)
        #expect(try Self.positionsRow(plain) == .pass)
    }

    // MARK: - A-3, A-4 and A-8: made hidden layers

    static let size: CGFloat = 9
    static var cell: CGFloat { SandwichMetrics.courierAdvancePerPoint * size }

    /// Invisible Courier pieces drawn writer-style on one line at y 600.
    static func madeLayer(_ pieces: [(text: String, x: CGFloat)]) throws -> PDFPage {
        let out = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try #require(CGDataConsumer(data: out as CFMutableData))
        let ctx = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        ctx.setTextDrawingMode(.invisible)
        let font = CTFontCreateWithName("Courier" as CFString, size, nil)
        for piece in pieces {
            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(x: piece.x, y: 600)
            CTLineDraw(CTLineCreateWithAttributedString(
                NSAttributedString(string: piece.text, attributes: [.font: font])), ctx)
            ctx.restoreGState()
        }
        ctx.endPDFPage()
        ctx.closePDF()
        let page = try #require(PDFDocument(data: out as Data)?.page(at: 0))
        let read = (page.string ?? "").filter { !$0.isWhitespace }
        try #require(read == pieces.map(\.text).joined(), "the made layer must read back (got \(read))")
        return page
    }

    static func courierAdvance(_ text: String) -> CGFloat {
        let font = CTFontCreateWithName("Courier" as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    @Test("A-3: after an off-cell character, a character 1 pt from both allowed places fails")
    func a3() async throws {
        let first = "abc≈", start = 20 * Self.cell
        let end = start + Self.courierAdvance(first)
        let second = 30 * Self.cell + 1
        let pastFirst = Self.offGrid(second - end, cell: Self.cell)
        try #require(min(pastFirst, Self.cell - pastFirst) >= 1, "1 pt or more from every place past the first piece")
        try #require(Self.offGrid(second, cell: Self.cell) >= 1, "1 pt or more from the grid")
        let page = try Self.madeLayer([(first, start), ("def", second)])
        #expect(try await verifier.verifySpatialExclusion(outputPage: page, regionShapes: []) == Self.advanceFail)
    }

    @Test("A-4: after a one-cell character, a character moved 1 pt fails (a pin)")
    func a4() async throws {
        let page = try Self.madeLayer([("abcd", 20 * Self.cell), ("efg", 30 * Self.cell + 1)])
        #expect(try await verifier.verifySpatialExclusion(outputPage: page, regionShapes: []) == Self.advanceFail)
    }

    @Test("A-8: a piece whose letters each stand 0.38 of the size off the grid, then a piece on the grid, does not fail")
    func a8() async throws {
        let offset = 0.38 * Self.size
        let page = try Self.madeLayer([("abcd", 20 * Self.cell + offset), ("efgh", 30 * Self.cell)])
        let line = Self.units(page).sorted { $0.bounds.minX < $1.bounds.minX }
        let d = try #require(line.first { $0.text == "d" }), e = try #require(line.first { $0.text == "e" })
        let tolerance = SandwichMetrics.advanceWidthTolerancePerPoint * Self.size
        try #require(Self.offGrid(d.bounds.minX, cell: Self.cell) > tolerance, "the first piece's letters stand off the grid")
        try #require(Self.offGrid(e.bounds.minX - d.bounds.minX - Self.cell, cell: Self.cell) > tolerance,
                     "the second piece is not a whole number of cells past the first")
        let row = try await verifier.verifySpatialExclusion(outputPage: page, regionShapes: [])
        #expect(!row.isFail, "a piece that starts on the grid must not fail; got \(row)")
    }

    // MARK: - A-5 and A-6: pages written from a turned source

    @Test("A-5: the A-1 page from a source turned 90 and from one turned 270 is not Failed",
          .timeLimit(.minutes(3)))
    func a5() async throws {
        for rotate in [90, 270] {
            let run = try await Self.exportRun(mark: "≈", leading: 11.5, rotate: rotate)
            try Self.requireShape(try #require(run.output.page(at: 0)), mark: "≈", rotate: rotate)
            let row = try Self.positionsRow(run)
            #expect(!row.isFail, "turn \(rotate): Character Positions must not fail; got \(row)")
        }
    }

    /// On a page written from a source turned 180 the lines run from the
    /// right edge, an edge the rule does not name: the page keeps today's
    /// reading.
    @Test("A-6: from a source turned 180 the lines start at the right edge, and the page still reads Failed (a pin)",
          .timeLimit(.minutes(3)))
    func a6() async throws {
        let run = try await Self.exportRun(mark: "≈", leading: 11.5, rotate: 180)
        let page = try #require(run.output.page(at: 0))
        let cells = try Self.requireShape(page, mark: "≈", rotate: 180)
        let line = try Self.markLine(page, mark: "≈", rotate: 180)
        let k = try #require(line.firstIndex { $0.text == "≈" })
        let next = line[k + 1], markUnit = line[k]
        let cell = SandwichMetrics.courierAdvancePerPoint * next.size
        let tolerance = SandwichMetrics.advanceWidthTolerancePerPoint * next.size
        // The check walks a horizontal line in X order, so of the pair
        // across the split it tests the later one in X order, the mark,
        // against a grid from the left edge.
        let markFromLeft = markUnit.bounds.minX - page.bounds(for: .cropBox).minX
        print("turn 180: the next piece starts \(String(format: "%.4f", cells)) cells from the right edge; "
              + "the mark, the later of the pair in X order, starts \(String(format: "%.4f", markFromLeft / cell)) cells from the left edge")
        try #require(Self.offGrid(markFromLeft, cell: cell) > tolerance,
                     "the later of the pair in X order is not on a grid from the left edge")
        #expect(try Self.positionsRow(run) == Self.advanceFail)
    }

    // MARK: - A-7: a correct export's hidden layer

    @Test("A-7: every letter of a correct export starts within the tolerance of its line's grid",
          .timeLimit(.minutes(3)))
    func a7() async throws {
        for rotate in [0, 90, 270] {
            let run = try await Self.exportRun(mark: "x", leading: 14.4, rotate: rotate)
            let page = try #require(run.output.page(at: 0))
            let box = page.bounds(for: .cropBox)
            let all = Self.units(page)
            try #require(all.count > 300, "the export must carry its text layer")
            var largest: CGFloat = 0
            for unit in all {
                let cell = SandwichMetrics.courierAdvancePerPoint * unit.size
                let distance = Self.offGrid(Self.fromStartEdge(unit.bounds, box: box, rotate: rotate), cell: cell)
                largest = max(largest, distance)
                #expect(distance <= SandwichMetrics.advanceWidthTolerancePerPoint * unit.size,
                        "turn \(rotate): \"\(unit.text)\" stands \(distance) pt off its grid")
            }
            print("turn \(rotate): \(all.count) letters; the largest distance from the grid is \(String(format: "%.5f", largest)) pt")
        }
    }
}
