import CoreGraphics
import Foundation

// The hidden-word check's rule, as a pure function over plain values.
//
// On a scanned page whose text is an invisible layer over the picture, the
// layer can sit some way from the printed words. A box drawn over a printed
// word then need not cover that word's hidden copy, and every other check
// reads the same box rectangles the export stripped by. This check places
// each word that survives in the export's text layer on the page's PRINT,
// read independently from a fresh render of the source page, and asks
// whether that print lies under a box.
//
// The rule, line by line:
// - A line's drift from its print is fitted from its anchors: surviving
//   words matched to a recognized source word with the same folded key, a
//   repeated key matched by its order on the line (and only when it occurs
//   as often in the print as in the layer), and neither copy touching a box.
//   No anchor or one: the line cannot be placed. Exactly two: an offset
//   alone, used only when both anchors lie within `residualSlack` of it.
//   Three or more: an offset plus a scale along the line, used only when the
//   scale is within `scaleAtLeast`…`scaleAtMost` and every anchor lies within
//   `residualSlack` of the fit. Across the line the fit is an offset alone,
//   under the same slack. No anchor is dropped to make a fit.
// - A placed word whose mapped print has its centre inside a box's paint
//   (its pre-growth `normalizedRect`) is flagged on that box, whatever its
//   key: a fragment counts. One whose mapped print only crosses a box's edge
//   is an edge note on that box.
// - A surviving word that could lie under a box (within the drift reach of a
//   box's paint) is not inspected when its line cannot be placed, or when it
//   was placed where no recognized print lies. Far from every box, either
//   changes nothing.
// - Findings, edge notes and an unplaceable word near a box can all hold on
//   one page.
//
// Every judgement is made in integers: coordinates are quantized once, at
// the edge, to `gridPerPoint` units, and the fit is compared through cross
// multiplication, never through a division. The geometry handed in is in the
// page's normalized frame (bottom-left origin, post-rotation crop box), the
// frame `RedactionRegion.normalizedRect` uses. No word's text leaves this
// function: the marks carry a page, a box and a rectangle.

/// One word as the hidden-word check reads it: its text (folded into a key
/// here, never stored or reported), its box in the page's normalized frame,
/// and a line id. Output and source line ids are numbered independently.
struct HiddenWordInkWord: Equatable, Sendable {
    var key: String
    var rect: CGRect
    var line: Int
}

/// What the check knows about the source page before it reads a word.
enum HiddenWordInkPageKind: Equatable, Sendable {
    /// An image object or inline image of any size, invisible text or a
    /// Type 3 font: the text layer need not sit on the print.
    case textOverImage
    /// None of those: the text layer is its own ink.
    case plain
}

/// Why a page had nothing for the check to check.
enum HiddenWordInkNotApplicable: Equatable, Sendable {
    case noText, plainSource, noRegions
}

/// A flagged word or an edge note: the page, the box, and the word's print
/// as the check placed it. No text.
struct HiddenWordInkMark: Equatable, Sendable {
    var pageIndex: Int
    var regionID: UUID
    var inkRect: CGRect
}

/// The check's verdict for one page.
struct HiddenWordInkVerdict: Equatable, Sendable {
    var findings: [HiddenWordInkMark] = []
    var edgeNotes: [HiddenWordInkMark] = []
    var unplaceableNearBox = false
    var notApplicable: HiddenWordInkNotApplicable?
}

enum HiddenWordInkCheck {

    // MARK: - The named limits

    /// Grid units per point: every coordinate is rounded once to 1/16 pt.
    static let gridPerPoint = 16

    /// How far (points) an anchor may sit from its line's fit, along and
    /// across: of the order of the least slack measured to reject no true
    /// word on producers' layers (2.25 pt), with headroom.
    static let residualSlack = 3.5

    /// The line scales (print along the line over layer along it) a fit may
    /// have, as exact fractions: 1/2 to 2/1. Past them the line is not placed.
    static let scaleAtLeast = (numerator: 1, denominator: 2)
    static let scaleAtMost = (numerator: 2, denominator: 1)

