import CryptoKit
import Foundation

/// What the box check is given: the record's fill and chosen quality, and for
/// each page its two sides in sixty-fourths, its boxes and the rectangles the
/// producer reports having painted for them. Read from the record only.
struct BoxCheckInput: Sendable {
    struct Page: Sendable {
        let widthSixtyFourths: Int
        let heightSixtyFourths: Int
        let boxes: [PaintedBox]
        /// The producer's rectangle for a box, by its place in the page's plan.
        let reported: [Int: RunRecord.PaintedPixels]
    }

    let fill: FillColor
    let chosenDPI: Int
    let pages: [Page]
    /// Each page's image digest as it was handed to the writer, in page order.
    let pageImageDigests: [Data]
}

extension BoxCheckInput {
    /// The input as the record holds it. Nil when a page has no plan: the
    /// record then holds neither that page's sides nor its boxes, and the
    /// check is not given a size it would have to work out itself.
    init?(record: RunRecord) {
        var pages: [Page] = []
        for page in record.confirmed.pages {
            guard let plan = page.plan else { return nil }
            var reported: [Int: RunRecord.PaintedPixels] = [:]
            for (position, pixels) in record.produced.paintedRectangles where position.pageIndex == page.pageIndex {
                reported[position.box] = pixels
            }
            pages.append(Page(widthSixtyFourths: plan.widthSixtyFourths, heightSixtyFourths: plan.heightSixtyFourths,
                              boxes: plan.boxes, reported: reported))
        }
        var digests: [Data] = []
        while let d = record.produced.pageImageDigests[digests.count] { digests.append(d) }
        self.init(fill: record.confirmed.fillColor, chosenDPI: record.confirmed.exportDPI, pages: pages,
                  pageImageDigests: digests)
    }
}

/// How the producer's report stands against the rule's paint.
enum BoxReportNote: Equatable, Sendable {
    /// The report is the rule's paint.
    case none
    /// The report holds the rule's paint and more: the larger area is judged.
    case reportedLarger
    /// The report does not hold the rule's paint (or spans no pixel, or leaves the image).
    case reportedSmaller
    /// The record holds no report for the box.
    case notReported
}

/// The counts behind one box's answer.
struct BoxCounts: Equatable, Sendable {
    var unitExpected = 0
    var unitExamined = 0
    var unitExact = 0
    var furtherExamined = 0
    var furtherExact = 0
    var colourInside = 0
    var colourInsideNeutral = 0
    var colourEdgeNeutral = 0
    var colourEdgeNotJudged = 0
    /// Pixel columns or rows of the painted area, on each side, in no block wholly inside it (0 to 7).
    var unconfirmedLeft = 0
    var unconfirmedTop = 0
    var unconfirmedRight = 0
    var unconfirmedBottom = 0
}

/// A block that is not what the paint makes it: its component and its place
/// in the component's block grid, from the top-left.
struct BoxWrongBlock: Equatable, Sendable {
    let component: Int
    let column: Int
    let row: Int
}

/// One box's answer.
enum BoxOutcome: Equatable, Sendable {
    case completed(BoxCounts, BoxReportNote)
    /// `inner` lies wholly outside its page: listed, not judged, not a failure.
    case offPage
    case issue(BoxCounts, [BoxWrongBlock])
    case inconclusive(CheckRule, BoxCounts?)
    case couldNotFinish(FaultName, BoxCounts?)

    var kind: OutcomeKind {
        switch self {
        case .completed, .offPage: .completed
        case .issue: .issue
        case .inconclusive(let rule, _): .inconclusive(rule)
        case .couldNotFinish(let fault, _): .fault(fault)
        }
    }
}

/// One page's answer: how its picture was read, the quality found for it,
/// and each box of its plan in order.
struct BoxCheckPage: Equatable, Sendable {
    let picture: OutcomeKind
    let quality: Int?
    /// Exported below the quality the user chose.
    let belowChosen: Bool
    /// A one-component picture: no colour to judge.
    let noColour: Bool
    let boxes: [BoxOutcome]
}

enum BoxCheckReport: Equatable, Sendable {
    case pages([BoxCheckPage])
    case noRecord

    /// Every unit the check was given and how it ended on it: each page's
    /// picture, then each box of that page's plan.
    var outcomes: [(unit: CheckUnit, kind: OutcomeKind)] {
        switch self {
        case .noRecord:
            return [(.document, .fault(.noRecord))]
        case .pages(let pages):
            var out: [(unit: CheckUnit, kind: OutcomeKind)] = []
            for (i, page) in pages.enumerated() {
                out.append((.page(i), page.picture))
                for (j, box) in page.boxes.enumerated() { out.append((.box(page: i, planIndex: j), box.kind)) }
            }
            return out
        }
    }
}

