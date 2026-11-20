import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import RedactionEngine

// The box check: each box of the record against the stored page picture's
// coded blocks. A page is painted here by the rule's lines, encoded as the
// writer encodes it, walked, and judged; the record is made by hand. The
// twelve cases about reading the picture itself are the page-image reader's
// and live in its own suite; with these they make the check's thirty-five.

@Suite("Each box of the record is judged on the stored picture's blocks")
struct BoxCheckTests {
    typealias F = BoxCheckFixtures
    typealias Lines = PixelPaintRule.Lines

    /// A square page 2 inches on a side: 600, 400 and 300 pixels at 300, 200 and 150.
    static let square = (9216, 9216)
    static let letter = (39168, 50688)

    struct Case: Sendable, CustomTestStringConvertible {
        let number: Int
        let name: String
        var testDescription: String { "\(number): \(name)" }
    }

    static let cases: [Case] = [
        Case(number: 1, name: "a box painted by the rule, black, at 300 dpi"),
        Case(number: 2, name: "the same with a white fill"),
        Case(number: 3, name: "the same at 200 and at 150 dpi"),
        Case(number: 4, name: "boxes on the image's right and bottom edges; a Letter box a sixty-fourth past the page"),
        Case(number: 8, name: "a box reported, and painted, 20 pixels larger on one side"),
        Case(number: 9, name: "a one-line box at 150 dpi on a black-and-white page"),
        Case(number: 10, name: "the same box beside a colour picture"),
        Case(number: 11, name: "a page exported at 150 dpi when 300 was chosen"),
        Case(number: 13, name: "boxes over print, none painted"),
        Case(number: 14, name: "every painted rectangle one block from its box"),
        Case(number: 15, name: "a white fill recorded, black painted"),
        Case(number: 16, name: "a box painted at level 1, not 0"),
        Case(number: 17, name: "a report smaller than the paint over a block not the fill; the same with no report"),
        Case(number: 18, name: "a tinted fill"),
        Case(number: 19, name: "a box in the record that was never painted"),
        Case(number: 27, name: "the record's sides from another page, so the frame fits no quality"),
        Case(number: 29, name: "a box that maps to no pixel, and one off the page"),
        Case(number: 30, name: "10,001 boxes on a page"),
        Case(number: 31, name: "a box widened across a 468 pt line at 300 dpi"),
        Case(number: 32, name: "a page half a point square with a 2 by 2 frame, 300 chosen"),
        Case(number: 33, name: "a report smaller with every block the fill; a report past the image; no report"),
        Case(number: 34, name: "a Letter record with a 2,550 by 3,300 frame, and with 3,301 rows"),
        Case(number: 35, name: "a Letter box in the top block row, its report read with rows from the bottom"),
    ]

    @Test("The table holds the check's 23 cases; with the page-image reader's 12 they make 35")
    func tableLength() {
        #expect(Self.cases.count == 23)
        #expect(Self.cases.count + PageImageReadTests.cases.count == 35)
        #expect(Set(Self.cases.map(\.number)).count == 23)
    }