    /// The most anchors one line's fit takes; a line with more is not placed
    /// (a reached limit is an observation, never a pass).
    static let maxAnchorsPerLine = 512

    /// How far (points) a layer may sit from its print along its line, at
    /// the least: 28.7 pt measured on producers' layers, plus a margin.
    static let driftAlong = 36.0

    /// The growth of that reach for each point between the line's start and
    /// the word's far end (a layer set smaller than its print falls behind
    /// it in proportion).
    static let driftAlongPerPoint = 0.45

    /// The growth of that reach for each wide (CJK) character on the line up
    /// to and including the word, as a share of the line's height.
    static let driftAlongPerWide = 0.5

    /// How far (points) a layer may sit above or below its print, at the
    /// least; `driftAcrossPerHeight` line heights when that is larger.
    static let driftAcross = 10.0
    static let driftAcrossPerHeight = 1.5

    // MARK: - The predicate

    static func verdict(
        pageIndex: Int, output: [HiddenWordInkWord], sourceInk: [HiddenWordInkWord],
        regions: [RedactionRegion], pageSize: CGSize, kind: HiddenWordInkPageKind,
        axis: HiddenWordInkAxis = .right
    ) -> HiddenWordInkVerdict {
        if output.isEmpty { return HiddenWordInkVerdict(notApplicable: .noText) }
        if regions.isEmpty { return HiddenWordInkVerdict(notApplicable: .noRegions) }
        if kind == .plain { return HiddenWordInkVerdict(notApplicable: .plainSource) }

        var verdict = HiddenWordInkVerdict()
        guard let grid = Grid(pageSize: pageSize) else {
            verdict.unplaceableNearBox = true
            return verdict
        }
        let boxes = regions.compactMap { region in grid.box(region.normalizedRect).map { (region.id, $0) } }
        guard boxes.count == regions.count else {
            verdict.unplaceableNearBox = true
            return verdict
        }
        let source: [GridWord] = sourceInk.compactMap { word in
            grid.box(word.rect).map { GridWord(key: fold(word.key), raw: word.key, box: $0) }
        }

        let lines = Dictionary(grouping: output, by: \.line).sorted { $0.key < $1.key }
        for (_, lineWords) in lines {
            var words: [GridWord] = []
            for word in lineWords {
                guard let box = grid.box(word.rect) else {
                    // A surviving word with no measurable box could be anywhere.
                    verdict.unplaceableNearBox = true
                    continue
                }
                words.append(GridWord(key: fold(word.key), raw: word.key, box: box))
            }
            guard !words.isEmpty else { continue }
            // "Along the line" is the page's axis: a page turned a quarter
            // runs its lines up or down the normalized frame. The rule is
            // the same on either, so a vertical page is read transposed and
            // its marks transposed back.
            let vertical = axis.isVertical
            let t: (GridBox) -> GridBox = { vertical ? $0.transposed : $0 }
            words = words.map { GridWord(key: $0.key, raw: $0.raw, box: t($0.box)) }
                .sorted { ($0.box.minX, $0.box.maxX) < ($1.box.minX, $1.box.maxX) }
            let lineSource = source.map { GridWord(key: $0.key, raw: $0.raw, box: t($0.box)) }
            let lineBoxes = boxes.map { ($0.0, t($0.1)) }
            let ink: (MappedBox) -> CGRect = { grid.normalized(vertical ? $0.transposed : $0) }
            let line = LineFacts(words)
            guard let fit = placedFit(words, line: line, source: lineSource, boxes: lineBoxes.map { $0.1 }) else {
                if words.contains(where: { nearAnyBox($0, line: line, boxes: lineBoxes) }) {
                    verdict.unplaceableNearBox = true
                }
                continue
            }
            for word in words {
                let mapped = fit.map(word.box)
                var flagged = false
                for (id, paint) in lineBoxes where mapped.centreInside(paint) {
                    verdict.findings.append(HiddenWordInkMark(pageIndex: pageIndex, regionID: id, inkRect: ink(mapped)))
                    flagged = true
                }
                if flagged { continue }
                for (id, paint) in lineBoxes where mapped.overlaps(paint) {
                    verdict.edgeNotes.append(HiddenWordInkMark(pageIndex: pageIndex, regionID: id, inkRect: ink(mapped)))
                }
                let hasPrint = lineSource.contains { mapped.overlaps($0.box) }
                if !hasPrint, nearAnyBox(word, line: line, boxes: lineBoxes) {
                    verdict.unplaceableNearBox = true
                }
            }
        }
        return verdict
    }

