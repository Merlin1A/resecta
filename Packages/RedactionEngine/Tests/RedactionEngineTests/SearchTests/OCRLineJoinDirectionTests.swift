import Testing
import Foundation
import PDFKit
import CoreGraphics
@testable import RedactionEngine

// A phrase on a scanned page that wraps from the end of one recognised line
// into the next, on print that does not run upright: a page scanned
// sideways or upside down, or at a slant. The lines are built by hand as the
// recogniser returns them (in reading order, each line's box and its words'
// boxes in the displayed frame, 0 to 1 from the bottom left) and searched on
// a blank page of the displayed size. No recognition runs.
//
// A layout is set upright on a 612 x 792 pt page: each line a box in points
// and its text, each word's box the line's height and the share of the
// line's width its characters take. A skew turns every corner about the
// page's centre (counter-clockwise positive) and takes each box's enclosing
// upright box; a turn is clockwise, by quarter turns.

struct PrintedWord: Sendable {
    var range: NSRange
    var rect: CGRect
}

struct PrintedLine: Sendable {
    var text: String
    var rect: CGRect
    var words: [PrintedWord]
}

enum PrintLayout {
    static let letter = CGSize(width: 612, height: 792)

    /// A line set upright, its baseline `top` points under the frame's top
    /// edge, `size` points high, `width` points wide (half the size a
    /// character when not given).
    static func line(_ text: String, x: CGFloat, top: CGFloat, width: CGFloat? = nil,
                     size: CGFloat = 12, frameHeight: CGFloat = 792) -> PrintedLine {
        let total = CGFloat((text as NSString).length)
        let lineWidth = width ?? total * size * 0.5
        let rect = CGRect(x: x, y: frameHeight - top - size * 0.25, width: lineWidth, height: size)
        let runs = (try? NSRegularExpression(pattern: "\\S+"))?
            .matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) ?? []
        let words = runs.map { run in
            PrintedWord(range: run.range, rect: CGRect(
                x: x + lineWidth * CGFloat(run.range.location) / total, y: rect.minY,
                width: lineWidth * CGFloat(run.range.length) / total, height: size))
        }
        return PrintedLine(text: text, rect: rect, words: words)
    }

    /// Every box of `line` through `map`, as its enclosing upright box.
    static func mapped(_ line: PrintedLine, _ map: (CGPoint) -> CGPoint) -> PrintedLine {
        func box(_ rect: CGRect) -> CGRect {
            let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                           CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)].map(map)
            let xs = corners.map(\.x), ys = corners.map(\.y)
            let minX = xs.min() ?? 0, minY = ys.min() ?? 0
            return CGRect(x: minX, y: minY, width: (xs.max() ?? 0) - minX, height: (ys.max() ?? 0) - minY)
        }
        return PrintedLine(text: line.text, rect: box(line.rect),
                           words: line.words.map { PrintedWord(range: $0.range, rect: box($0.rect)) })
    }

    /// The lines turned `degrees` counter-clockwise about the letter page's centre.
    static func skewed(_ lines: [PrintedLine], by degrees: CGFloat) -> [PrintedLine] {
        let angle = degrees * .pi / 180, centre = CGPoint(x: 306, y: 396)
        return lines.map { line in
            mapped(line) { point in
                let dx = point.x - centre.x, dy = point.y - centre.y
                return CGPoint(x: centre.x + dx * cos(angle) - dy * sin(angle),
                               y: centre.y + dx * sin(angle) + dy * cos(angle))
            }
        }
    }

    /// The lines of a `frame`-sized frame turned clockwise by `degrees` (0,
    /// 90, 180 or 270), with the turned frame's size.
    static func turned(_ lines: [PrintedLine], by degrees: Int, frame: CGSize = letter) -> (lines: [PrintedLine], size: CGSize) {
        let w = frame.width, h = frame.height
        switch degrees {
        case 90: return (lines.map { mapped($0) { CGPoint(x: $0.y, y: w - $0.x) } }, CGSize(width: h, height: w))
        case 180: return (lines.map { mapped($0) { CGPoint(x: w - $0.x, y: h - $0.y) } }, frame)
        case 270: return (lines.map { mapped($0) { CGPoint(x: h - $0.y, y: $0.x) } }, CGSize(width: h, height: w))
        default: return (lines, frame)
        }
    }

    /// The lines moved by `offset` points.
    static func moved(_ lines: [PrintedLine], by offset: CGPoint) -> [PrintedLine] {
        lines.map { mapped($0) { CGPoint(x: $0.x + offset.x, y: $0.y + offset.y) } }
    }

    /// The lines as the recogniser returns them on a page of `page` points.
    static func recognised(_ lines: [PrintedLine], page: CGSize) -> [OCREngine.TextLine] {
        let scale = CGAffineTransform(scaleX: 1 / page.width, y: 1 / page.height)
        return lines.map { line in
            OCREngine.TextLine(
                text: line.text, normalizedRect: line.rect.applying(scale), confidence: 1,
                wordBoxes: line.words.map { OCREngine.WordBox(range: $0.range, normalizedRect: $0.rect.applying(scale)) })
        }
    }
}