    @Test("The check's planted failures are ten, each a patch in the repository's Mutants folder")
    func plantedFailures() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../../Mutants").standardized
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("box-check-") && $0.hasSuffix(".patch") }
        #expect(names.count == 10, "\(names.sorted())")
    }

    // MARK: - helpers

    /// A box at these pixel lines on an H-row frame at quality d, and the rule's paint for it.
    static func boxAt(_ l: Lines, dpi d: Int, width w: Int, height h: Int) -> (PaintedBox, Lines) {
        let b = F.box(F.inner(left: l.left, top: l.top, right: l.right, bottom: l.bottom, dpi: d, height: h))
        return (b, F.paint(b, dpi: d, width: w, height: h))
    }

    static func counts(_ o: BoxOutcome) -> BoxCounts? {
        switch o {
        case .completed(let c, _), .issue(let c, _): c
        case .inconclusive(_, let c), .couldNotFinish(_, let c): c
        case .offPage: nil
        }
    }

    static func isWhole(_ o: BoxOutcome, note: BoxReportNote = .none) -> Bool {
        guard case .completed(let c, let n) = o, n == note else { return false }
        return c.unitExpected > 0 && c.unitExpected == c.unitExamined && c.unitExamined == c.unitExact
            && c.furtherExamined == c.furtherExact && c.colourInside == c.colourInsideNeutral
    }

    static func isIssue(_ o: BoxOutcome) -> Bool { if case .issue = o { true } else { false } }

    // MARK: - the table

    @Test("Each case", arguments: BoxCheckTests.cases)
    func each(_ c: Case) throws {
        switch c.number {
        case 1, 2:
            let fill: FillColor = c.number == 1 ? .black : .white
            let (b, p) = Self.boxAt(Lines(left: 100, top: 100, right: 220, bottom: 140), dpi: 300, width: 600, height: 600)
            let (walk, _) = F.walk(F.picture(width: 600, height: 600, print: true, marks: [F.Mark(lines: p, gray: fill == .black ? 0 : 1)]))
            let o = F.judge(b, report: F.report(p, height: 600), on: walk, dpi: 300, sides: Self.square, fill: fill)
            #expect(Self.isWhole(o), "\(o)")
        case 3:
            let (b300, _) = Self.boxAt(Lines(left: 100, top: 100, right: 220, bottom: 140), dpi: 300, width: 600, height: 600)
            for (d, side) in [(200, 400), (150, 300)] {
                let p = F.paint(b300, dpi: d, width: side, height: side)
                let (walk, _) = F.walk(F.picture(width: side, height: side, print: true, marks: [F.Mark(lines: p)]))
                let o = F.judge(b300, report: F.report(p, height: side), on: walk, dpi: d, sides: Self.square)
                #expect(Self.isWhole(o), "\(d) dpi: \(o)")
            }
        case 4:
            // A 601-pixel frame: its last block column and row are cut by the image's edge.
            let s = 9230
            #expect(PixelPaintRule.frameSide(s, dpi: 300) == 601)
            let right = F.box(F.r(8000, 4000, s, 5000)), bottom = F.box(F.r(3000, 0, 4500, 600))
            let pr = F.paint(right, dpi: 300, width: 601, height: 601), pb = F.paint(bottom, dpi: 300, width: 601, height: 601)
            #expect(pr.right == 601 && pb.bottom == 601)
            let (walk, _) = F.walk(F.picture(width: 601, height: 601, print: true, marks: [F.Mark(lines: pr), F.Mark(lines: pb)]))
            for (b, p) in [(right, pr), (bottom, pb)] {
                let o = F.judge(b, report: F.report(p, height: 601), on: walk, dpi: 300, sides: (s, s))
                #expect(Self.isWhole(o), "\(o)")
            }
            // On a Letter page: a box ending a sixty-fourth past the page is clipped, and counts as the box ending at the page.
            let past = F.box(F.r(30000, 49000, 39169, 50689)), at = F.box(F.r(30000, 49000, 39168, 50688))
            let p = F.paint(past, dpi: 300, width: 2550, height: 3300)
            #expect(p == F.paint(at, dpi: 300, width: 2550, height: 3300))
            let (lw, _) = F.walk(F.picture(width: 2550, height: 3300, print: true, marks: [F.Mark(lines: p)]))
            let a = F.judge(past, report: F.report(p, height: 3300), on: lw, dpi: 300, sides: Self.letter)
            let z = F.judge(at, report: F.report(p, height: 3300), on: lw, dpi: 300, sides: Self.letter)
            #expect(Self.isWhole(a) && a == z, "\(a) against \(z)")
        case 8:
            let (b, p) = Self.boxAt(Lines(left: 100, top: 100, right: 220, bottom: 140), dpi: 300, width: 600, height: 600)
            var larger = p
            larger.right += 20
            let (walk, _) = F.walk(F.picture(width: 600, height: 600, print: true, marks: [F.Mark(lines: larger)]))
            let o = F.judge(b, report: F.report(larger, height: 600), on: walk, dpi: 300, sides: Self.square)
            #expect(Self.isWhole(o, note: .reportedLarger), "\(o)")
            #expect((Self.counts(o)?.furtherExamined ?? 0) >= 10, "the whole blocks of the strip are judged: \(o)")
        case 9, 10:
            let (b, p) = Self.boxAt(Lines(left: 60, top: 100, right: 180, bottom: 110), dpi: 150, width: 300, height: 300)
            let patch = c.number == 10 ? Lines(left: p.right, top: p.top - 4, right: p.right + 30, bottom: p.bottom + 4) : nil
            let (walk, _) = F.walk(F.picture(width: 300, height: 300, colourPatch: patch, marks: [F.Mark(lines: p)]))
            let o = F.judge(b, report: F.report(p, height: 300), on: walk, dpi: 150, sides: Self.square)
            #expect(Self.isWhole(o), "\(o)")
            let notJudged = Self.counts(o)?.colourEdgeNotJudged ?? -1
            #expect(c.number == 9 ? notJudged == 0 : notJudged > 0, "edge colour blocks not judged: \(notJudged)")
        case 11:
            let (b, p) = Self.boxAt(Lines(left: 50, top: 50, right: 110, bottom: 70), dpi: 150, width: 300, height: 300)
            let (walk, _) = F.walk(F.picture(width: 300, height: 300, marks: [F.Mark(lines: p)]))
            let page = BoxCheckInput.Page(widthSixtyFourths: 9216, heightSixtyFourths: 9216, boxes: [b], reported: [0: F.report(p, height: 300)])
            let r = ExactFillCheck.judge(page: page, picture: .completed(walk), fill: .black, chosenDPI: 300)
            #expect(r.quality == 150 && r.belowChosen)
            #expect(Self.isWhole(r.boxes[0]), "\(r.boxes[0])")
        case 13, 14, 15, 16:
            let (b, p) = Self.boxAt(Lines(left: 100, top: 100, right: 220, bottom: 140), dpi: 300, width: 600, height: 600)
            var marks: [F.Mark] = []
            switch c.number {
            case 14: marks = [F.Mark(lines: Lines(left: p.left, top: p.top + 8, right: p.right, bottom: p.bottom + 8))]
            case 15: marks = [F.Mark(lines: p)]
            case 16: marks = [F.Mark(lines: p, gray: 1.0 / 255)]
            default: break
            }
            let (walk, _) = F.walk(F.picture(width: 600, height: 600, print: true, marks: marks))
            let o = F.judge(b, report: F.report(p, height: 600), on: walk, dpi: 300, sides: Self.square,
                            fill: c.number == 15 ? .white : .black)
            #expect(Self.isIssue(o), "\(o)")
        case 17:
            let (b, p) = Self.boxAt(Lines(left: 96, top: 96, right: 224, bottom: 144), dpi: 300, width: 600, height: 600)
            var part = p
            part.right -= 24
            let (walk, _) = F.walk(F.picture(width: 600, height: 600, print: true, marks: [F.Mark(lines: part)]))
            let smaller = F.judge(b, report: F.report(part, height: 600), on: walk, dpi: 300, sides: Self.square)
            let none = F.judge(b, report: nil, on: walk, dpi: 300, sides: Self.square)
            #expect(Self.isIssue(smaller) && Self.isIssue(none), "\(smaller) · \(none)")
            // The unit is worked out from the box alone: the smaller report leaves it as it is.
            #expect(Self.counts(smaller)?.unitExpected == Self.counts(none)?.unitExpected,
                    "\(String(describing: Self.counts(smaller))) against \(String(describing: Self.counts(none)))")
        case 18:
            let (b, p) = Self.boxAt(Lines(left: 96, top: 96, right: 224, bottom: 160), dpi: 300, width: 600, height: 600)
            let (walk, _) = F.walk(F.picture(width: 600, height: 600, marks: [F.Mark(lines: p, rgb: (0, 0, 0.03))]))
            let o = F.judge(b, report: F.report(p, height: 600), on: walk, dpi: 300, sides: Self.square)
            guard case .issue(_, let blocks) = o else { Issue.record("an issue expected: \(o)"); return }
            #expect(blocks.contains { $0.component > 0 }, "a colour block wholly inside is not neutral: \(blocks.prefix(4))")
        case 19:
            let (painted, p) = Self.boxAt(Lines(left: 100, top: 100, right: 220, bottom: 140), dpi: 300, width: 600, height: 600)
            let (never, q) = Self.boxAt(Lines(left: 300, top: 300, right: 420, bottom: 340), dpi: 300, width: 600, height: 600)
            let (walk, _) = F.walk(F.picture(width: 600, height: 600, print: true, marks: [F.Mark(lines: p)]))
            #expect(Self.isWhole(F.judge(painted, report: F.report(p, height: 600), on: walk, dpi: 300, sides: Self.square)))
            #expect(Self.isIssue(F.judge(never, report: F.report(q, height: 600), on: walk, dpi: 300, sides: Self.square)))
        case 27:
            let (b, p) = Self.boxAt(Lines(left: 100, top: 100, right: 220, bottom: 140), dpi: 300, width: 600, height: 600)
            let (walk, _) = F.walk(F.picture(width: 600, height: 600, marks: [F.Mark(lines: p)]))
            let page = BoxCheckInput.Page(widthSixtyFourths: Self.letter.0, heightSixtyFourths: Self.letter.1, boxes: [b, b], reported: [:])
            let r = ExactFillCheck.judge(page: page, picture: .completed(walk), fill: .black, chosenDPI: 300)
            #expect(r.quality == nil)
            #expect(r.boxes.allSatisfy { $0 == .inconclusive(ExactFillCheck.frameFitsNoQuality, nil) }, "\(r.boxes)")
        case 29:
            let (walk, _) = F.walk(F.picture(width: 600, height: 600, marks: []))
            // 1,536 sixty-fourths is exactly pixel 100 at 300 dpi: a box of no width maps to no pixel.
            let thin = F.box(F.r(1536, 2000, 1536, 3000)), off = F.box(F.r(9300, 2000, 9800, 3000))
            #expect(F.judge(thin, report: nil, on: walk, dpi: 300, sides: Self.square) == .inconclusive(ExactFillCheck.mapsToNoPixel, nil))
            #expect(F.judge(off, report: nil, on: walk, dpi: 300, sides: Self.square) == .offPage)
        case 30:
            let (walk, _) = F.walk(F.picture(width: 300, height: 300, marks: []))
            let b = F.box(F.r(1000, 1000, 2000, 2000))
            let page = BoxCheckInput.Page(widthSixtyFourths: 9216, heightSixtyFourths: 9216,
                                          boxes: Array(repeating: b, count: ExactFillCheck.boxLimit + 1), reported: [:])
            let r = ExactFillCheck.judge(page: page, picture: .completed(walk), fill: .black, chosenDPI: 150)
            #expect(r.boxes.count == 10_001)
            #expect(r.boxes.allSatisfy { $0 == .inconclusive(ExactFillCheck.tooManyBoxes, nil) })
        case 31:
            let b = F.box(F.r(4608, 40000, 4608 + 468 * 64, 40800))
            let p = F.paint(b, dpi: 300, width: 2550, height: 3300)
            let (walk, _) = F.walk(F.picture(width: 2550, height: 3300, print: true, marks: [F.Mark(lines: p)]))
            let o = F.judge(b, report: F.report(p, height: 3300), on: walk, dpi: 300, sides: Self.letter)
            #expect(Self.isWhole(o), "\(o)")
            let expected = Self.counts(o)?.unitExpected ?? 0
            print("BOXCHECK case 31: \(expected) unit blocks expected, examined and exact")
            #expect(expected > 1_500 && expected < 2_600, "about 2,000 blocks: \(expected)")
        case 32:
            #expect(PixelPaintRule.pageQuality(widthSixtyFourths: 32, heightSixtyFourths: 32, frameWidth: 2, frameHeight: 2, chosen: 300) == 150)
            let b = F.box(F.r(0, 0, 32, 32))
            let p = F.paint(b, dpi: 150, width: 2, height: 2)
            let (walk, _) = F.walk(F.picture(width: 2, height: 2, marks: [F.Mark(lines: p)]))
            let page = BoxCheckInput.Page(widthSixtyFourths: 32, heightSixtyFourths: 32, boxes: [b], reported: [0: F.report(p, height: 2)])
            let r = ExactFillCheck.judge(page: page, picture: .completed(walk), fill: .black, chosenDPI: 300)
            #expect(r.quality == 150)
            #expect(Self.isWhole(r.boxes[0]), "\(r.boxes[0])")
        case 33:
            let (b, p) = Self.boxAt(Lines(left: 96, top: 96, right: 224, bottom: 144), dpi: 300, width: 600, height: 600)
            let (walk, _) = F.walk(F.picture(width: 600, height: 600, marks: []))
            var part = p
            part.right -= 24
            var past = p
            past.right = 640
            let rule = ExactFillCheck.reportDoesNotHoldThePaint
            let smaller = F.judge(b, report: F.report(part, height: 600), on: walk, dpi: 300, sides: Self.square, fill: .white)
            let outside = F.judge(b, report: F.report(past, height: 600), on: walk, dpi: 300, sides: Self.square, fill: .white)
            let none = F.judge(b, report: nil, on: walk, dpi: 300, sides: Self.square, fill: .white)
            #expect(smaller.kind == .inconclusive(rule) && outside.kind == .inconclusive(rule), "\(smaller) · \(outside)")
            #expect(none.kind == .inconclusive(ExactFillCheck.noReport), "\(none)")
        case 34:
            #expect(PixelPaintRule.pageQuality(widthSixtyFourths: 39168, heightSixtyFourths: 50688, frameWidth: 2550, frameHeight: 3300, chosen: 300) == 300)
            #expect(PixelPaintRule.pageQuality(widthSixtyFourths: 39168, heightSixtyFourths: 50688, frameWidth: 2550, frameHeight: 3301, chosen: 300) == nil)
            let b = F.box(F.r(4608, 40000, 9216, 40800))
            let (walk, _) = F.walk(F.picture(width: 2550, height: 3301, marks: []))
            let page = BoxCheckInput.Page(widthSixtyFourths: 39168, heightSixtyFourths: 50688, boxes: [b], reported: [:])
            let r = ExactFillCheck.judge(page: page, picture: .completed(walk), fill: .black, chosenDPI: 300)
            #expect(r.boxes == [.inconclusive(ExactFillCheck.frameFitsNoQuality, nil)])
        case 35:
            let b = F.box(F.r(6144, 50600, 9216, 50688))
            let p = F.paint(b, dpi: 300, width: 2550, height: 3300)
            #expect(p == Lines(left: 399, top: 0, right: 601, bottom: 8), "the rule's paint: \(p)")
            let report1 = RunRecord.PaintedPixels(firstColumn: 399, firstRowFromBottom: 3292, columns: 202, rows: 8)
            let report2 = RunRecord.PaintedPixels(firstColumn: 399, firstRowFromBottom: 3276, columns: 202, rows: 24)
            let down = Lines(left: 399, top: 0, right: 601, bottom: 24)
            let (w1, _) = F.walk(F.picture(width: 2550, height: 3300, print: true, marks: [F.Mark(lines: p)]))
            let one = F.judge(b, report: report1, on: w1, dpi: 300, sides: Self.letter)
            #expect(Self.isWhole(one) && Self.counts(one)?.unitExpected == 25, "(i) \(one)")
            let (w2, _) = F.walk(F.picture(width: 2550, height: 3300, print: true, marks: [F.Mark(lines: down)]))
            let two = F.judge(b, report: report2, on: w2, dpi: 300, sides: Self.letter)
            #expect(Self.isWhole(two, note: .reportedLarger) && Self.counts(two)?.furtherExamined == 50, "(ii) \(two)")
            let grey = Lines(left: 480, top: 16, right: 488, bottom: 24)
            let (w3, _) = F.walk(F.picture(width: 2550, height: 3300, print: true, marks: [F.Mark(lines: down), F.Mark(lines: grey, gray: 128.0 / 255)]))
            let three = F.judge(b, report: report2, on: w3, dpi: 300, sides: Self.letter)
            guard case .issue(_, let blocks) = three else { Issue.record("(iii) an issue expected: \(three)"); return }
            #expect(blocks == [BoxWrongBlock(component: 0, column: 60, row: 2)], "(iii) the grey block: \(blocks)")
        default:
            Issue.record("case \(c.number) has no body")
        }
    }
}