    /// A line's accepted fit, or nil when it cannot be placed: its words (in
    /// the page's along frame, sorted along it) must spread along the page's
    /// axis (a line that runs across it, or has no clear axis, is not placed),
    /// and their anchors must fit.
    static func placedFit(_ words: [GridWord], line: LineFacts, source: [GridWord], boxes: [GridBox]) -> Fit? {
        guard runsAlong(words) else { return nil }
        return fitLine(words, line: line, source: source, boxes: boxes)
    }

    /// Whether a line's words (already in the page's along frame) spread
    /// along x more than across it: by their centres when the line has two
    /// or more, else by the word's own shape. Equal spreads are no clear axis.
    static func runsAlong(_ words: [GridWord]) -> Bool {
        if words.count >= 2 {
            let xs = words.map(\.box.centre2X), ys = words.map(\.box.centre2Y)
            return (xs.max()! - xs.min()!) > (ys.max()! - ys.min()!)
        }
        let box = words[0].box
        return (box.maxX - box.minX) > (box.maxY - box.minY)
    }

    // MARK: - Keys

    /// A word's matching key: case, diacritics and width folded, letters and
    /// digits only. Empty for punctuation, which never anchors.
    static func fold(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    /// Whether a scalar is set wide (an ideograph, kana, hangul or a
    /// full-width form): the layer advances less than the print over it.
    static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }

    // MARK: - The fit

    /// One line's drift: along, print = (K + 2L·x) / (2·den) for a layer
    /// coordinate x; across, print = (2n·y + ky) / (2n). All in grid units.
    struct Fit: Equatable {
        var k: Int128
        var l: Int128
        var den: Int128
        var ky: Int128
        var n: Int128

        func map(_ box: GridBox) -> MappedBox {
            MappedBox(minX: k + 2 * l * Int128(box.minX), maxX: k + 2 * l * Int128(box.maxX), xDen: 2 * den,
                      minY: 2 * n * Int128(box.minY) + ky, maxY: 2 * n * Int128(box.maxY) + ky, yDen: 2 * n)
        }
    }