/// The words (by their order in the line) of one line a match is boxed on.
struct BoxedPart: Sendable {
    let line: Int
    let words: [Int]
    init(_ line: Int, _ words: [Int]) { self.line = line; self.words = words }
}

/// One search on a layout: no parts means no result.
struct LayoutSearch: Sendable {
    let query: String
    let parts: [BoxedPart]
}

struct LineJoinCase: Sendable, CustomTestStringConvertible {
    let name: String
    let lines: [PrintedLine]
    let page: CGSize
    let searches: [LayoutSearch]
    var testDescription: String { name }
}

enum PrintDirectionExpectation: Sendable {
    case notSet
    case setNotTurned
    case along(CGVector)
    case degrees(CGFloat)
}

struct PrintDirectionCase: Sendable, CustomTestStringConvertible {
    let name: String
    let lines: [PrintedLine]
    let page: CGSize
    let expect: PrintDirectionExpectation
    var testDescription: String { name }
}

enum TurnedPrintLayouts {
    typealias L = PrintLayout

    // One column of a letter: the second line ends "Corliss &", the third
    // starts "Pemberton Benefits Advisors, LLC"; the fourth holds a
    // one-line value.
    static let column: [PrintedLine] = [
        L.line("Stop-Loss Proposal Summary", x: 72, top: 96, size: 18),
        L.line("Prepared for the plan sponsor by its carrier, through Corliss &", x: 72, top: 148),
        L.line("Pemberton Benefits Advisors, LLC. Proposed policy NGI-SL-552190, effective", x: 72, top: 170),
        L.line("January 1, 2027. Questions go to Northgate Indemnity Company at the address", x: 72, top: 192),
        L.line("on the cover page. This page is synthetic and made for a measurement.", x: 72, top: 214),
    ]
    static let wrappedValue = LayoutSearch(query: "Corliss & Pemberton Benefits Advisors, LLC",
                                           parts: [BoxedPart(1, [9, 10]), BoxedPart(2, [0, 1, 2, 3])])
    static let oneLineValue = LayoutSearch(query: "Northgate Indemnity Company", parts: [BoxedPart(3, [6, 7, 8])])

    // Four full 7-inch lines over a half-inch last line; the fourth ends
    // "Jane", the last starts "Doe".
    static func shortLastLine(size: CGFloat, pitch: CGFloat) -> [PrintedLine] {
        let texts = ["The claim was opened on the first of the month and sent on to the office",
                     "of the adjuster, who asked for the signed form and the original receipt",
                     "from the store. The form came back with a note that it should go to",
                     "the account holder named on the policy, who is listed there as Mrs Jane"]
        var lines = texts.enumerated().map { L.line($1, x: 54, top: 300 + CGFloat($0) * pitch, width: 504, size: size) }
        lines.append(L.line("Doe Ltd", x: 54, top: 300 + 4 * pitch, width: 36, size: size))
        return lines
    }
    static let shortLastLineValue = LayoutSearch(query: "Jane Doe", parts: [BoxedPart(3, [13]), BoxedPart(4, [0])])

