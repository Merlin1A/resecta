import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import RedactionEngine

// The box check beyond its table: every grid position, agreement with the
// system's decoder, a block whose DC is the fill's but is not flat, the
// outcome rows as data, the entry point over an export, and the two seams
// that wait on other work.

@Suite("The box check's rule, its decoder agreement and its entry point")
struct BoxCheckRuleTests {
    typealias F = BoxCheckFixtures
    typealias Lines = PixelPaintRule.Lines

    @Test("Every grid position: 64 top-left offsets, both fills, three qualities, 384 boxes complete")
    func everyGridPosition() {
        var judged = 0
        for fill in [FillColor.black, .white] {
            for (d, side) in [(300, 600), (200, 400), (150, 300)] {
                var boxes: [(PaintedBox, Lines)] = []
                for j in 0..<8 {
                    for i in 0..<8 {
                        let left = 8 + 36 * i + i, top = 8 + 36 * j + j
                        let b = F.box(F.inner(left: left, top: top, right: left + 12, bottom: top + 12, dpi: d, height: side))
                        let u = PixelPaintRule.outward(b.inner, dpi: d, imageHeight: side)
                        #expect(u.left == left && u.top == top, "offset (\(i), \(j)) at \(d) dpi: \(u)")
                        boxes.append((b, F.paint(b, dpi: d, width: side, height: side)))
                    }
                }
                let picture = F.picture(width: side, height: side, marks: [F.Mark(lines: Lines(left: 0, top: 0, right: side, bottom: side), gray: 0.5)]
                                        + boxes.map { F.Mark(lines: $0.1, gray: fill == .black ? 0 : 1) })
                let (walk, _) = F.walk(picture)
                for (b, p) in boxes {
                    let o = F.judge(b, report: F.report(p, height: side), on: walk, dpi: d, sides: (9216, 9216), fill: fill)
                    #expect(BoxCheckTests.isWhole(o), "\(fill) at \(d) dpi: \(o)")
                    judged += 1
                }
            }
        }
        #expect(judged == 384)
    }

    @Test("A block the walk calls the fill, with its eight neighbours the fill, decodes to exactly the fill")
    func systemDecoderAgrees() throws {
        let (b, p) = BoxCheckTests.boxAt(Lines(left: 96, top: 96, right: 256, bottom: 176), dpi: 300, width: 600, height: 600)
        _ = b
        let (walk, jpeg) = F.walk(F.picture(width: 600, height: 600, print: true, marks: [F.Mark(lines: p)]))
        let src = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let ctx = try #require(CGContext(data: nil, width: 600, height: 600, bitsPerComponent: 8, bytesPerRow: 600 * 4,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 600, height: 600))
        let px = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
        let wide = walk.blocksWide[0]
        func fill(_ bx: Int, _ by: Int) -> Bool {
            bx >= 0 && by >= 0 && bx < 75 && by < 75 && ExactFillCheck.isExactFill(walk.blocks[0][by * wide + bx], .black)
        }
        var checked = 0
        for by in 0..<75 {
            for bx in 0..<75 where (-1...1).allSatisfy({ dy in (-1...1).allSatisfy { dx in fill(bx + dx, by + dy) } }) {
                for y in (by * 8)..<(by * 8 + 8) {
                    for x in (bx * 8)..<(bx * 8 + 8) {
                        let o = (y * 600 + x) * 4
                        #expect(px[o] == 0 && px[o + 1] == 0 && px[o + 2] == 0, "pixel (\(x), \(y)) of block (\(bx), \(by))")
                    }
                }
                checked += 1
            }
        }
        print("BOXCHECK decoder agreement: \(checked) blocks with every neighbour the fill, each decoded to exactly the fill")
        #expect(checked > 0)
    }

    @Test("A black box with one pixel at level 16: the block's DC is within the fill's bound and it is not flat, so it is an issue")
    func oneBrightPixel() {
        let (b, p) = BoxCheckTests.boxAt(Lines(left: 96, top: 96, right: 224, bottom: 144), dpi: 300, width: 600, height: 600)
        let dot = Lines(left: 132, top: 116, right: 133, bottom: 117)
        let (walk, _) = F.walk(F.picture(width: 600, height: 600, gray: true, marks: [F.Mark(lines: p), F.Mark(lines: dot, gray: 16.0 / 255)]))
        let block = walk.blocks[0][(116 / 8) * walk.blocksWide[0] + 132 / 8]
        #expect(block.dcTimesStep <= -1021, "the DC alone reads as the fill: \(block.dcTimesStep)")
        #expect(!block.flat, "an AC coefficient is not zero")
        let o = F.judge(b, report: F.report(p, height: 600), on: walk, dpi: 300, sides: (9216, 9216))
        #expect(BoxCheckTests.isIssue(o), "\(o)")
    }