    /// The fit of one output line, or nil when the line cannot be placed.
    static func fitLine(_ words: [GridWord], line: LineFacts, source: [GridWord], boxes: [GridBox]) -> Fit? {
        // The print on this line: recognized words within the across reach of
        // the line's centre.
        let band = source.filter { abs($0.box.centre2Y - line.centre2Y) <= line.across2 }
            .sorted { ($0.box.minX, $0.box.maxX) < ($1.box.minX, $1.box.maxX) }
        // Pair each key by its order on the line, only when it occurs as
        // often in the print as in the layer.
        var anchors: [(layer: GridBox, print: GridBox)] = []
        let layerByKey = Dictionary(grouping: words.filter { !$0.key.isEmpty }, by: \.key)
        let printByKey = Dictionary(grouping: band.filter { !$0.key.isEmpty }, by: \.key)
        for (key, layerCopies) in layerByKey {
            guard let printCopies = printByKey[key], printCopies.count == layerCopies.count else { continue }
            for (layer, print) in zip(layerCopies, printCopies)
            where !boxes.contains(where: { layer.box.overlaps($0) || print.box.overlaps($0) }) {
                anchors.append((layer.box, print.box))
            }
        }
        let n = anchors.count
        guard n >= 2, n <= maxAnchorsPerLine else { return nil }
        let slack2 = Int128(slackGrid2)

        // Across: an offset alone, every anchor within the slack of the mean.
        let dys = anchors.map { Int128($0.print.centre2Y - $0.layer.centre2Y) }
        let sumDY = dys.reduce(0, +)
        let nn = Int128(n)
        guard dys.allSatisfy({ abs(nn * $0 - sumDY) <= slack2 * nn }) else { return nil }

        let xs = anchors.map { Int128($0.layer.centre2X) }
        let ys = anchors.map { Int128($0.print.centre2X) }
        if n == 2 {
            // An offset alone: both anchors within the slack of the pair's mean.
            let d0 = ys[0] - xs[0], d1 = ys[1] - xs[1]
            guard abs(d0 - d1) <= 2 * slack2 else { return nil }
            return Fit(k: d0 + d1, l: 2, den: 2, ky: sumDY, n: nn)
        }
        // An offset plus a scale, by least squares, compared exactly.
        let sx = xs.reduce(0, +), sy = ys.reduce(0, +)
        let sxx = nn * xs.map { $0 * $0 }.reduce(0, +) - sx * sx
        let sxy = nn * zip(xs, ys).map { $0 * $1 }.reduce(0, +) - sx * sy
        guard sxx > 0 else { return nil }
        // scaleAtLeast ≤ sxy / sxx ≤ scaleAtMost, cross-multiplied (sxx > 0).
        guard Int128(scaleAtLeast.denominator) * sxy >= Int128(scaleAtLeast.numerator) * sxx,
              Int128(scaleAtMost.denominator) * sxy <= Int128(scaleAtMost.numerator) * sxx else { return nil }
        let den = nn * sxx
        let k = sy * sxx - sxy * sx
        let l = nn * sxy
        guard zip(xs, ys).allSatisfy({ x, y in abs(y * den - (k + l * x)) <= slack2 * den }) else { return nil }
        return Fit(k: k, l: l, den: den, ky: sumDY, n: nn)
    }

    /// The residual slack in doubled grid units (centres are doubled to stay
    /// integral).
    static var slackGrid2: Int { Int((residualSlack * Double(gridPerPoint) * 2).rounded()) }

    // MARK: - Near a box

    /// Whether the print of `word` could lie under some box: the box's paint
    /// is within the drift reach of the word's layer box, along and across.
    /// The reach does not assume a reading direction: the distance is taken
    /// from whichever end of the line is farther, and every wide character
    /// on the line counts.
    static func nearAnyBox(_ word: GridWord, line: LineFacts, boxes: [(UUID, GridBox)]) -> Bool {
        // The reach along, in hundredths of a grid unit:
        // 100·(driftAlong + 0.45·distance + 0.5·height·wide).
        let distance = Int128(max(word.box.maxX - line.startX, line.endX - word.box.minX))
        let wide = Int128(line.wide)
        let base = Int128((driftAlong * Double(gridPerPoint) * 100).rounded())
        let perPoint = Int128((driftAlongPerPoint * 100).rounded())
        let perWide = Int128((driftAlongPerWide * 100).rounded())
        let reach100 = base + perPoint * distance + perWide * Int128(line.height) * wide
        return boxes.contains { _, paint in
            let gapX = Int128(max(0, paint.minX - word.box.maxX, word.box.minX - paint.maxX))
            let gapY = max(0, paint.minY - word.box.maxY, word.box.minY - paint.maxY)
            return gapX * 100 <= reach100 && 2 * gapY <= line.across2
        }
    }

    // MARK: - Grid values

    struct GridBox: Equatable {
        var minX: Int, maxX: Int, minY: Int, maxY: Int
        var centre2X: Int { minX + maxX }
        var centre2Y: Int { minY + maxY }
        var transposed: GridBox { GridBox(minX: minY, maxX: maxY, minY: minX, maxY: maxX) }
        /// Overlap with positive area (sharing an edge is not overlap).
        func overlaps(_ other: GridBox) -> Bool {
            minX < other.maxX && other.minX < maxX && minY < other.maxY && other.minY < maxY
        }
    }

