import Foundation

/// Where a page's plan comes from: the regions as placed, or the policy of
/// the switch that widens boxes to their column.
package enum PlanSource: String, Hashable, Sendable, Codable, CaseIterable {
    /// One box for each region, `inner` and `paint` both the region's
    /// rectangle, no limit lines.
    case asPlaced
    /// The rows of the policy table.
    case switchPolicy
}

/// What the plan read of a box's line.
package enum LineReading: String, Hashable, Sendable, Codable, CaseIterable {
    /// A layout was read and the box's column can be read from it.
    case column
    /// A layout was read, with too little unselected text above and below
    /// the box to show its column.
    case noColumn
    /// No layout was read: the page's words are not the text its visible
    /// print is drawn from.
    case scanOrPicture
    /// No layout was read: the line's print does not run level, upright and
    /// left to right as the page is displayed.
    case direction
}

/// How a box's `inner` and `paint` are made.
package enum PaintRule: String, Hashable, Sendable, Codable, CaseIterable {
    /// `inner` and `paint` are the region's rectangle; no limit lines.
    case asPlaced
    /// As drawn: no margin, no limit lines.
    case asDrawn
    /// The placed rectangle plus the table's fixed margin on every side; no
    /// limit lines.
    case placedPlusFixedMargin
    /// `inner` is the selected extent on its line; `paint` is `inner` plus the
    /// margin worked out from the line's height, held at the limit lines and
    /// never inside `inner`.
    case lineMargin
    /// `inner` is the band from the column's start to its end across the
    /// line's own height; `paint` is the band plus the same margin, held at
    /// the limit lines.
    case band
}

/// What a row records about the switch.
package enum RowOutcome: Hashable, Sendable, Codable {
    /// The switch was not asked.
    case notAsked
    /// The plan records "widened" or "already as wide" by comparing the paint
    /// with the paint the same inputs give with the switch off.
    case byPaint
    /// The box could not be widened, for this reason.
    case couldNotWiden(reason: WidenReason)
}

/// What a row is looked up by.
package struct PolicyKey: Hashable, Sendable, Codable {
    package var kind: RegionKind
    package var reading: LineReading
    package var switchOn: Bool

    package init(kind: RegionKind, reading: LineReading, switchOn: Bool) {
        self.kind = kind
        self.reading = reading
        self.switchOn = switchOn
    }
}

/// What a row gives.
package struct PolicyRule: Hashable, Sendable, Codable {
    package var paint: PaintRule
    package var exposure: Exposure
    package var outcome: RowOutcome

    package init(paint: PaintRule, exposure: Exposure, outcome: RowOutcome) {
        self.paint = paint
        self.exposure = exposure
        self.outcome = outcome
    }
}

package struct PolicyRow: Hashable, Sendable, Codable {
    package var key: PolicyKey
    package var rule: PolicyRule

    package init(key: PolicyKey, rule: PolicyRule) {
        self.key = key
        self.rule = rule
    }
}

/// A fraction with whole numerator and denominator, so a constant measured
/// in line heights is exact.
package struct Ratio: Hashable, Sendable, Codable {
    package var numerator: Int
    package var denominator: Int

    package init(_ numerator: Int, _ denominator: Int) {
        self.numerator = numerator
        self.denominator = denominator
    }
}

/// When two lines of a page stand close enough to belong to one stack: by
/// the page's ordinary gap between consecutive lines, in steps, when there
/// are enough gaps to take it from; else by the lines' height alone.
package struct BlockSpacing: Hashable, Sendable, Codable {
    /// How far past the ordinary gap two lines may stand and still join, in
    /// line heights.
    package var excess: Ratio
    /// The step the free space between lines is counted in, in whole
    /// sixty-fourths of a point.
    package var stepSixtyFourths: Int
    /// The fewest gaps the ordinary gap is taken from.
    package var fewestGaps: Int
    /// With fewer gaps, two lines join when the free space between them is
    /// under this many line heights.
    package var withoutOrdinaryGap: Ratio

    package init(excess: Ratio, stepSixtyFourths: Int, fewestGaps: Int, withoutOrdinaryGap: Ratio) {
        self.excess = excess
        self.stepSixtyFourths = stepSixtyFourths
        self.fewestGaps = fewestGaps
        self.withoutOrdinaryGap = withoutOrdinaryGap
    }
}

/// A closed range of Unicode scalar values.
package struct ScalarRange: Hashable, Sendable, Codable {
    package var first: UInt32
    package var last: UInt32

    package init(_ first: UInt32, _ last: UInt32) {
        self.first = first
        self.last = last
    }

    package func contains(_ scalar: Unicode.Scalar) -> Bool { first <= scalar.value && scalar.value <= last }
}