    // A narrow block: a value over three lines.
    static let threeLines: [PrintedLine] = [
        L.line("Stop-Loss Renewal Notice", x: 72, top: 96),
        L.line("The renewal was arranged by", x: 72, top: 136),
        L.line("Ashcombe Lindqvist", x: 72, top: 156),
        L.line("Benefits Consulting", x: 72, top: 176),
        L.line("Group, which holds the file.", x: 72, top: 196),
        L.line("This page is synthetic and made for a measurement.", x: 72, top: 216),
    ]
    static let threeLineValue = LayoutSearch(query: "Ashcombe Lindqvist Benefits Consulting Group",
                                             parts: [BoxedPart(2, [0, 1]), BoxedPart(3, [0, 1]), BoxedPart(4, [0])])

    // Two columns, returned column 1 whole before column 2. A value wraps
    // inside column 1; column 1's last line ends "Wexmoor" on the row where
    // column 2's last line starts "Freight".
    static let twoColumns: [PrintedLine] = {
        let first = ["The adviser of record for the plan is", "Halloran Ridge", "Partners LLP, which also prepares",
                     "the annual notice for the sponsor and", "keeps the signed copy of this letter at",
                     "its office. Questions on the renewal go", "to the adviser in writing. Wexmoor"]
        let second = ["The carrier sends its own notice by", "post within thirty days of the renewal",
                      "date. Its records are held apart from", "the adviser's and are not shared without",
                      "the sponsor's written consent to do so.", "This page is synthetic, for a measurement.",
                      "Freight handles the mailing for both."]
        return first.enumerated().map { L.line($1, x: 72, top: 96 + CGFloat($0) * 20) }
            + second.enumerated().map { L.line($1, x: 330, top: 96 + CGFloat($0) * 20) }
    }()
    static let columnWrapValue = LayoutSearch(query: "Halloran Ridge Partners LLP", parts: [BoxedPart(1, [0, 1]), BoxedPart(2, [0, 1])])
    static let rowAcrossColumns = LayoutSearch(query: "Wexmoor Freight", parts: [])
    static let columnFootIntoHead = LayoutSearch(query: "Wexmoor The carrier", parts: [])

    // A wrap from an indented first line, into a centred line, and into a
    // short last line, each with two more lines.
    static let indentedFirstLine: [PrintedLine] = [
        L.line("Please contact Jane", x: 108, top: 300),
        L.line("Doe about the claim and the form", x: 72, top: 320),
        L.line("that was sent on to the office last week.", x: 72, top: 340),
        L.line("This page is made for a measurement.", x: 72, top: 360),
    ]
    static let indentedValue = LayoutSearch(query: "Jane Doe", parts: [BoxedPart(0, [2]), BoxedPart(1, [0])])
    static let centredLine: [PrintedLine] = [
        L.line("The office asks that you please contact Jane", x: 72, top: 300),
        L.line("Doe at the front desk", x: 141, top: 320),
        L.line("during the hours that are set out below.", x: 72, top: 340),
        L.line("This page is made for a measurement.", x: 72, top: 360),
    ]
    static let centredValue = LayoutSearch(query: "Jane Doe", parts: [BoxedPart(0, [7]), BoxedPart(1, [0])])
    static let shortParagraphEnd: [PrintedLine] = [
        L.line("The form was sent to the office in March and", x: 72, top: 300),
        L.line("has to be signed by the holder, Mrs Jane", x: 72, top: 320),
        L.line("Doe and Co.", x: 72, top: 340),
        L.line("This page is made for a measurement.", x: 72, top: 380),
    ]
    static let shortEndValue = LayoutSearch(query: "Jane Doe", parts: [BoxedPart(1, [8]), BoxedPart(2, [0])])

    // Lines too short to give a direction.
    static let oneWordLines: [PrintedLine] = ["Jane", "Doe", "Smith", "Office", "Street"].enumerated()
        .map { L.line($1, x: 72, top: 300 + CGFloat($0) * 20) }
    static let twoLines: [PrintedLine] = [L.line("Please contact Jane", x: 72, top: 300),
                                          L.line("Doe about the claim", x: 72, top: 320)]
    static let shortWrap = LayoutSearch(query: "Jane Doe", parts: [])

    // Upright body lines, the second ending "Jane" and the third starting "Doe".
    static let body: [PrintedLine] = [
        "The renewal file was opened by the plan office", "and sent for review to the adviser, Jane",
        "Doe of the regional office, who signs it", "and returns it to the sponsor within a week.",
        "A copy is kept with the signed letter of", "the carrier for the year of the renewal.",
    ].enumerated().map { L.line($1, x: 72, top: 96 + CGFloat($0) * 20) }