    /// A box mapped through a fit: each coordinate is a numerator over its
    /// axis's (positive) denominator.
    struct MappedBox: Equatable {
        var minX: Int128, maxX: Int128, xDen: Int128
        var minY: Int128, maxY: Int128, yDen: Int128

        var transposed: MappedBox {
            MappedBox(minX: minY, maxX: maxY, xDen: yDen, minY: minX, maxY: maxX, yDen: xDen)
        }

        /// The centre is inside the paint, edges included.
        func centreInside(_ paint: GridBox) -> Bool {
            let cx = minX + maxX, cy = minY + maxY
            return 2 * Int128(paint.minX) * xDen <= cx && cx <= 2 * Int128(paint.maxX) * xDen
                && 2 * Int128(paint.minY) * yDen <= cy && cy <= 2 * Int128(paint.maxY) * yDen
        }

        func overlaps(_ box: GridBox) -> Bool {
            minX < Int128(box.maxX) * xDen && Int128(box.minX) * xDen < maxX
                && minY < Int128(box.maxY) * yDen && Int128(box.minY) * yDen < maxY
        }
    }

    struct GridWord: Equatable {
        var key: String
        var raw: String
        var box: GridBox
    }

    /// One output line's facts: its start, its height (the median word
    /// height), its centre (doubled) and its across reach (doubled).
    struct LineFacts {
        var startX: Int
        var endX: Int
        var wide: Int
        var height: Int
        var centre2Y: Int
        var across2: Int

        init(_ words: [GridWord]) {
            startX = words.map(\.box.minX).min() ?? 0
            endX = words.map(\.box.maxX).max() ?? 0
            wide = words.reduce(0) { $0 + $1.raw.unicodeScalars.filter(HiddenWordInkCheck.isWide).count }
            let heights = words.map { $0.box.maxY - $0.box.minY }.sorted()
            height = heights[heights.count / 2]
            centre2Y = words.map(\.box.centre2Y).sorted()[words.count / 2]
            let atLeast = Int((HiddenWordInkCheck.driftAcross * Double(HiddenWordInkCheck.gridPerPoint) * 2).rounded())
            let perHeight2 = Int((HiddenWordInkCheck.driftAcrossPerHeight * 2).rounded())
            across2 = max(atLeast, perHeight2 * height)
        }
    }

    /// The page's normalized frame quantized to the grid.
    struct Grid {
        var width: Double
        var height: Double

        init?(pageSize: CGSize) {
            guard pageSize.width.isFinite, pageSize.height.isFinite, pageSize.width > 0, pageSize.height > 0 else {
                return nil
            }
            width = Double(pageSize.width) * Double(HiddenWordInkCheck.gridPerPoint)
            height = Double(pageSize.height) * Double(HiddenWordInkCheck.gridPerPoint)
        }

        func box(_ rect: CGRect) -> GridBox? {
            let r = rect.standardized
            guard !r.isNull, r.minX.isFinite, r.minY.isFinite, r.maxX.isFinite, r.maxY.isFinite,
                  r.width > 0, r.height > 0 else { return nil }
            let limit = 1 << 40
            let values = [Double(r.minX) * width, Double(r.maxX) * width, Double(r.minY) * height, Double(r.maxY) * height]
                .map { $0.rounded() }
            guard values.allSatisfy({ abs($0) < Double(limit) }) else { return nil }
            let ints = values.map { Int($0) }
            guard ints[1] > ints[0], ints[3] > ints[2] else { return nil }
            return GridBox(minX: ints[0], maxX: ints[1], minY: ints[2], maxY: ints[3])
        }

        /// A mapped box back in the normalized frame (for the mark only; no
        /// judgement reads it).
        func normalized(_ m: MappedBox) -> CGRect {
            let x0 = Double(m.minX) / Double(m.xDen) / width, x1 = Double(m.maxX) / Double(m.xDen) / width
            let y0 = Double(m.minY) / Double(m.yDen) / height, y1 = Double(m.maxY) / Double(m.yDen) / height
            return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }
    }
}
