import CoreGraphics
import Foundation

/// A Searchable page's text path: from the extracted entries to the list the
/// page records and writes, or to "a picture" with a reason. The rasterizer
/// calls it once. Its steps run in one order, each through a seam a test can
/// replace (`steps`): the fold, the filter, the alphabet marks and the paint
/// marks, the whole-word closure with the drawn-cell rule, and the record.
/// Every step that changes a letter of the hidden text runs before the
/// record; after it nothing adds, removes or changes a letter.
///
/// Two lists of rectangles come in, already in output-page points; the path
/// derives neither. The text-path rectangles: the filter, the layout's line
/// breaks (in the writer and in the drawn-cell rule), the record and the
/// page output's rectangles all read this one list, every kind but "under a
/// widened box", which only the position check reads. The painted
/// rectangles: read by the paint marks, empty until the plan switch fills
/// them.
enum PageTextPath {

    /// The path's steps. The default is the real step for each; a test
    /// replaces one, within `$steps.withValue`, to make it fault.
    struct Steps: Sendable {
        var fold: @Sendable ([CharacterInfo]) throws -> [CharacterInfo]
        var filter: @Sendable ([CharacterInfo], [CGRect]) async throws -> FilterResult
        var alphabetMarks: @Sendable ([CharacterInfo]) throws -> TextPathAlphabetMarks.Marks
        /// The words the paint covers, by the page's one partition, from the
        /// survivors and the painted rectangles. Nothing until the plan
        /// switch hands in painted rectangles.
        var paintMarks: @Sendable ([CharacterInfo], [CGRect]) throws -> Set<Int>

        static let live = Steps(
            fold: { TextPathFold.fold($0) },
            filter: { try await filterCharacters(characters: $0, redactionRects: $1) },
            alphabetMarks: { TextPathAlphabetMarks.marks($0) },
            paintMarks: { _, _ in [] })
    }

    @TaskLocal static var steps = Steps.live

    /// How the page ends.
    enum Outcome: Sendable {
        /// The list to record and write, its record, and the rectangles the
        /// writer's line assembly reads.
        case written(entries: [CharacterInfo], digest: PageFilterDigest, removalRects: [CGRect])
        /// The page is a picture, for this reason.
        case picture(TextLayerDetector.FallbackReason)
    }

    struct Result: Sendable {
        let outcome: Outcome
        /// The runs the alphabet rule left out: carried with either outcome,
        /// zero when the page is a picture for another reason.
        let runsLeftOut: Int
        /// Survivors the drawn-cell rule dropped.
        let drawnCellDropped: Int
    }

    static func run(
        entries: [CharacterInfo],
        frame: PageFrame,
        textPathRectangles: [TextPathRectangle],
        paintedRectangles: [CGRect],
        pageIndex: Int,
        safetyMargin: CGFloat = safetyMarginPoints
    ) async throws -> Result {
        let steps = Self.steps
        let rects = textPathRectangles.filter { $0.kind != .underWidenedBox }.map(\.rect)

        let folded = try steps.fold(entries)
        let filtered = try await steps.filter(folded, rects)
        let alphabet = try steps.alphabetMarks(filtered.surviving)
        let painted = try steps.paintMarks(filtered.surviving, paintedRectangles)

        // The whole-word closure over every marked word, then the drawn-cell
        // rule on what is left.
        let closed = closeOverMarkedWords(filtered, marked: alphabet.wordIndices.union(painted))
        let shapes = rects.map {
            RegionShape(expandedBounds: $0.insetBy(dx: -safetyMargin, dy: -safetyMargin), bounds: $0)
        }
        let validated = TextLayerReconstructor.validateSurvivors(
            closed, regionShapes: shapes, frame: frame)
        guard validated.settled else {
            return Result(outcome: .picture(.extractionFailed), runsLeftOut: 0,
                          drawnCellDropped: validated.dropped)
        }
        if validated.result.surviving.isEmpty, !alphabet.wordIndices.isEmpty,
           let reason = alphabet.reasonIfNoWordLeft {
            return Result(outcome: .picture(reason), runsLeftOut: alphabet.runsLeftOut,
                          drawnCellDropped: validated.dropped)
        }

        // The record.
        let digest = validated.result.toDigest(
            pageIndex: pageIndex,
            redactionRects: rects,
            safetyMargin: safetyMargin,
            drawnCellRuleExcludedCount: validated.dropped,
            frame: frame)
        return Result(
            outcome: .written(entries: validated.result.surviving, digest: digest, removalRects: rects),
            runsLeftOut: alphabet.runsLeftOut, drawnCellDropped: validated.dropped)
    }

    /// `result` with every survivor of a marked word left out, counted as
    /// excluded. With no word marked it is `result` itself.
    static func closeOverMarkedWords(_ result: FilterResult, marked: Set<Int>) -> FilterResult {
        guard !marked.isEmpty else { return result }
        let kept = result.surviving.filter { !marked.contains($0.wordIndex) }
        return FilterResult(
            surviving: kept, totalCharacters: result.totalCharacters,
            excludedCount: result.excludedCount + (result.surviving.count - kept.count))
    }
}