/// The plan's constants that are not yet settled. They are values here, so a
/// change to one is a change to the table and not to any code path.
package struct ProvisionalConstants: Hashable, Sendable, Codable {
    /// The gap along a line that ends a run, in line heights.
    package var runGap: Ratio
    /// How many other lines must show a column before words beside a box's
    /// room are taken into its band.
    package var bridgingLines: Int
    /// The stop's distance: the larger of this many line heights and
    /// `stopPixels` at `lowestQualityDPI`.
    package var stopLineHeights: Ratio
    package var stopPixels: Int
    /// The lowest quality the app paints at, in dots per inch.
    package var lowestQualityDPI: Int
    /// How far from level a line's print may lie and still read as level,
    /// as the largest rise over run: one degree, its tangent
    /// (0.0174550649…) rounded down to millionths, so the test at the edge
    /// is a comparison of whole numbers.
    package var levelSlope: Ratio
    /// Scalars of right-to-left scripts: a letter in one of these on a line
    /// is evidence that the line does not run left to right.
    package var rightToLeftScalars: [ScalarRange]
    /// When two lines belong to one stack.
    package var blockSpacing: BlockSpacing

    package init(
        runGap: Ratio, bridgingLines: Int, stopLineHeights: Ratio, stopPixels: Int,
        lowestQualityDPI: Int, levelSlope: Ratio, rightToLeftScalars: [ScalarRange], blockSpacing: BlockSpacing
    ) {
        self.runGap = runGap
        self.bridgingLines = bridgingLines
        self.stopLineHeights = stopLineHeights
        self.stopPixels = stopPixels
        self.lowestQualityDPI = lowestQualityDPI
        self.levelSlope = levelSlope
        self.rightToLeftScalars = rightToLeftScalars
        self.blockSpacing = blockSpacing
    }

    /// Whether `scalar` is a letter of a right-to-left script: it lies in
    /// one of the table's ranges and its general category is a letter (L*),
    /// so the ranges' digits, marks and punctuation are not evidence.
    package func isRightToLeftLetter(_ scalar: Unicode.Scalar) -> Bool {
        guard rightToLeftScalars.contains(where: { $0.contains(scalar) }) else { return false }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    /// `stopPixels` at `lowestQualityDPI`, in whole sixty-fourths of a point,
    /// rounded up: the least the stop's distance can be.
    package var stopPixelsSixtyFourths: Int {
        let numerator = stopPixels * 64 * 72
        return (numerator + lowestQualityDPI - 1) / lowestQualityDPI
    }
}

/// The policy that makes a page's plan: a table of rows, looked up by the
/// region's kind, what was read of its line and the switch; the rule for the
/// plan made from the regions as placed; and the constants the rows use.
package struct GeometryPolicy: Hashable, Sendable, Codable {
    package var rows: [PolicyRow]
    package var asPlaced: PolicyRule
    /// The margin added on every side of a box whose paint rule is
    /// `placedPlusFixedMargin`, in whole sixty-fourths of a point.
    package var fixedMarginSixtyFourths: Int
    package var provisional: ProvisionalConstants

    package init(rows: [PolicyRow], asPlaced: PolicyRule, fixedMarginSixtyFourths: Int, provisional: ProvisionalConstants) {
        self.rows = rows
        self.asPlaced = asPlaced
        self.fixedMarginSixtyFourths = fixedMarginSixtyFourths
        self.provisional = provisional
    }

    /// The rule for a box: the as-placed rule when the plan is made from the
    /// regions as placed, else the row of its key, or nil when the table has
    /// no row for it.
    package func rule(for key: PolicyKey, source: PlanSource) -> PolicyRule? {
        switch source {
        case .asPlaced: asPlaced
        case .switchPolicy: rows.first { $0.key == key }?.rule
        }
    }
}

extension GeometryPolicy {
    /// This release's table. Every row can show the covered value's length.
    package static let release = GeometryPolicy(
        rows: releaseRows,
        asPlaced: PolicyRule(paint: .asPlaced, exposure: .canShowLength, outcome: .notAsked),
        fixedMarginSixtyFourths: 96,
        provisional: ProvisionalConstants(
            runGap: Ratio(1, 1),
            bridgingLines: 2,
            stopLineHeights: Ratio(1, 2),
            stopPixels: 8,
            lowestQualityDPI: 150,
            levelSlope: Ratio(17_455, 1_000_000),
            rightToLeftScalars: [
                ScalarRange(0x0590, 0x08FF),
                ScalarRange(0xFB1D, 0xFDFF),
                ScalarRange(0xFE70, 0xFEFC),
                ScalarRange(0x10800, 0x10FFF),
                ScalarRange(0x1E800, 0x1EFFF),
            ],
            blockSpacing: BlockSpacing(excess: Ratio(1, 2), stepSixtyFourths: 32, fewestGaps: 4,
                                       withoutOrdinaryGap: Ratio(1, 1))
        )
    )

    private static func row(
        _ kind: RegionKind, _ reading: LineReading, on switchOn: Bool, _ paint: PaintRule, _ outcome: RowOutcome
    ) -> PolicyRow {
        PolicyRow(key: PolicyKey(kind: kind, reading: reading, switchOn: switchOn),
                  rule: PolicyRule(paint: paint, exposure: .canShowLength, outcome: outcome))
    }

    private static let releaseRows: [PolicyRow] = [
        // Drawn by hand: as drawn, whatever was read of the line.
        row(.drawnByHand, .column, on: false, .asDrawn, .notAsked),
        row(.drawnByHand, .column, on: true, .asDrawn, .couldNotWiden(reason: .byHand)),
        row(.drawnByHand, .noColumn, on: false, .asDrawn, .notAsked),
        row(.drawnByHand, .noColumn, on: true, .asDrawn, .couldNotWiden(reason: .byHand)),
        row(.drawnByHand, .scanOrPicture, on: false, .asDrawn, .notAsked),
        row(.drawnByHand, .scanOrPicture, on: true, .asDrawn, .couldNotWiden(reason: .byHand)),
        row(.drawnByHand, .direction, on: false, .asDrawn, .notAsked),
        row(.drawnByHand, .direction, on: true, .asDrawn, .couldNotWiden(reason: .byHand)),
        // Placed from the text and still anchored: the line decides.
        row(.placedFromTextAnchored, .column, on: false, .lineMargin, .notAsked),
        row(.placedFromTextAnchored, .column, on: true, .band, .byPaint),
        row(.placedFromTextAnchored, .noColumn, on: false, .lineMargin, .notAsked),
        row(.placedFromTextAnchored, .noColumn, on: true, .lineMargin, .couldNotWiden(reason: .noColumn)),
        row(.placedFromTextAnchored, .scanOrPicture, on: false, .placedPlusFixedMargin, .notAsked),
        row(.placedFromTextAnchored, .scanOrPicture, on: true, .placedPlusFixedMargin, .couldNotWiden(reason: .scanOrPicture)),
        row(.placedFromTextAnchored, .direction, on: false, .placedPlusFixedMargin, .notAsked),
        row(.placedFromTextAnchored, .direction, on: true, .placedPlusFixedMargin, .couldNotWiden(reason: .direction)),
        // Placed from the text, then moved or resized: as drawn, by hand.
        row(.placedFromTextThenEdited, .column, on: false, .asDrawn, .notAsked),
        row(.placedFromTextThenEdited, .column, on: true, .asDrawn, .couldNotWiden(reason: .byHand)),
        row(.placedFromTextThenEdited, .noColumn, on: false, .asDrawn, .notAsked),
        row(.placedFromTextThenEdited, .noColumn, on: true, .asDrawn, .couldNotWiden(reason: .byHand)),
        row(.placedFromTextThenEdited, .scanOrPicture, on: false, .asDrawn, .notAsked),
        row(.placedFromTextThenEdited, .scanOrPicture, on: true, .asDrawn, .couldNotWiden(reason: .byHand)),
        row(.placedFromTextThenEdited, .direction, on: false, .asDrawn, .notAsked),
        row(.placedFromTextThenEdited, .direction, on: true, .asDrawn, .couldNotWiden(reason: .byHand)),
        // Placed from the page's picture: the fixed margin, scan or picture.
        row(.placedFromPicture, .column, on: false, .placedPlusFixedMargin, .notAsked),
        row(.placedFromPicture, .column, on: true, .placedPlusFixedMargin, .couldNotWiden(reason: .scanOrPicture)),
        row(.placedFromPicture, .noColumn, on: false, .placedPlusFixedMargin, .notAsked),
        row(.placedFromPicture, .noColumn, on: true, .placedPlusFixedMargin, .couldNotWiden(reason: .scanOrPicture)),
        row(.placedFromPicture, .scanOrPicture, on: false, .placedPlusFixedMargin, .notAsked),
        row(.placedFromPicture, .scanOrPicture, on: true, .placedPlusFixedMargin, .couldNotWiden(reason: .scanOrPicture)),
        row(.placedFromPicture, .direction, on: false, .placedPlusFixedMargin, .notAsked),
        row(.placedFromPicture, .direction, on: true, .placedPlusFixedMargin, .couldNotWiden(reason: .scanOrPicture)),
    ]
}