/// The check that each box of the record is painted as the rule says, read
/// from the stored page picture's coded blocks without decoding a pixel.
enum ExactFillCheck {
    /// The most boxes a page may hold.
    static let boxLimit = 10_000
    /// A block cut by the image's right or bottom edge is judged by its part
    /// on the image, like any other. A runtime that pads edge blocks
    /// differently would turn this off for a release; never remove it.
    static let edgeBlocksJudgedByTheirPartOnTheImage = true

    static let frameFitsNoQuality = CheckRule("the frame fits no quality of its page")
    static let mapsToNoPixel = CheckRule("the box maps to no pixel and is not off its page")
    static let reportDoesNotHoldThePaint = CheckRule("the reported rectangle does not contain the rule's paint")
    static let noReport = CheckRule("the record holds no reported rectangle for the box")
    static let tooManyBoxes = CheckRule("more boxes on the page than the check reads")

    /// A brightness block that is exactly the fill: flat, and its DC value
    /// times its step at most −1021 (black) or at least 1013 (white), the
    /// values that decode to 0 or 255 at every sample whichever way a half rounds.
    static func isExactFill(_ b: CodedBlock, _ fill: FillColor) -> Bool {
        guard b.flat else { return false }
        switch fill {
        case .black: return b.dcTimesStep <= -1021
        case .white: return b.dcTimesStep >= 1013
        }
    }

    /// A colour block that carries no colour: flat, its DC value times its step within ±3.
    static func isNeutral(_ b: CodedBlock) -> Bool { b.flat && abs(b.dcTimesStep) <= 3 }

    /// The check over a file: every page's picture read by the page-image
    /// reader, then every box of that page judged. Throws only cancellation.
    static func run(fileData: Data, source: some PageImageSource, input: BoxCheckInput?) throws(CancellationError) -> BoxCheckReport {
        guard let input else { return .noRecord }
        var pages: [BoxCheckPage] = []
        try PageImageLocator.readEach(fileData: fileData, source: source, recordedHashes: input.pageImageDigests) { index, outcome in
            let page = index < input.pages.count ? input.pages[index] : nil
            pages.append(judge(page: page, picture: outcome, fill: input.fill, chosenDPI: input.chosenDPI))
        }
        return .pages(pages)
    }

    /// One page: its picture's outcome, its quality, and each box.
    static func judge(page: BoxCheckInput.Page?, picture: PageImageOutcome, fill: FillColor, chosenDPI: Int) -> BoxCheckPage {
        let boxes = page?.boxes ?? []
        guard case .completed(let walk) = picture else {
            let fault: FaultName
            if case .couldNotFinish(let refusal) = picture { fault = refusal.reason.fault } else { fault = .unreadableInput }
            return BoxCheckPage(picture: picture.kind, quality: nil, belowChosen: false, noColour: false,
                                boxes: boxes.map { _ in .couldNotFinish(fault, nil) })
        }
        guard let page else {
            return BoxCheckPage(picture: .completed, quality: nil, belowChosen: false, noColour: !walk.hasColour, boxes: [])
        }
        let quality = PixelPaintRule.pageQuality(widthSixtyFourths: page.widthSixtyFourths, heightSixtyFourths: page.heightSixtyFourths,
                                                 frameWidth: walk.width, frameHeight: walk.height, chosen: chosenDPI)
        let judged: [BoxOutcome]
        if boxes.count > boxLimit {
            judged = boxes.map { _ in .inconclusive(tooManyBoxes, nil) }
        } else if let quality {
            judged = boxes.enumerated().map { j, box in
                judge(box: box, reported: page.reported[j], walk: walk, dpi: quality,
                      widthSixtyFourths: page.widthSixtyFourths, heightSixtyFourths: page.heightSixtyFourths, fill: fill)
            }
        } else {
            judged = boxes.map { _ in .inconclusive(frameFitsNoQuality, nil) }
        }
        return BoxCheckPage(picture: .completed, quality: quality, belowChosen: quality.map { $0 < chosenDPI } ?? false,
                            noColour: !walk.hasColour, boxes: judged)
    }

    /// The on-image extent of block (bx, by) of size (sw, sh).
    private static func extent(_ bx: Int, _ by: Int, _ sw: Int, _ sh: Int, _ w: Int, _ h: Int) -> PixelPaintRule.Lines {
        let full = PixelPaintRule.Lines(left: bx * sw, top: by * sh, right: bx * sw + sw, bottom: by * sh + sh)
        return edgeBlocksJudgedByTheirPartOnTheImage ? full.clipped(width: w, height: h) : full
    }

    private static func overlaps(_ a: PixelPaintRule.Lines, _ b: PixelPaintRule.Lines) -> Bool {
        a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom
    }