    // A block of sideways lines (set upright in their own frame, turned 90
    // and placed on the right of a letter page); the first ends "Mark", the
    // second starts "Roe".
    static func sidewaysBlock(_ count: Int) -> [PrintedLine] {
        let texts = ["Received from the carrier by Mark", "Roe at the front desk on Monday",
                     "and filed with the renewal papers.", "The papers are kept for six years",
                     "and then sent back to the sponsor.", "This page is made for a measurement.",
                     "A second copy goes to the adviser.", "The adviser keeps it for a year."]
        let frame = CGSize(width: 300, height: 20 * CGFloat(count) + 20)
        let upright = texts.prefix(count).enumerated().map { L.line($1, x: 20, top: 20 + CGFloat($0) * 20, frameHeight: frame.height) }
        return L.moved(L.turned(upright, by: 90, frame: frame).lines, by: CGPoint(x: 420, y: 150))
    }

    /// Body lines 1 to 2 (the wrap) as the page's only upright lines, with `count` sideways lines.
    static func mixedPage(uprightLines: Int, sidewaysLines: Int) -> [PrintedLine] {
        let upright = uprightLines == 6 ? body : Array(body[1..<(1 + uprightLines)])
        return upright + sidewaysBlock(sidewaysLines)
    }

    // A sideways scan: `count` lines set upright on a letter page and turned
    // 90; the tenth ends "Jane" and the eleventh starts "Doe". Upright
    // `header` and `footer` lines may stand above and below it.
    static func sidewaysScan(_ count: Int, header: Bool, footer: Bool) -> [PrintedLine] {
        let texts = (0..<count).map { index -> String in
            switch index {
            case 9: return "the notes for this item go on to Jane"
            case 10: return "Doe at the office, who keeps them"
            default: return "the notes for item \(index + 1) are kept with the file"
            }
        }
        let turned = L.turned(texts.enumerated().map { L.line($1, x: 72, top: 96 + CGFloat($0) * 20) }, by: 90).lines
        return (header ? [L.line("RECEIVED 2 NOV 2026", x: 520, top: 40, frameHeight: 612)] : [])
            + turned
            + (footer ? [L.line("Page 1 of 1", x: 360, top: 600, frameHeight: 612)] : [])
    }
    static func sidewaysScanValue(header: Bool) -> LayoutSearch {
        let first = header ? 10 : 9
        return LayoutSearch(query: "Jane Doe", parts: [BoxedPart(first, [8]), BoxedPart(first + 1, [0])])
    }

    // A sideways page of five lines with one upright line between its second
    // and third; the third, returned next, lies to the upright line's left
    // across its height.
    static let uprightLineBesideSideways: [PrintedLine] = {
        let texts = ["The form was sent to the office and kept", "with the notes for the year of the renewal",
                     "Kim was the clerk who signed for it then", "and passed it on to the plan sponsor in",
                     "the week after it came in from the carrier."]
        let tops: [CGFloat] = [96, 116, 300, 320, 340]
        let sideways = L.turned(zip(texts, tops).map { L.line($0, x: 72, top: $1) }, by: 90).lines
        let upright = L.line("Filed by Ann", x: 540, top: 212, frameHeight: 612)
        return Array(sideways[0..<2]) + [upright] + Array(sideways[2...])
    }()

    // Two blocks of three lines side by side, the right one starting under
    // the left one's last line, with no overlap across the page.
    static let staggeredBlocks: [PrintedLine] = [
        L.line("The form goes to the office of", x: 72, top: 300),
        L.line("the plan sponsor, who signs and", x: 72, top: 320),
        L.line("returns it to Mark", x: 72, top: 340),
        L.line("Roe and Sons keep the copy", x: 330, top: 360),
        L.line("of the form for the file", x: 330, top: 380),
        L.line("and send it back in a week.", x: 330, top: 400),
    ]

    // A line ending "Lee" over a line "Lee Lee and others".
    static let repeatedWord: [PrintedLine] = [
        L.line("The claim was signed for the office by Lee", x: 72, top: 300),
        L.line("Lee Lee and others in the same week, as", x: 72, top: 320),
        L.line("the letter from the carrier sets out there.", x: 72, top: 340),
        L.line("This page is made for a measurement.", x: 72, top: 360),
    ]

