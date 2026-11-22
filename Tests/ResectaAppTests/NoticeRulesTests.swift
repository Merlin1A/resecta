import Testing
import Foundation
import CoreGraphics
@testable import ResectaApp

// The notice band's pure rules: when a notice meets a page, how the fold
// answers each event, the reading time, and when the folded mark is drawn.
// Every expectation is the rules' case table, written out, not derived
// from the code under test. Figures in points are the editor's canvas at
// the default text size: a paused notice from y 112 to 176, a Letter page
// at fit from y 189 to 695.

@MainActor
@Suite("Notice band rules")
struct NoticeRulesTests {

    private static func rect(_ minX: CGFloat, _ minY: CGFloat, _ maxX: CGFloat, _ maxY: CGFloat) -> CanvasRect {
        CanvasRect(outward: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))!
    }

    // MARK: - Meeting a page

    @Test("A notice meets a page only when they share an inside point")
    func meetsOnlyInside() {
        let notice = Self.rect(16, 112, 386, 176)
        let rows: [(name: String, notice: CanvasRect, pages: [CanvasRect], meets: Bool)] = [
            ("F-1 a Letter page at fit, below the notice", notice, [Self.rect(0, 189, 402, 695)], false),
            ("F-2 a page whose top is at y 160", notice, [Self.rect(0, 160, 402, 666)], true),
            ("F-5 the notice's foot on the page's top edge", Self.rect(16, 112, 386, 176), [Self.rect(0, 176, 402, 682)], false),
            ("F-6 112.4 to 175.6 against a page from 175.8, rounded outward",
             Self.rect(16, 112.4, 386, 175.6), [Self.rect(0, 175.8, 402, 682)], true),
            ("F-7 two visible pages, only the second under the notice",
             notice, [Self.rect(0, 400, 402, 906), Self.rect(0, -356, 402, 150)], true),
            ("no visible page", notice, [], false),
        ]
        #expect(rows.count == 6)
        for row in rows {
            #expect(NoticeRules.meetsAnyPage(row.notice, pages: row.pages) == row.meets, "\(row.name)")
        }
        // Rounded outward: the measured edges 112.4 and 175.6 become 112 and 176.
        #expect(Self.rect(16, 112.4, 386, 175.6) == CanvasRect(minX: 16, minY: 112, maxX: 386, maxY: 176))
        #expect(Self.rect(0, 175.8, 402, 682) == CanvasRect(minX: 0, minY: 175, maxX: 402, maxY: 682))
    }

    @Test("Around a touching corner, a page meets the notice only when it crosses both edges")
    func touchingCornerTable() {
        // The notice is 0 to 100 on both axes; the page starts at
        // (100 + dx, 100 + dy) and runs to 200. Rows are dy, columns dx,
        // each from -2 to 3.
        let notice = CanvasRect(minX: 0, minY: 0, maxX: 100, maxY: 100)
        let offsets = [-2, -1, 0, 1, 2, 3]
        let expected: [[Bool]] = [
            [true, true, false, false, false, false],     // dy -2
            [true, true, false, false, false, false],     // dy -1
            [false, false, false, false, false, false],   // dy 0
            [false, false, false, false, false, false],   // dy 1
            [false, false, false, false, false, false],   // dy 2
            [false, false, false, false, false, false],   // dy 3
        ]
        var checked = 0
        for (row, dy) in offsets.enumerated() {
            for (column, dx) in offsets.enumerated() {
                let page = CanvasRect(minX: 100 + dx, minY: 100 + dy, maxX: 200, maxY: 200)
                #expect(NoticeRules.meets(notice, page) == expected[row][column], "dx \(dx), dy \(dy)")
                #expect(NoticeRules.meets(page, notice) == expected[row][column], "reversed: dx \(dx), dy \(dy)")
                checked += 1
            }
        }
        #expect(checked == 36)
    }

    @Test("A measured rectangle with no place on the canvas gives no whole-point rectangle")
    func outwardRefusesNonFrames() {
        #expect(CanvasRect(outward: .null) == nil)
        #expect(CanvasRect(outward: .infinite) == nil)
        #expect(CanvasRect(outward: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)) == nil)
        #expect(CanvasRect(outward: CGRect(x: 0, y: 0, width: 2_000_000, height: 10)) == nil)
        #expect(CanvasRect(outward: CGRect(x: -0.5, y: -1.5, width: 1, height: 2))
                == CanvasRect(minX: -1, minY: -2, maxX: 1, maxY: 1))
    }

    // MARK: - The fold

    private struct Step {
        let event: BandEvent
        let meets: Bool
        let after: BandFold
    }

    private struct FoldRow {
        let name: String
        let start: BandFold
        let steps: [Step]

        init(_ name: String, _ start: BandFold, _ steps: [Step]) {
            self.name = name
            self.start = start
            self.steps = steps
        }
    }

    @Test("The band's fold, by event")
    func foldByEvent() {
        let rows: [FoldRow] = [
            FoldRow("F-1 no page under the notice: it stays open", .folded, [
                Step(event: .arrived, meets: false, after: .open(timed: false)),
                Step(event: .readingTimeElapsed, meets: false, after: .open(timed: false)),
            ]),
            FoldRow("F-2 a page under it: open on a clock, then folded", .folded, [
                Step(event: .arrived, meets: true, after: .open(timed: true)),
                Step(event: .readingTimeElapsed, meets: true, after: .folded),
            ]),
            FoldRow("F-3 open over no page; a pinch brings a page under it", .folded, [
                Step(event: .arrived, meets: false, after: .open(timed: false)),
                Step(event: .pageMoved, meets: true, after: .folded),
            ]),
            FoldRow("F-4 folded; a tap opens it untimed; a later scroll folds it", .folded, [
                Step(event: .tapped, meets: true, after: .open(timed: false)),
                Step(event: .readingTimeElapsed, meets: true, after: .open(timed: false)),
                Step(event: .pageMoved, meets: true, after: .folded),
            ]),
            FoldRow("F-8 a zoom still folds a notice the clock does not run for", .folded, [
                Step(event: .arrived, meets: true, after: .open(timed: true)),
                Step(event: .pageMoved, meets: true, after: .folded),
            ]),
            FoldRow("F-10 folded; the band hides and returns: open, then the rule again", .folded, [
                Step(event: .arrived, meets: true, after: .open(timed: true)),
                Step(event: .readingTimeElapsed, meets: true, after: .folded),
            ]),
            FoldRow("a page that moves off the notice leaves it as it was", .open(timed: false), [
                Step(event: .pageMoved, meets: false, after: .open(timed: false)),
                Step(event: .tapped, meets: false, after: .open(timed: false)),
            ]),
            FoldRow("arrived with no frames, then the first frames meet a page: open and timed, not folded", .folded, [
                Step(event: .arrived, meets: false, after: .open(timed: false)),
                Step(event: NoticeRules.frameEvent(firstSinceWanted: true), meets: true, after: .open(timed: true)),
                Step(event: NoticeRules.frameEvent(firstSinceWanted: false), meets: true, after: .folded),
            ]),
        ]
        #expect(rows.count == 8)
        for row in rows {
            var fold = row.start
            for (index, step) in row.steps.enumerated() {
                fold = NoticeRules.next(fold, step.event, meets: step.meets)
                #expect(fold == step.after, "\(row.name), step \(index + 1)")
            }
        }
    }

    @Test("The reading clock runs only for a timed notice, and never while VoiceOver is running")
    func readingClock() {
        let rows: [(fold: BandFold, voiceOver: Bool, runs: Bool)] = [
            (.open(timed: true), false, true),
            (.open(timed: true), true, false),
            (.open(timed: false), false, false),
            (.open(timed: false), true, false),
            (.folded, false, false),
            (.folded, true, false),
        ]
        #expect(rows.count == 6)
        for row in rows {
            #expect(NoticeRules.readingClockRuns(fold: row.fold, voiceOverRunning: row.voiceOver) == row.runs,
                    "\(row.fold), VoiceOver \(row.voiceOver)")
        }
    }

    @Test("The folded mark hides while a drawing tool is on")
    func foldedMarkAndTool() {
        let rows: [(fold: BandFold, toolOn: Bool, shown: Bool)] = [
            (.folded, false, true),
            (.folded, true, false),
            (.open(timed: false), false, false),
            (.open(timed: true), true, false),
        ]
        #expect(rows.count == 4)
        for row in rows {
            #expect(NoticeRules.foldedMarkIsShown(fold: row.fold, toolOn: row.toolOn) == row.shown,
                    "\(row.fold), tool on \(row.toolOn)")
        }
    }

    // MARK: - Reading time

    @Test("Reading time")
    func readingTime() {
        let paused = "Processing was paused. Your drawn regions are preserved."
        #expect(NoticeRules.wordCount(paused) == 8)
        #expect(NoticeRules.wordCount(ImportAnnotationNoticeBanner.noticeMessage) == 41)
        #expect(NoticeRules.wordCount("  one\ttwo\nthree  ") == 3)
        #expect(NoticeRules.wordCount("") == 0)
        let rows: [(name: String, words: Int, hasAction: Bool, seconds: TimeInterval)] = [
            ("one word", 1, false, 2.5),
            ("no words", 0, false, 2.5),
            ("three words, at the floor", 3, false, 2.5),
            ("four words, past the floor", 4, false, 3.0),
            ("the paused notice, with Restart", 8, true, 8.0),
            ("the import notice", 41, false, 21.5),
            ("one word with an action", 1, true, 8.0),
            ("the import notice's words with an action", 41, true, 21.5),
        ]
        #expect(rows.count == 8)
        for row in rows {
            #expect(NoticeRules.readingTime(words: row.words, hasAction: row.hasAction) == row.seconds, "\(row.name)")
        }
    }
}