    @Test("The seven outcome rows as data, against the names the verdict reads")
    func outcomeRows() {
        let rows: [(BoxOutcome, OutcomeKind, RowClass)] = [
            (.completed(BoxCounts(), .reportedLarger), .completed, .passed),
            (.issue(BoxCounts(), []), .issue, .needsReview),
            (.inconclusive(ExactFillCheck.frameFitsNoQuality, nil), .inconclusive(ExactFillCheck.frameFitsNoQuality), .couldNotVerify),
            (.inconclusive(ExactFillCheck.mapsToNoPixel, nil), .inconclusive(ExactFillCheck.mapsToNoPixel), .couldNotVerify),
            (.inconclusive(ExactFillCheck.reportDoesNotHoldThePaint, nil), .inconclusive(ExactFillCheck.reportDoesNotHoldThePaint), .couldNotVerify),
            (.couldNotFinish(.evidenceShort, nil), .fault(.evidenceShort), .couldNotVerify),
            (.inconclusive(ExactFillCheck.noReport, nil), .inconclusive(ExactFillCheck.noReport), .couldNotVerify),
        ]
        #expect(rows.count == 7)
        for (outcome, kind, row) in rows {
            #expect(outcome.kind == kind)
            #expect(kind.rowClass == row, "\(outcome)")
        }
    }

    @Test("The entry point over an export: the page's picture located by its digest and the box judged; no record is one answer")
    func entryPoint() async throws {
        let (b, p) = BoxCheckTests.boxAt(Lines(left: 100, top: 100, right: 220, bottom: 140), dpi: 300, width: 600, height: 600)
        let (_, jpeg) = F.walk(F.picture(width: 600, height: 600, print: true, marks: [F.Mark(lines: p)]))
        let file = try await PageImageFixtures.export([jpeg], size: CGSize(width: 144, height: 144))
        let source = try #require(SystemPageImageSource(fileData: file))
        let input = BoxCheckInput(fill: .black, chosenDPI: 300,
                                  pages: [.init(widthSixtyFourths: 9216, heightSixtyFourths: 9216, boxes: [b], reported: [0: F.report(p, height: 600)])],
                                  pageImageDigests: [PageImageFixtures.sha256(jpeg)])
        let report = try ExactFillCheck.run(fileData: file, source: source, input: input)
        let kinds = report.outcomes.map(\.kind)
        #expect(kinds == [.completed, .completed], "\(report.outcomes)")
        let none = try ExactFillCheck.run(fileData: file, source: source, input: nil)
        #expect(none.outcomes.count == 1 && none.outcomes[0].unit == .document && none.outcomes[0].kind == .fault(.noRecord))
    }

    @Test("A record whose page has no plan gives the check no input; it never works out a page's size itself")
    func recordWithoutAPlan() {
        let record = RunRecord(confirmed: .init(fillColor: .black, exportDPI: 300, pages: [.init(pageIndex: 0, regions: [])]),
                               produced: .init())
        #expect(BoxCheckInput(record: record) == nil)
        let planned = RunRecord(confirmed: .init(fillColor: .white, exportDPI: 200, pages: [
            .init(pageIndex: 0, regions: [], plan: PaintPlan(widthSixtyFourths: 9216, heightSixtyFourths: 9216, boxes: [F.box(F.r(0, 0, 64, 64))])),
        ]), produced: .init(pageImageDigests: [0: Data([1])], paintedRectangles: [.init(pageIndex: 0, box: 0): .init(firstColumn: 0, firstRowFromBottom: 0, columns: 1, rows: 1)], infoDictionary: nil))
        let input = BoxCheckInput(record: planned)
        #expect(input?.fill == .white && input?.chosenDPI == 200 && input?.pages.first?.boxes.count == 1)
        #expect(input?.pages.first?.reported[0] == .init(firstColumn: 0, firstRowFromBottom: 0, columns: 1, rows: 1))
        #expect(input?.pageImageDigests == [Data([1])])
    }

    @Test("Seam: the checks are handed the run's record, with each page's plan and the producer's rectangles",
          .disabled("waits on the pixel step, which paints by the plan and writes each box's painted rectangle; the record reaches the checks with each page's plan today, and with no painted rectangle"))
    func seamTheRecordReachesTheCheck() {
        Issue.record("the record does not yet hold the rectangles the producer painted")
    }

    @Test("Seam: one real export in each mode through the app's pipeline, every box complete and none reported smaller",
          .disabled("waits on the pixel step's merge, which paints by the plan and writes the reported rectangles; no export is faked meanwhile"))
    func seamRealExportEachMode() {
        Issue.record("no real export with a plan and reported rectangles exists yet")
    }
}