    // Two lines reading right and two reading left.
    static let opposedLines: [PrintedLine] = {
        let right = [L.line("The form was sent to the office", x: 72, top: 300),
                     L.line("and kept with the notes there", x: 72, top: 320)]
        let frame = CGSize(width: 300, height: 60)
        let left = L.turned([L.line("The copy goes back to the sponsor", x: 20, top: 20, frameHeight: 60),
                             L.line("who keeps it for the year", x: 20, top: 40, frameHeight: 60)], by: 180, frame: frame).lines
        return right + L.moved(left, by: CGPoint(x: 150, y: 100))
    }()
}

@Suite("OCR phrase across lines on print that is not upright")
struct OCRLineJoinDirectionTests {
    typealias Layouts = TurnedPrintLayouts

    static func turnedCases(_ name: String, _ lines: [PrintedLine], _ searches: [LayoutSearch]) -> [LineJoinCase] {
        [0, 90, 180, 270].map { turn in
            let (turnedLines, size) = PrintLayout.turned(lines, by: turn)
            return LineJoinCase(name: "\(name), turned \(turn)", lines: turnedLines, page: size, searches: searches)
        }
    }

    static func skewCase(_ name: String, _ lines: [PrintedLine], skew: CGFloat, turn: Int = 0,
                         _ search: LayoutSearch) -> LineJoinCase {
        let (turnedLines, size) = PrintLayout.turned(PrintLayout.skewed(lines, by: skew), by: turn)
        return LineJoinCase(name: "\(name), skew \(skew), turned \(turn)", lines: turnedLines, page: size, searches: [search])
    }