    /// One box against its page's picture.
    static func judge(box: PaintedBox, reported: RunRecord.PaintedPixels?, walk: PageImageWalk, dpi: Int,
                      widthSixtyFourths sw: Int, heightSixtyFourths sh: Int, fill: FillColor) -> BoxOutcome {
        let inner = box.inner
        if inner.maxX <= 0 || inner.minX >= sw || inner.maxY <= 0 || inner.minY >= sh { return .offPage }
        let w = walk.width, h = walk.height
        guard let unit = PixelPaintRule.unit(inner: inner, dpi: dpi, width: w, height: h) else {
            return .inconclusive(mapsToNoPixel, nil)
        }
        let rule = PixelPaintRule.pixelPaint(inner: inner, paint: box.paint, limitAbove: box.limitAbove, limitBelow: box.limitBelow,
                                             dpi: dpi, width: w, height: h)
        let note: BoxReportNote
        var painted = rule
        if let reported {
            if let lines = PixelPaintRule.reported(reported, width: w, height: h), lines.contains(rule) {
                note = lines == rule ? .none : .reportedLarger
                painted = lines
            } else {
                note = .reportedSmaller
            }
        } else {
            note = .notReported
        }

        var counts = BoxCounts()
        var wrongBlocks: [BoxWrongBlock] = []
        let side = PixelPaintRule.blockSide
        // Brightness: every block of the unit, then every further block wholly inside the painted area.
        let lumaWide = walk.blocksWide[0], lumaHigh = walk.blocksHigh[0]
        let luma = walk.blocks[0]
        let unitCols = (unit.left / side)..<PixelPaintRule.ceilDiv(unit.right, side)
        let unitRows = (unit.top / side)..<PixelPaintRule.ceilDiv(unit.bottom, side)
        counts.unitExpected = unitCols.count * unitRows.count
        for by in unitRows {
            for bx in unitCols {
                guard bx < lumaWide, by < lumaHigh else { continue }
                counts.unitExamined += 1
                if isExactFill(luma[by * lumaWide + bx], fill) {
                    counts.unitExact += 1
                } else {
                    wrongBlocks.append(BoxWrongBlock(component: 0, column: bx, row: by))
                }
            }
        }
        let paintCols = (painted.left / side)..<PixelPaintRule.ceilDiv(painted.right, side)
        let paintRows = (painted.top / side)..<PixelPaintRule.ceilDiv(painted.bottom, side)
        for by in paintRows {
            for bx in paintCols where !(unitCols.contains(bx) && unitRows.contains(by)) {
                guard painted.contains(extent(bx, by, side, side, w, h)), bx < lumaWide, by < lumaHigh else { continue }
                counts.furtherExamined += 1
                if isExactFill(luma[by * lumaWide + bx], fill) {
                    counts.furtherExact += 1
                } else {
                    wrongBlocks.append(BoxWrongBlock(component: 0, column: bx, row: by))
                }
            }
        }
        // What of the painted area lies in no block wholly inside it.
        counts.unconfirmedLeft = PixelPaintRule.upToBlock(painted.left) - painted.left
        counts.unconfirmedTop = PixelPaintRule.upToBlock(painted.top) - painted.top
        counts.unconfirmedRight = painted.right == w ? 0 : painted.right - PixelPaintRule.downToBlock(painted.right)
        counts.unconfirmedBottom = painted.bottom == h ? 0 : painted.bottom - PixelPaintRule.downToBlock(painted.bottom)

        // Colour: a colour block wholly inside the painted area must be neutral;
        // one that touches the unit and is not wholly inside is only counted.
        if walk.hasColour {
            let hMax = walk.components.map(\.horizontal).max() ?? 1
            let vMax = walk.components.map(\.vertical).max() ?? 1
            for c in 1..<walk.components.count {
                let cw = side * hMax / walk.components[c].horizontal
                let ch = side * vMax / walk.components[c].vertical
                let wide = walk.blocksWide[c], high = walk.blocksHigh[c]
                for by in (painted.top / ch)..<PixelPaintRule.ceilDiv(painted.bottom, ch) {
                    for bx in (painted.left / cw)..<PixelPaintRule.ceilDiv(painted.right, cw) {
                        let e = extent(bx, by, cw, ch, w, h)
                        let inside = painted.contains(e)
                        guard inside || overlaps(e, unit) else { continue }
                        guard bx < wide, by < high else { return .couldNotFinish(.evidenceShort, counts) }
                        let neutral = isNeutral(walk.blocks[c][by * wide + bx])
                        if inside {
                            counts.colourInside += 1
                            if neutral { counts.colourInsideNeutral += 1 } else {
                                wrongBlocks.append(BoxWrongBlock(component: c, column: bx, row: by))
                            }
                        } else if neutral {
                            counts.colourEdgeNeutral += 1
                        } else {
                            counts.colourEdgeNotJudged += 1
                        }
                    }
                }
            }
        }

        // A block that is not the paint is an issue whatever else holds; a
        // report never removes a block from what is judged.
        if !wrongBlocks.isEmpty { return .issue(counts, wrongBlocks) }
        if counts.unitExamined != counts.unitExpected { return .couldNotFinish(.evidenceShort, counts) }
        switch note {
        case .reportedSmaller: return .inconclusive(reportDoesNotHoldThePaint, counts)
        case .notReported: return .inconclusive(noReport, counts)
        case .none, .reportedLarger: return .completed(counts, note)
        }
    }
}