    static let joinCases: [LineJoinCase] = {
        var rows = turnedCases("one column: the wrapped value on two boxes, the one-line value on one",
                               Layouts.column, [Layouts.wrappedValue, Layouts.oneLineValue])
        let shortLast = Layouts.shortLastLine(size: 12, pitch: 14)
        for skew: CGFloat in [2, -2, 5, -5] {
            rows.append(skewCase("a long line over a short last line 14 pt apart: the value across them on two boxes",
                                 shortLast, skew: skew, Layouts.shortLastLineValue))
        }
        for skew: CGFloat in [5, -5] {
            rows.append(skewCase("one column: the wrapped value on two boxes", Layouts.column, skew: skew, turn: 90,
                                 Layouts.wrappedValue))
        }
        rows += turnedCases("a value over three lines: one occurrence on three boxes", Layouts.threeLines, [Layouts.threeLineValue])
        rows += turnedCases("two columns: a value wrapping inside column 1 on two boxes", Layouts.twoColumns, [Layouts.columnWrapValue])
        rows += turnedCases("two columns: a row across the two columns is not one value", Layouts.twoColumns, [Layouts.rowAcrossColumns])
        rows += turnedCases("an indented first line joins the line under it", Layouts.indentedFirstLine, [Layouts.indentedValue])
        rows += turnedCases("a centred line joins the line over it", Layouts.centredLine, [Layouts.centredValue])
        rows += turnedCases("a short last line joins the line over it", Layouts.shortParagraphEnd, [Layouts.shortEndValue])
        for (name, lines) in [("five one-word lines", Layouts.oneWordLines), ("two lines", Layouts.twoLines)] {
            let (turnedLines, size) = PrintLayout.turned(lines, by: 90)
            rows.append(LineJoinCase(name: "\(name), turned 90: no print direction, so a wrapped value is not joined (a stated limit)",
                                     lines: turnedLines, page: size, searches: [Layouts.shortWrap]))
        }
        rows.append(LineJoinCase(
            name: "six upright lines and a block of three sideways lines: no print direction, the block's wrap is not joined (a stated limit), the body's is",
            lines: Layouts.mixedPage(uprightLines: 6, sidewaysLines: 3), page: PrintLayout.letter,
            searches: [LayoutSearch(query: "Mark Roe", parts: []),
                       LayoutSearch(query: "Jane Doe", parts: [BoxedPart(1, [7]), BoxedPart(2, [0])])]))
        rows.append(LineJoinCase(
            name: "two upright lines and a block of six sideways lines: both wraps joined",
            lines: Layouts.mixedPage(uprightLines: 2, sidewaysLines: 6), page: PrintLayout.letter,
            searches: [LayoutSearch(query: "Jane Doe", parts: [BoxedPart(0, [7]), BoxedPart(1, [0])]),
                       LayoutSearch(query: "Mark Roe", parts: [BoxedPart(2, [5]), BoxedPart(3, [0])])]))
        rows += turnedCases("two columns: the foot of column 1 does not join the head of column 2", Layouts.twoColumns,
                            [Layouts.columnFootIntoHead])
        rows.append(skewCase("6 pt print 7 pt apart, under 3 degrees: only the upright measure applies, the value is not joined (a stated limit)",
                             Layouts.shortLastLine(size: 6, pitch: 7), skew: -2, LayoutSearch(query: "Jane Doe", parts: [])))
        rows += turnedCases("two staggered blocks that do not overlap across the page do not join", Layouts.staggeredBlocks,
                            [LayoutSearch(query: "Mark Roe", parts: [])])
        rows.append(skewCase("a long line over a short last line 12 pt apart: the value across them on two boxes",
                             Layouts.shortLastLine(size: 12, pitch: 12), skew: -3.5, Layouts.shortLastLineValue))
        let (twenty, twentySize) = (Layouts.sidewaysScan(20, header: true, footer: false), CGSize(width: 792, height: 612))
        rows.append(LineJoinCase(name: "a sideways scan with an upright stamp: the wrapped value on two boxes",
                                 lines: twenty, page: twentySize, searches: [Layouts.sidewaysScanValue(header: true)]))
        let repeated = LayoutSearch(query: "Lee Lee", parts: [BoxedPart(0, [8]), BoxedPart(1, [0])])
        for turn in [0, 90] {
            let (turnedLines, size) = PrintLayout.turned(Layouts.repeatedWord, by: turn)
            rows.append(LineJoinCase(
                name: "a search of one word twice across a join: one occurrence across the two lines, the second line's second word in no box (a stated limit), turned \(turn)",
                lines: turnedLines, page: size, searches: [repeated]))
        }
        rows.append(LineJoinCase(name: "a sideways scan with an upright header and page line: the wrapped value on two boxes",
                                 lines: Layouts.sidewaysScan(12, header: true, footer: true), page: twentySize,
                                 searches: [Layouts.sidewaysScanValue(header: true)]))
        rows.append(LineJoinCase(name: "an upright line on a sideways page does not join the sideways line beside it",
                                 lines: Layouts.uprightLineBesideSideways, page: twentySize,
                                 searches: [LayoutSearch(query: "Ann Kim", parts: [])]))
        return rows
    }()

    static let directionCases: [PrintDirectionCase] = {
        let size = CGSize(width: 792, height: 612)
        var rows = [PrintDirectionCase(name: "one column, upright: set, not turned", lines: Layouts.column,
                                       page: PrintLayout.letter, expect: .setNotTurned)]
        for (turn, along) in [(90, CGVector(dx: 0, dy: -1)), (180, CGVector(dx: -1, dy: 0)), (270, CGVector(dx: 0, dy: 1))] {
            let (lines, turnedSize) = PrintLayout.turned(Layouts.column, by: turn)
            rows.append(PrintDirectionCase(name: "one column, turned \(turn)", lines: lines, page: turnedSize, expect: .along(along)))
        }
        rows += [
            PrintDirectionCase(name: "one-word lines: not set", lines: Layouts.oneWordLines, page: PrintLayout.letter, expect: .notSet),
            PrintDirectionCase(name: "two lines of several words: not set", lines: Layouts.twoLines, page: PrintLayout.letter, expect: .notSet),
            PrintDirectionCase(name: "two lines reading right and two reading left: not set", lines: Layouts.opposedLines,
                               page: PrintLayout.letter, expect: .notSet),
            PrintDirectionCase(name: "one column, skew 5: 5 degrees, measured in page points", lines: PrintLayout.skewed(Layouts.column, by: 5),
                               page: PrintLayout.letter, expect: .degrees(5)),
            PrintDirectionCase(name: "twenty sideways lines and one upright: the sideways direction, not a blend",
                               lines: Layouts.sidewaysScan(20, header: true, footer: false), page: size, expect: .along(CGVector(dx: 0, dy: -1))),
            PrintDirectionCase(name: "six upright lines and three sideways: not set", lines: Layouts.mixedPage(uprightLines: 6, sidewaysLines: 3),
                               page: PrintLayout.letter, expect: .notSet),
            PrintDirectionCase(name: "twelve sideways lines and two upright: the sideways direction",
                               lines: Layouts.sidewaysScan(12, header: true, footer: true), page: size, expect: .along(CGVector(dx: 0, dy: -1))),
            PrintDirectionCase(name: "eight sideways lines and three upright: not set", lines: Layouts.mixedPage(uprightLines: 3, sidewaysLines: 8),
                               page: PrintLayout.letter, expect: .notSet),
        ]
        return rows
    }()

    static func blankPage(_ size: CGSize) -> PDFPage {
        let page = PDFPage()
        page.setBounds(CGRect(origin: .zero, size: size), for: .mediaBox)
        page.setBounds(CGRect(origin: .zero, size: size), for: .cropBox)
        return page
    }

    static func matches(_ lines: [OCREngine.TextLine], query: String, page size: CGSize) async -> [SearchResult] {
        var options = SearchOptions()
        options.includeOCR = true
        let page = blankPage(size)
        return await DocumentSearcher().ocrLiteralMatches(lines: lines, query: query, options: options,
                                                          page: page, pageIndex: 0, term: query)
    }

    static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1e-9 && abs(a.minY - b.minY) < 1e-9 && abs(a.width - b.width) < 1e-9 && abs(a.height - b.height) < 1e-9
    }

    @Test("the suite holds 53 join rows and 12 direction rows")
    func rowCounts() {
        #expect(Self.joinCases.count == 53)
        #expect(Self.directionCases.count == 12)
    }

    @Test("a wrapped phrase is joined along the page's print direction, and only there", arguments: joinCases)
    func join(_ row: LineJoinCase) async throws {
        let lines = PrintLayout.recognised(row.lines, page: row.page)
        let reference = Self.blankPage(row.page)
        for search in row.searches {
            let hits = await Self.matches(lines, query: search.query, page: row.page)
            #expect(hits.count == search.parts.count, "\(search.query): \(hits.count) results, \(hits.map(\.matchedText))")
            guard hits.count == search.parts.count, !hits.isEmpty else { continue }
            for (hit, part) in zip(hits, search.parts) {
                let words = part.words.map { lines[part.line].wordBoxes[$0].normalizedRect }
                let union = try #require(words.first.map { first in words.dropFirst().reduce(first) { $0.union($1) } })
                let expected = DocumentSearcher.paddedNormalizedRect(union, in: reference)
                #expect(Self.close(hit.normalizedRect, expected),
                        "\(search.query): line \(part.line) boxed \(hit.normalizedRect), expected \(expected)")
            }
            if hits.count > 1 {
                #expect(hits[0].occurrenceID != nil && hits.allSatisfy { $0.occurrenceID == hits[0].occurrenceID },
                        "\(search.query): the lines of one match share one occurrence")
            } else {
                #expect(hits[0].occurrenceID == nil, "\(search.query): a match inside one line has no occurrence")
            }
        }
    }

    @Test("the page's print direction", arguments: directionCases)
    func direction(_ row: PrintDirectionCase) throws {
        let direction = DocumentSearcher.printDirection(PrintLayout.recognised(row.lines, page: row.page), pageSize: row.page)
        switch row.expect {
        case .notSet:
            #expect(direction == nil, "got \(String(describing: direction))")
        case .setNotTurned:
            let along = try #require(direction)
            #expect(along.dx >= cos(3 * Double.pi / 180), "got \(along)")
        case .along(let expected):
            let along = try #require(direction)
            #expect(abs(along.dx - expected.dx) < 1e-6 && abs(along.dy - expected.dy) < 1e-6, "got \(along)")
        case .degrees(let expected):
            let along = try #require(direction)
            #expect(abs(atan2(along.dy, along.dx) * 180 / .pi - expected) < 0.01, "got \(atan2(along.dy, along.dx) * 180 / .pi)")
        }
    }
}
